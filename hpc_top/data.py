"""Cluster access: the remote snapshot query, its parsers and the SSH transport."""

from __future__ import annotations

import os
import re
import shlex
import socket
import subprocess
import time
from dataclasses import dataclass

PARTITION = "aiq"
LOG_LINES = 200
RUN_TIMEOUT = 30  # seconds granted to a cluster command before it is killed
ACTIVE_STATES = {"RUNNING", "PENDING"}
TIME_WARNING = 0.9  # fraction of the time limit after which a running job raises an alert
WASTE_AFTER = 300  # seconds of run time before a memory peak is considered meaningful
# MIG profile of each resource class; mirrors `preset` in bin/hpc.
CLASSES = {"1g.35gb": "tiny", "2g.35gb": "small", "4g.71gb": "medium", "7g.141gb": "large"}
GRES = re.compile(r"gpu:([\w.]+):(\d+)")
# One line per node of the partition, parsed by parse_node.
NODES_COMMAND = f"sinfo -N -h -p {PARTITION} -O NodeList:30,StateLong:20,CPUsState:30,Memory:15,AllocMem:15,Gres:300,GresUsed:400"


@dataclass(frozen=True)
class Job:
    """A pending or running job, as reported by squeue."""

    id: str
    name: str
    state: str
    elapsed: str
    limit: str
    qos: str
    where: str
    workdir: str
    start: str  # actual start, or the scheduler's estimate while pending ("N/A" when unknown)
    user: str


@dataclass(frozen=True)
class Record:
    """The accounting record of a job submitted in the last 24 hours, as reported by sacct."""

    id: str
    name: str
    state: str
    elapsed: str
    exit_code: str
    workdir: str
    submit: str
    start: str
    end: str
    limit: str
    requested: dict[str, str]
    allocated: dict[str, str]
    node: str
    account: str
    # The job's own ID, as squeue shows it and as %j names the log; id is ID_TASK for a task of a job array.
    raw: str


@dataclass(frozen=True)
class Usage:
    """Resource usage of a running job, as reported by sstat: peaks and current values."""

    cpu_time: str
    mem_mb: float
    gpu_mem_mb: float
    mem_now_mb: float
    gpu_mem_now_mb: float


@dataclass(frozen=True)
class Node:
    """Allocation of a compute node; gpus maps a MIG profile to (used, total) slices."""

    name: str
    state: str
    cpu_used: int
    cpu_total: int
    mem_used: int
    mem_total: int
    gpus: dict[str, tuple[int, int]]


@dataclass(frozen=True)
class Snapshot:
    jobs: tuple[Job, ...]
    nodes: tuple[Node, ...]
    records: dict[str, Record]  # by raw job ID
    history: tuple[Record, ...]  # the records of the jobs that have ended, most recent first
    log_path: str
    log: str
    usage: Usage | None  # of the selected job, when it is running
    efficiency: dict[str, str]  # seff report of the selected job, by label


def snapshot_command(selected: tuple[str, str] | None, everyone: bool = False) -> str:
    """Shell command printing one snapshot; selected is the (workdir, job ID) whose log is tailed.

    The jobs listed are those of the caller, or of every user when everyone is set.
    """
    owner = "" if everyone else '-u "$USER" '
    parts = [
        "set -e",
        "echo @@jobs",
        f'squeue -h {owner}-O "JobID:|,Name:|,State:|,TimeUsed:|,TimeLimit:|,QOS:|,ReasonList:|,WorkDir:|,StartTime:|,UserName:|"',
        "echo @@nodes",
        NODES_COMMAND,
        "echo @@history",
        "sacct -X -n -P -S now-1days --format=JobID,JobName,State,Elapsed,ExitCode,WorkDir,"
        "Submit,Start,End,Timelimit,ReqTRES,AllocTRES,NodeList,Account,JobIDRaw",
        "echo @@log",
    ]
    usage = "echo @@usage"
    efficiency = "echo @@efficiency"
    if selected:
        workdir, job_id = selected
        # Same convention as `hpc logs`: slurm-%j.out and %x-%j.out both put "-" before the ID.
        pattern = f"{shlex.quote(workdir)}/*-{shlex.quote(job_id)}.out"
        parts.append(
            f'f=$(ls -t {pattern} 2>/dev/null | head -n 1); if [ -n "$f" ]; then echo "$f"; tail -n {LOG_LINES} "$f"; fi'
        )
        # sstat knows running jobs only; for the others it prints an error and no rows.
        usage += f"; sstat -a -n -P -j {shlex.quote(job_id)} --format=TRESUsageInMax,TRESUsageInTot 2>/dev/null || true"
        efficiency += f"; seff {shlex.quote(job_id)} 2>/dev/null || true"
    return "; ".join([*parts, usage, efficiency])


def tres(text: str) -> dict[str, str]:
    """Parse a TRES list such as "cpu=6,gres/gpu:4g.71gb=1,mem=128G"."""
    return dict(item.split("=", 1) for item in text.split(",") if item)


def megabytes(size: str) -> float:
    """Convert a Slurm size such as "8658528K" or "128G" to megabytes."""
    units = {"K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024}
    return float(size[:-1]) * units[size[-1]] if size[-1] in units else float(size)


def seconds(duration: str) -> int | None:
    """Convert "[D-]HH:MM:SS" to seconds; None for a limit that is not a duration (UNLIMITED)."""
    match = re.fullmatch(r"(?:(\d+)-)?(\d+):(\d+):(\d+)", duration)
    if not match:
        return None
    days, hours, minutes, secs = (int(part or 0) for part in match.groups())
    return ((days * 24 + hours) * 60 + minutes) * 60 + secs


def parse_node(line: str) -> Node:
    name, state, cpus, mem_total, mem_used, gres, gres_used = line.split()
    allocated, _idle, _other, total = cpus.split("/")
    used = dict(GRES.findall(gres_used))
    return Node(
        name=name,
        state=state,
        cpu_used=int(allocated),
        cpu_total=int(total),
        mem_used=int(mem_used),
        mem_total=int(mem_total),
        gpus={profile: (int(used[profile]), int(count)) for profile, count in GRES.findall(gres)},
    )


def parse_snapshot(text: str) -> Snapshot:
    sections: dict[str, list[str]] = {}
    # Not splitlines(): a carriage return inside a log line must not start a new line.
    for line in text.rstrip("\n").split("\n"):
        if line.startswith("@@"):
            current = sections.setdefault(line[2:], [])
        else:
            current.append(line)

    jobs = tuple(Job(*line.split("|")[:10]) for line in sections["jobs"])
    records = {}
    for line in sections["history"]:
        fields = line.split("|")
        fields[2] = fields[2].split()[0]  # "CANCELLED by 1234" -> "CANCELLED"
        fields[10:12] = tres(fields[10]), tres(fields[11])
        records[fields[-1]] = Record(*fields)
    history = [record for record in records.values() if record.state not in ACTIVE_STATES]
    # One line per job step: the peak values and the current ones. sstat prints an empty row ("|") for a step
    # that has just started and has no accounting yet: there is nothing to show for it, so it is left out.
    steps = [tuple(tres(part) for part in line.split("|")) for line in sections["usage"]]
    steps = [step for step in steps if step[0]]
    log_path, *log_lines = sections["log"] or [""]
    return Snapshot(
        jobs=jobs,
        nodes=tuple(parse_node(line) for line in sections["nodes"]),
        records=records,
        history=tuple(reversed(history)),
        usage=Usage(
            cpu_time=max((peak["cpu"] for peak, _ in steps), key=seconds),
            mem_mb=max(megabytes(peak["mem"]) for peak, _ in steps),
            gpu_mem_mb=max(megabytes(peak.get("gres/gpumem", "0")) for peak, _ in steps),
            mem_now_mb=max(megabytes(now["mem"]) for _, now in steps),
            gpu_mem_now_mb=max(megabytes(now.get("gres/gpumem", "0")) for _, now in steps),
        ) if steps else None,
        efficiency=dict(line.split(": ", 1) for line in sections["efficiency"] if ": " in line),
        log_path=log_path,
        # Progress bars rewrite a line with carriage returns: keep its final content only.
        log="\n".join(line.rsplit("\r", 1)[-1] for line in log_lines),
    )


def free_classes(node: Node) -> dict[str, int]:
    """Resource classes with a free GPU slice on the node, and how many slices are free."""
    free = {}
    for profile, name in CLASSES.items():
        used, total = node.gpus.get(profile, (0, 0))
        if total > used:
            free[name] = total - used
    return free


def free_text(node: Node) -> str:
    free = " · ".join(f"{name} {count}" for name, count in free_classes(node).items())
    return f"free now: {free}" if free else "no free GPU slice"


def target() -> str:
    """The SSH target, which `bin/hpc` passes in the environment."""
    found = os.environ.get("HPC_TARGET")
    if not found:
        raise SystemExit("HPC_TARGET is not set; run this through `bin/hpc`, which sets it from HPC_USER")
    return found


def events(previous: dict[str, str] | None, records: dict[str, Record], warned: set[str]) -> list[tuple[str, str]]:
    """Alerts as (title, message): state changes since the previous states, and jobs close to their limit.

    A job is added to `warned` when its time alert is raised, so that it is raised once.
    """
    found = []
    for raw, record in records.items():
        label = f"{record.id} {record.name}"
        before = (previous or {}).get(raw)
        if before and before != record.state:
            if record.state == "RUNNING":
                found.append(("Job started", f"{label} is running on {record.node}"))
            elif record.state not in ACTIVE_STATES:
                found.append((f"Job {record.state.lower()}", f"{label} ended after {record.elapsed}, exit code {record.exit_code}"))
        limit = seconds(record.limit)
        if record.state == "RUNNING" and limit and raw not in warned:
            left = limit - seconds(record.elapsed)
            if left <= (1 - TIME_WARNING) * limit:
                warned.add(raw)
                found.append(("Job almost out of time", f"{label} has {left // 60} min left of {record.limit}"))
    return found


class Cluster:
    """Runs commands on the head node over SSH, sharing one multiplexed connection."""

    def __init__(self, target: str):
        self.target = target

    def argv(self, command: str, tty: bool = False) -> list[str]:
        # A terminal session gets a connection of its own: inside the shared one it can freeze
        # the connection, and with it every later command.
        connection = ["-o", "ControlPath=none", "-t"] if tty else [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=~/.ssh/hpc-top-%C",
            "-o", "ControlPersist=60",
            # A shared connection that has died is dropped instead of hanging its users.
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
        ]
        return [
            "ssh",
            "-o", "ConnectTimeout=10",  # an unreachable cluster (VPN down) is reported quickly
            *connection,
            self.target,
            # No login shell: it would run the user's profile a second time, about one second per command.
            "module load slurm && " + command,
        ]

    def run(self, command: str) -> str:
        """Run a command and return its output.

        A non-zero exit raises CalledProcessError; no answer within RUN_TIMEOUT raises TimeoutExpired.
        """
        # Decoded by hand: text mode would turn the carriage returns of progress bars into new lines.
        try:
            return subprocess.run(
                self.argv(command), check=True, capture_output=True, timeout=RUN_TIMEOUT
            ).stdout.decode(errors="replace")
        except subprocess.CalledProcessError as error:
            error.stderr = error.stderr.decode(errors="replace")
            raise

    def tunnel_argv(self, port: int, node: str) -> list[str]:
        # A connection of its own: a forward added to the shared one would outlive the tunnel.
        return [
            "ssh", "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-L", f"{port}:{node}:{port}",
            self.target,
        ]

    def tunnel(self, port: int, node: str) -> subprocess.Popen:
        """Forward localhost:port to the same port of a compute node, until the process is terminated."""
        return subprocess.Popen(
            self.tunnel_argv(port, node),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    @staticmethod
    def port_answers(port: int, attempts: int = 20) -> bool:
        """Whether a server answers behind the tunnel on localhost:port.

        ssh accepts the local connection in any case and drops it at once when nothing listens
        on the node, so a connection that stays open (or sends data) is the sign of a server.
        """
        for _ in range(attempts):
            try:
                connection = socket.create_connection(("localhost", port), timeout=2)
            except ConnectionRefusedError:  # the local end of the tunnel is not open yet
                time.sleep(0.25)
                continue
            with connection:
                try:
                    return connection.recv(1) != b""
                except TimeoutError:  # open and waiting for a request, as an HTTP server does
                    return True
                except ConnectionResetError:
                    return False
        return False

    def interactive(self, command: str) -> None:
        """Run a full-screen command (a pager) attached to the local terminal."""
        subprocess.run(self.argv(command, tty=True))
