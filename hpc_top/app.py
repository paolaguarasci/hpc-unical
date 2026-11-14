"""The Textual application behind `hpc top`."""

from __future__ import annotations

import json
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import PurePosixPath

from rich.text import Text
from textual import work
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.theme import Theme
from textual.widgets import DataTable, Footer, Input, RichLog, Static

from hpc_top.data import Cluster, Job, Record, Snapshot, events, parse_snapshot, snapshot_command, target
from hpc_top.widgets import ACCENT, HOT, LINE, SKY, WARM, DetailsPanel, NodePanel, clock, state_text

REFRESH_SECONDS = 5
CLUSTER_ERRORS = (subprocess.CalledProcessError, subprocess.TimeoutExpired)

THEME = Theme(
    name="hpc",
    dark=True,
    primary=ACCENT,
    secondary="#7FD4FF",
    accent=ACCENT,
    foreground="#E4F0E7",
    background="#06120E",
    surface="#0C1E18",
    panel=LINE,
    success="#3DDC97",
    warning=WARM,
    error=HOT,
)


class ConfirmCancel(ModalScreen[bool]):
    """Asks before cancelling a job; dismisses with the answer."""

    BINDINGS = [("y", "answer(True)", "Yes"), ("n", "answer(False)", "No"), ("escape", "answer(False)", "No")]

    def __init__(self, job: Job):
        super().__init__()
        self.job = job

    def compose(self) -> ComposeResult:
        yield Static(
            Text.assemble(
                ("Cancel job ", "bold"), (f"{self.job.id} {self.job.name}", f"bold {HOT}"), ("?\n\n", "bold"),
                ("y", f"bold {ACCENT}"), " yes    ", ("n", f"bold {ACCENT}"), " no",
            ),
            id="confirm",
        )

    def action_answer(self, answer: bool) -> None:
        self.dismiss(answer)


class PortPrompt(ModalScreen[int | None]):
    """Asks for the port of a server running inside a job; dismisses with it, or None when cancelled."""

    AUTO_FOCUS = "#port"  # the application-wide default points at the job table
    BINDINGS = [("escape", "dismiss(None)", "Cancel")]

    def __init__(self, job: Job):
        super().__init__()
        self.job = job

    def compose(self) -> ComposeResult:
        prompt = Input(type="integer", placeholder="port on the node, e.g. 8000", id="port")
        prompt.border_title = f"Tunnel to {self.job.id} {self.job.name} on {self.job.where}"
        yield prompt

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(int(event.value) if event.value else None)


def desktop_notification(title: str, message: str) -> None:
    """A macOS notification through osascript; on other systems the alert stays inside the view."""
    if sys.platform == "darwin":
        script = f"display notification {json.dumps(message)} with title {json.dumps(title)}"
        subprocess.run(["osascript", "-e", script])


class TopApp(App):
    CSS_PATH = "top.tcss"
    AUTO_FOCUS = "#jobs"
    TITLE = "hpc top"
    ENABLE_COMMAND_PALETTE = False
    BINDINGS = [
        ("q", "quit", "Quit"),
        ("r", "reload", "Refresh"),
        ("c", "cancel_job", "Cancel job"),
        ("l", "full_log", "Full log"),
        ("t", "tunnel", "Tunnel"),
        ("a", "toggle_everyone", "All / my jobs"),
    ]

    def __init__(self, cluster: Cluster, notifier=desktop_notification):
        super().__init__()
        self.cluster = cluster
        self.notifier = notifier
        self.states: dict[str, str] | None = None  # job states at the previous refresh
        self.warned: set[str] = set()  # jobs whose time alert has been raised
        # job ID -> [port, ssh process, whether a server answers (None while being checked)]
        self.tunnels: dict[str, list] = {}
        self.jobs: dict[str, Job | Record] = {}
        self.user = cluster.target.split("@")[0]
        self.everyone = False  # the job list shows the jobs of every user
        self.loading = False  # a refresh is in flight
        self.stale = False  # another refresh was requested meanwhile
        self.active = "jobs"  # the table whose highlighted row drives the log panel
        self.selected: tuple[str, str] | None = None  # (workdir, job ID)
        self.shown_log: tuple[str, str] | None = None
        self.log_path = ""
        # Widgets are held directly: a query would look at the confirmation dialog while it is open.
        self.title_bar = Static(id="title")
        self.node_row = Horizontal(id="nodes")
        self.node_panels: dict[str, NodePanel] = {}
        self.tables = {
            # The cursor keeps the state colours of the row it highlights.
            name: DataTable(id=name, cursor_type="row", cursor_foreground_priority="renderable")
            for name in ("jobs", "history")
        }
        self.details = DetailsPanel()
        self.log_panel = RichLog(id="log", wrap=True, min_width=1)

    def compose(self) -> ComposeResult:
        yield self.title_bar
        yield self.node_row
        with Horizontal(id="middle"):
            yield self.tables["jobs"]
            with Vertical(id="side"):
                yield self.details
                yield self.log_panel
        yield self.tables["history"]
        yield Footer()

    def on_mount(self) -> None:
        self.register_theme(THEME)
        self.theme = THEME.name
        self.title_jobs()
        history = self.tables["history"]
        history.border_title = "Last 24 h"
        history.add_columns("ID", "Name", "State", "Elapsed", "Exit")
        self.log_panel.border_title = "Log"
        self.load()
        self.set_interval(REFRESH_SECONDS, self.load)

    def title_jobs(self) -> None:
        """Title and columns of the job list, which gains the user when it shows everyone's jobs."""
        jobs = self.tables["jobs"]
        jobs.clear(columns=True)
        jobs.border_title = "All jobs" if self.everyone else "My jobs"
        if self.everyone:
            jobs.add_column("User")
        jobs.add_columns("ID", "Name", "State", "Time", "Limit", "QoS", "Node / reason", "Tunnel")

    def foreign(self, job: Job | Record) -> bool:
        """Whether the job belongs to another user: it is listed, but never read or acted upon."""
        return isinstance(job, Job) and job.user != self.user

    def load(self) -> None:
        """Request a refresh. Refreshes never overlap: one asked for while another runs follows it."""
        if self.loading:
            self.stale = True
            return
        self.loading, self.stale = True, False
        self.fetch(self.selected, self.everyone)

    @work(thread=True)
    def fetch(self, selected: tuple[str, str] | None, everyone: bool) -> None:
        try:
            snapshot = parse_snapshot(self.cluster.run(snapshot_command(selected, everyone)))
        except CLUSTER_ERRORS as error:
            self.call_from_thread(self.loaded, None, selected, everyone, error)
        else:
            self.call_from_thread(self.loaded, snapshot, selected, everyone, None)

    def loaded(
        self, snapshot: Snapshot | None, selected: tuple[str, str] | None, everyone: bool, error: Exception | None
    ) -> None:
        self.loading = False
        if error:
            self.report(error)
        elif everyone == self.everyone:  # otherwise the list was switched meanwhile and a refresh follows
            self.show(snapshot, selected)
        if self.stale:
            self.load()

    def report(self, error: Exception) -> None:
        if isinstance(error, subprocess.TimeoutExpired):
            message = f"No answer from the cluster within {error.timeout:g} seconds."
        else:
            message = error.stderr.strip() or str(error)
        self.notify(message, title="Cluster command failed", severity="error")

    def show(self, snapshot: Snapshot, selected: tuple[str, str] | None) -> None:
        # By raw job ID, which is the row key of both tables.
        self.jobs = {**{record.raw: record for record in snapshot.history}, **{job.id: job for job in snapshot.jobs}}
        for title, message in events(self.states, snapshot.records, self.warned):
            self.notify(message, title=title)
            self.notifier(title, message)
        self.states = {job_id: record.state for job_id, record in snapshot.records.items()}
        running = {job.id for job in snapshot.jobs if job.state == "RUNNING"}
        for job_id, (port, process, _) in list(self.tunnels.items()):
            if job_id not in running or process.poll() is not None:
                process.terminate()
                del self.tunnels[job_id]
                self.notify(f"The tunnel on port {port} of job {job_id} is closed.", severity="warning")
        states = [job.state for job in snapshot.jobs if not self.foreign(job)]
        self.title_bar.update(
            f" hpc top   {self.cluster.target}   ● {states.count('RUNNING')} running"
            f"   ● {states.count('PENDING')} pending   updated {datetime.now():%H:%M:%S}"
        )
        for node in snapshot.nodes:
            if node.name in self.node_panels:
                self.node_panels[node.name].show(node)
            else:
                self.node_panels[node.name] = NodePanel(node)
                self.node_row.mount(self.node_panels[node.name])
        self.fill(
            "jobs",
            [
                (
                    j.id,
                    (
                        *([j.user] if self.everyone else []),
                        j.id, j.name, state_text(j.state), j.elapsed, j.limit, j.qos, self.where(j), self.tunnel_cell(j.id),
                    ),
                )
                for j in snapshot.jobs
            ],
        )
        self.fill(
            "history",
            [
                (j.raw, (j.id, j.name, state_text(j.state), j.elapsed, Text(j.exit_code, style="" if j.exit_code == "0:0" else HOT)))
                for j in snapshot.history
            ],
        )
        if selected == self.selected:
            record = snapshot.records.get(selected[1]) if selected else None
            self.details.show(record, snapshot.usage, snapshot.efficiency)
        if selected == self.selected and (snapshot.log_path, snapshot.log) != self.shown_log:
            self.shown_log = (snapshot.log_path, snapshot.log)
            self.log_path = snapshot.log_path
            log = self.log_panel
            log.clear()
            if snapshot.log_path:
                log.border_title = f"Log · {PurePosixPath(snapshot.log_path).name}"
                log.write(Text.from_ansi(snapshot.log))
            elif selected:
                log.border_title = f"Log · no *-{selected[1]}.out in {selected[0]}"
            else:
                log.border_title = "Log"
        self.sync_selection()

    @staticmethod
    def where(job: Job) -> str:
        """The node of a running job; the pending reason, with the estimated start when Slurm gives one."""
        if job.state == "PENDING" and job.start[:1].isdigit():
            return f"{job.where} · est. {clock(job.start)}"
        return job.where

    def tunnel_cell(self, job_id: str) -> Text:
        if job_id not in self.tunnels:
            return Text()
        port, _, answers = self.tunnels[job_id]
        if answers is False:
            return Text(f"localhost:{port} ✗ no server", style=f"bold {HOT}")
        return Text(f"localhost:{port} {'✓' if answers else '…'}", style=f"bold {SKY}")

    def fill(self, table_id: str, rows: list[tuple[str, tuple]]) -> None:
        """Replace the rows of a table, keeping the cursor on the same job when it is still listed."""
        table = self.tables[table_id]
        current = self.cursor_job(table)
        table.clear()
        for key, cells in rows:
            table.add_row(*cells, key=key)
        if current in table.rows:
            table.move_cursor(row=table.get_row_index(current))

    @staticmethod
    def cursor_job(table: DataTable) -> str | None:
        if not table.row_count:
            return None
        return table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value

    def sync_selection(self) -> None:
        """Follow the highlighted row of the active table; a new selection triggers a reload for its log."""
        job_id = self.cursor_job(self.tables[self.active])
        selected = (self.jobs[job_id].workdir, job_id) if job_id and not self.foreign(self.jobs[job_id]) else None
        if selected != self.selected:
            self.selected = selected
            self.load()

    def on_data_table_row_highlighted(self) -> None:
        self.sync_selection()

    def on_descendant_focus(self, event) -> None:
        if isinstance(event.widget, DataTable):
            self.active = event.widget.id
            self.sync_selection()

    def action_reload(self) -> None:
        self.load()

    def action_toggle_everyone(self) -> None:
        self.everyone = not self.everyone
        self.title_jobs()
        self.load()

    def action_cancel_job(self) -> None:
        job_id = self.cursor_job(self.tables["jobs"])
        if self.active != "jobs" or not job_id or self.foreign(self.jobs[job_id]):
            self.notify("Select one of your pending or running jobs first.", severity="warning")
            return
        self.push_screen(ConfirmCancel(self.jobs[job_id]), lambda confirmed: confirmed and self.cancel(job_id))

    @work(thread=True)
    def cancel(self, job_id: str) -> None:
        try:
            self.cluster.run(f"scancel {shlex.quote(job_id)}")
        except CLUSTER_ERRORS as error:
            self.call_from_thread(self.report, error)
            return
        self.call_from_thread(self.load)

    def action_tunnel(self) -> None:
        job = self.jobs.get(self.cursor_job(self.tables["jobs"]))
        if self.active != "jobs" or not job or job.state != "RUNNING" or self.foreign(job):
            self.notify("Select one of your running jobs first.", severity="warning")
        elif job.id in self.tunnels:
            port, process, _ = self.tunnels.pop(job.id)
            process.terminate()
            self.notify(f"Tunnel on port {port} closed.")
            self.load()
        else:
            self.push_screen(PortPrompt(job), lambda port: port and self.open_tunnel(job, port))

    def open_tunnel(self, job: Job, port: int) -> None:
        self.tunnels[job.id] = [port, self.cluster.tunnel(port, job.where), None]
        self.check_tunnel(job, port)
        self.load()

    @work(thread=True)
    def check_tunnel(self, job: Job, port: int) -> None:
        answers = self.cluster.port_answers(port)
        self.call_from_thread(self.tunnel_checked, job, port, answers)

    def tunnel_checked(self, job: Job, port: int, answers: bool) -> None:
        if job.id not in self.tunnels or self.tunnels[job.id][0] != port:
            return  # closed in the meantime
        self.tunnels[job.id][2] = answers
        if answers:
            self.notify(f"http://localhost:{port} reaches {job.where}:{port}; press t again to close.", title="Tunnel open")
        else:
            self.notify(
                f"No server answers on {job.where}:{port}. Check the port in the log, then press t to close the tunnel.",
                title="Tunnel open, but nothing listens",
                severity="error",
            )
        self.load()

    def on_unmount(self) -> None:
        for _, process, _ in self.tunnels.values():
            process.terminate()

    def action_full_log(self) -> None:
        if not self.log_path:
            self.notify("The selected job has no log file.", severity="warning")
            return
        with self.suspend():
            self.cluster.interactive(f"less +G {shlex.quote(self.log_path)}")


def main() -> None:
    TopApp(Cluster(target())).run()
