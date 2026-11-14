"""Offline tests for the interactive view: parsers, rendering and the Textual application."""

import socket
import subprocess
import threading
import unittest

from textual.widgets import DataTable
from textual.worker import WorkerCancelled

from hpc_top.app import TopApp
from hpc_top.data import NODES_COMMAND, Cluster, events, free_classes, megabytes, parse_snapshot, seconds, snapshot_command
from hpc_top.free import report
from hpc_top.widgets import DetailsPanel, NodePanel, bar, details_text, spark

# Output captured from the real cluster on 2026-11-13, with the login replaced.
SNAPSHOT = """\
@@jobs
10183|vllm-serve|RUNNING|3:59|30:00|scavenger|ainode02|/home/u1/projects/femtools-cluster|2026-11-13T21:57:15|u1|
10184|fem-l0|PENDING|0:00|1:00:00|scavenger|(Priority)|/home/u1/projects/femtools|2026-11-13T23:10:00|u1|
@@nodes
ainode01 mixed 30/66/0/96 2063758 983040 gpu:7g.141gb:4(S:0),gpu:4g.71gb:4(S:1),gpu:2g.35gb:4(S:1),gpu:1g.35gb:4(S:1) gpu:7g.141gb:0(IDX:N/A),gpu:4g.71gb:0(IDX:N/A),gpu:2g.35gb:0(IDX:N/A),gpu:1g.35gb:0(IDX:N/A)
ainode02 mixed 26/70/0/96 2063758 409600 gpu:7g.141gb:4(S:0),gpu:4g.71gb:4(S:1),gpu:2g.35gb:4(S:1),gpu:1g.35gb:4(S:1) gpu:7g.141gb:1(IDX:0),gpu:4g.71gb:2(IDX:4,7),gpu:2g.35gb:0(IDX:N/A),gpu:1g.35gb:2(IDX:6,9)
@@history
10180|vllm-env|FAILED|00:00:02|1:0|/home/u1/projects/femtools-cluster|2026-11-13T21:39:31|2026-11-13T21:39:31|2026-11-13T21:39:33|01:00:00|billing=4,cpu=4,mem=32G,node=1|billing=4,cpu=4,mem=32G,node=1|ainode02|jupyter_users|10180
10181|vllm-env|COMPLETED|00:16:03|0:0|/home/u1/projects/femtools-cluster|2026-11-13T21:39:31|2026-11-13T21:39:31|2026-11-13T21:39:33|01:00:00|billing=4,cpu=4,mem=32G,node=1|billing=4,cpu=4,mem=32G,node=1|ainode02|jupyter_users|10181
10122|probe-tunnel|CANCELLED by 1234|00:00:08|0:0|/home/u1/projects/hpc|2026-11-13T21:39:31|2026-11-13T21:39:31|2026-11-13T21:39:33|01:00:00|billing=4,cpu=4,mem=32G,node=1|billing=4,cpu=4,mem=32G,node=1|ainode02|jupyter_users|10122
10183|vllm-serve|RUNNING|00:14:27|0:0|/home/u1/projects/femtools-cluster|2026-11-13T21:57:14|2026-11-13T21:57:15|Unknown|00:30:00|billing=6,cpu=6,gres/gpu:4g.71gb=1,gres/gpu=1,mem=128G,node=1|billing=6,cpu=6,gres/gpu:4g.71gb=1,gres/gpu=1,mem=128G,node=1|ainode02|jupyter_users|10183
@@log
/home/u1/projects/femtools-cluster/vllm-serve-10183.out
Downloading a\rDownloading b
server ready
@@usage
cpu=00:00:01,energy=0,gres/gpumem=0,gres/gpuutil=0,mem=1024K|cpu=00:00:01,energy=0,gres/gpumem=0,gres/gpuutil=0,mem=1M
cpu=00:03:20,energy=0,fs/disk=26985533053,gres/gpumem=51880M,gres/gpuutil=0,mem=8658528K,pages=23165,vmem=108077292K|cpu=00:03:20,energy=0,gres/gpumem=50000M,gres/gpuutil=0,mem=3868M
@@efficiency
Job ID: 10183
CPU Utilized: 00:03:05
CPU Efficiency: 4.80% of 01:04:12 core-walltime
Job Wall-clock time: 00:16:03
Memory Utilized: 762.18 MB
Memory Efficiency: 2.33% of 32.00 GB
"""

# The same snapshot when the jobs of every user are requested: one job of another user is listed.
EVERYONE = SNAPSHOT.replace(
    "@@nodes",
    "10190|train|RUNNING|1:00:00|2:00:00|scavenger|ainode01|/home/u2/projects/secret|2026-11-13T21:00:00|u2|\n@@nodes",
)

# A finished task of a job array: sacct shows ID_TASK, while the log is named after the raw job ID.
ARRAY = SNAPSHOT.replace(
    "@@log",
    "10211_1|demo|COMPLETED|00:00:09|0:0|/home/u1/projects/hpc|2026-11-13T22:00:00|2026-11-13T22:00:01|"
    "2026-11-13T22:00:10|00:02:00|billing=1,cpu=1,mem=16G,node=1|billing=1,cpu=1,mem=16G,node=1|ainode02|jupyter_users|10212\n@@log",
)


class FakeTunnel:
    closed = False

    def poll(self):
        return None

    def terminate(self):
        self.closed = True


class FakeCluster:
    target = "u1@hpcgate.unical.it"

    def __init__(self):
        self.commands = []
        self.output = SNAPSHOT
        self.tunnels = []

    def run(self, command):
        self.commands.append(command)
        return self.output

    def tunnel(self, port, node):
        self.tunnels.append((port, node, FakeTunnel()))
        return self.tunnels[-1][2]

    def port_answers(self, port):
        return port == 8000


async def settle(app, pilot):
    """Let the pending messages and snapshot workers finish; a superseded worker is cancelled."""
    for _ in range(4):
        await pilot.pause()
        try:
            await app.workers.wait_for_complete()
        except WorkerCancelled:
            pass
    await pilot.pause()


class ParseSnapshotTest(unittest.TestCase):
    def setUp(self):
        self.snapshot = parse_snapshot(SNAPSHOT)

    def test_jobs(self):
        running, pending = self.snapshot.jobs
        self.assertEqual(
            (running.id, running.name, running.state, running.elapsed, running.limit, running.qos, running.where),
            ("10183", "vllm-serve", "RUNNING", "3:59", "30:00", "scavenger", "ainode02"),
        )
        self.assertEqual(running.workdir, "/home/u1/projects/femtools-cluster")
        self.assertEqual(running.user, "u1")
        self.assertEqual((pending.state, pending.where), ("PENDING", "(Priority)"))

    def test_nodes(self):
        first, second = self.snapshot.nodes
        self.assertEqual((first.name, first.state, first.cpu_used, first.cpu_total), ("ainode01", "mixed", 30, 96))
        self.assertEqual((first.mem_used, first.mem_total), (983040, 2063758))
        self.assertEqual(
            second.gpus,
            {"7g.141gb": (1, 4), "4g.71gb": (2, 4), "2g.35gb": (0, 4), "1g.35gb": (2, 4)},
        )

    def test_history_keeps_only_finished_jobs(self):
        self.assertEqual([job.id for job in self.snapshot.history], ["10122", "10181", "10180"])
        cancelled = self.snapshot.history[0]
        self.assertEqual((cancelled.state, cancelled.exit_code), ("CANCELLED", "0:0"))

    def test_log(self):
        self.assertEqual(self.snapshot.log_path, "/home/u1/projects/femtools-cluster/vllm-serve-10183.out")
        self.assertEqual(self.snapshot.log, "Downloading b\nserver ready")

    def test_missing_log(self):
        snapshot = parse_snapshot("@@jobs\n@@nodes\n@@history\n@@log\n@@usage\n@@efficiency\n")
        self.assertEqual((snapshot.jobs, snapshot.log_path, snapshot.log, snapshot.usage), ((), "", "", None))

    def test_records_cover_running_jobs_too(self):
        record = self.snapshot.records["10183"]
        self.assertEqual((record.state, record.elapsed, record.limit), ("RUNNING", "00:14:27", "00:30:00"))
        self.assertEqual((record.submit, record.start, record.end), ("2026-11-13T21:57:14", "2026-11-13T21:57:15", "Unknown"))
        self.assertEqual(record.allocated["mem"], "128G")
        self.assertEqual(record.allocated["gres/gpu:4g.71gb"], "1")
        self.assertEqual((record.node, record.account), ("ainode02", "jupyter_users"))

    def test_array_task_is_keyed_by_its_raw_job_id(self):
        snapshot = parse_snapshot(ARRAY)
        self.assertEqual((snapshot.records["10212"].id, snapshot.records["10212"].raw), ("10211_1", "10212"))
        self.assertEqual(snapshot.records["10183"].raw, "10183")
        self.assertEqual(events({"10212": "RUNNING"}, snapshot.records, set())[0][0], "Job completed")

    def test_usage_takes_the_largest_step(self):
        usage = self.snapshot.usage
        self.assertEqual((usage.cpu_time, usage.mem_mb, usage.gpu_mem_mb), ("00:03:20", 8658528 / 1024, 51880))
        self.assertEqual((usage.mem_now_mb, usage.gpu_mem_now_mb), (3868, 50000))

    def test_efficiency_and_estimated_start(self):
        self.assertEqual(self.snapshot.efficiency["CPU Efficiency"], "4.80% of 01:04:12 core-walltime")
        self.assertEqual(self.snapshot.efficiency["Memory Utilized"], "762.18 MB")
        self.assertEqual(self.snapshot.jobs[1].start, "2026-11-13T23:10:00")

    def test_free_classes(self):
        first, second = self.snapshot.nodes
        self.assertEqual(free_classes(first), {"tiny": 4, "small": 4, "medium": 4, "large": 4})
        self.assertEqual(free_classes(second), {"tiny": 2, "small": 4, "medium": 2, "large": 3})


class EventsTest(unittest.TestCase):
    def records(self, text=SNAPSHOT):
        return parse_snapshot(text).records

    def test_first_snapshot_reports_no_transition(self):
        self.assertEqual(events(None, self.records(), set()), [])

    def test_start_and_end_are_reported_once(self):
        before = {"10183": "PENDING", "10181": "RUNNING", "10180": "FAILED"}
        found = events(before, self.records(), set())
        self.assertEqual([title for title, _ in found], ["Job completed", "Job started"])
        self.assertIn("10181 vllm-env", found[0][1])
        self.assertIn("ainode02", found[1][1])
        after = {job_id: record.state for job_id, record in self.records().items()}
        self.assertEqual(events(after, self.records(), set()), [])

    def test_time_warning_fires_once_at_ninety_percent(self):
        late = self.records(SNAPSHOT.replace("RUNNING|00:14:27", "RUNNING|00:27:30"))
        warned = set()
        (title, message), = events(None, late, warned)
        self.assertEqual(title, "Job almost out of time")
        self.assertIn("2 min left", message)
        self.assertEqual(events(None, late, warned), [])

    def test_units(self):
        self.assertEqual((megabytes("128G"), megabytes("512M"), megabytes("2048K"), megabytes("0")), (131072, 512, 2, 0))
        self.assertEqual((seconds("00:30:00"), seconds("1-00:00:01"), seconds("UNLIMITED")), (1800, 86401, None))


class DetailsTest(unittest.TestCase):
    def setUp(self):
        self.snapshot = parse_snapshot(SNAPSHOT)

    def test_running_job_shows_usage_against_the_request(self):
        text = details_text(self.snapshot.records["10183"], self.snapshot.usage, {}, 70).plain
        for expected in ("RUNNING", "ainode02", "queued 0:00:01", "ends 22:27:15", "14:27 / 30:00",
                         "8.3 / 128 GB", "50.7 / 71 GB", "4g.71gb", "6 cores", "00:03:20"):
            self.assertIn(expected, text)

    def test_pending_job_has_no_allocation_yet(self):
        line = ("10184|fem-l0|PENDING|00:00:00|0:0|/home/u1/projects/femtools|2026-11-13T22:00:00|Unknown|Unknown|"
                "01:00:00|billing=2,cpu=2,gres/gpu:1g.35gb=1,gres/gpu=1,mem=32G,node=1||None assigned|jupyter_users|10184")
        record = parse_snapshot(f"@@jobs\n@@nodes\n@@history\n{line}\n@@log\n@@usage\n@@efficiency\n").records["10184"]
        text = details_text(record, None, {}, 70).plain
        for expected in ("PENDING", "not started", "2 cores", "32 GB requested", "GPU 1g.35gb"):
            self.assertIn(expected, text)

    def test_finished_job_without_usage_or_gpu(self):
        text = details_text(self.snapshot.records["10180"], None, self.snapshot.efficiency, 70).plain
        for expected in ("FAILED", "ended 21:39:33", "32 GB requested", "no GPU", "4 cores",
                         "CPU efficiency 4.80%", "memory 762.18 MB (2.33% of 32.00 GB)"):
            self.assertIn(expected, text)

    def test_oversized_memory_request_is_flagged_after_five_minutes(self):
        record, usage = self.snapshot.records["10183"], self.snapshot.usage
        self.assertIn("RAM peak is 6% of the request", details_text(record, usage, {}, 70).plain)
        early = parse_snapshot(SNAPSHOT.replace("RUNNING|00:14:27", "RUNNING|00:04:59")).records["10183"]
        self.assertNotIn("of the request", details_text(early, usage, {}, 70).plain)


class CommandTest(unittest.TestCase):
    def test_snapshot_without_selection_reads_no_log(self):
        command = snapshot_command(None)
        for tool in ("squeue", "sinfo", "sacct"):
            self.assertIn(tool, command)
        self.assertNotIn("tail", command)
        self.assertNotIn("sstat", command)

    def test_snapshot_lists_my_jobs_unless_everyone_is_asked(self):
        self.assertIn('squeue -h -u "$USER"', snapshot_command(None))
        everyone = snapshot_command(None, everyone=True)
        self.assertIn("squeue -h -O", everyone)
        self.assertNotIn("-u", everyone.split("echo @@nodes")[0])
        self.assertIn("UserName", everyone)

    def test_free_report_lists_the_free_classes_of_each_node(self):
        self.assertIn(NODES_COMMAND, snapshot_command(None))
        self.assertEqual(
            report(parse_snapshot(SNAPSHOT).nodes),
            "ainode01  free now: tiny 4 · small 4 · medium 4 · large 4\n"
            "ainode02  free now: tiny 2 · small 4 · medium 2 · large 3",
        )

    def test_snapshot_tails_the_log_of_the_selected_job(self):
        command = snapshot_command(("/home/u1/my project", "10183"))
        self.assertIn("'/home/u1/my project'/*-10183.out", command)
        self.assertIn("tail -n", command)
        self.assertIn("sstat -a -n -P -j 10183", command)
        self.assertIn("seff 10183", command)

    def test_tunnel_forwards_the_port_through_the_head_node(self):
        argv = Cluster("u1@hpcgate.unical.it").tunnel_argv(8000, "ainode02")
        self.assertEqual(argv[:2], ["ssh", "-N"])
        self.assertIn("8000:ainode02:8000", argv)
        self.assertEqual(argv[-1], "u1@hpcgate.unical.it")

    def test_ssh_argv_loads_slurm_on_the_target(self):
        argv = Cluster("u1@hpcgate.unical.it").argv("squeue")
        self.assertEqual(argv[0], "ssh")
        self.assertIn("u1@hpcgate.unical.it", argv)
        self.assertEqual(argv[-1], "bash -lc 'module load slurm && squeue'")
        self.assertNotIn("-t", argv)

    def test_interactive_commands_stay_off_the_shared_connection(self):
        # A terminal session inside the shared connection froze it for every later refresh.
        argv = Cluster("u1@hpcgate.unical.it").argv("less f", tty=True)
        self.assertIn("-t", argv)
        self.assertIn("ControlPath=none", argv)
        self.assertNotIn("ControlMaster=auto", argv)


class PortAnswersTest(unittest.TestCase):
    def serve(self, handler):
        """A local server on a free port that passes each connection to the handler."""
        server = socket.create_server(("localhost", 0))
        self.addCleanup(server.close)

        def loop():
            while True:
                try:
                    connection, _ = server.accept()
                except OSError:
                    return
                handler(connection)

        threading.Thread(target=loop, daemon=True).start()
        return server.getsockname()[1]

    def test_a_server_waiting_for_a_request_answers(self):
        held = []
        self.assertTrue(Cluster.port_answers(self.serve(held.append)))

    def test_a_connection_closed_at_once_does_not_answer(self):
        # What the local end of an SSH tunnel does when nothing listens on the node.
        self.assertFalse(Cluster.port_answers(self.serve(lambda connection: connection.close())))

    def test_a_closed_local_port_does_not_answer(self):
        server = socket.create_server(("localhost", 0))
        port = server.getsockname()[1]
        server.close()
        self.assertFalse(Cluster.port_answers(port, attempts=2))


class BarTest(unittest.TestCase):
    def test_filled_cells_follow_the_fraction(self):
        self.assertEqual(bar(1, 4, 8).plain, "██░░░░░░")
        self.assertEqual(bar(0, 4, 8).plain, "░░░░░░░░")
        self.assertEqual(bar(4, 4, 8).plain, "████████")

    def test_spark_keeps_the_latest_values(self):
        self.assertEqual(spark([0, 0.5, 1], 3).plain, "▁▅█")
        self.assertEqual(spark([0, 0.5, 1], 2).plain, "▅█")


class TopAppTest(unittest.IsolatedAsyncioTestCase):
    async def test_shows_cluster_jobs_history_and_log(self):
        cluster = FakeCluster()
        app = TopApp(cluster, notifier=lambda *_: None)
        async with app.run_test(size=(120, 40)) as pilot:
            await settle(app, pilot)
            self.assertEqual(len(app.query(NodePanel)), 2)
            details = app.query_one(DetailsPanel)
            self.assertEqual(details.border_title, "Details · 10183 vllm-serve")
            self.assertIn("50.7 / 71 GB", details.render().plain)
            self.assertEqual(app.query_one("#jobs", DataTable).row_count, 2)
            self.assertEqual(app.query_one("#history", DataTable).row_count, 3)
            # The first job is selected, so its log is requested and shown.
            self.assertIn("*-10183.out", cluster.commands[-1])
            self.assertEqual(app.query_one("#log").border_title, "Log · vllm-serve-10183.out")
            self.assertIn("server ready", "\n".join(line.text for line in app.query_one("#log").lines))

    async def test_shows_free_classes_and_estimated_start(self):
        app = TopApp(FakeCluster(), notifier=lambda *_: None)
        async with app.run_test(size=(140, 44)) as pilot:
            await settle(app, pilot)
            self.assertEqual(app.node_panels["ainode02"].border_subtitle, "free now: tiny 2 · small 4 · medium 2 · large 3")
            self.assertIn("est. 23:10:00", str(app.tables["jobs"].get_row("10184")[6]))

    async def test_state_change_sends_a_desktop_notification(self):
        cluster, sent = FakeCluster(), []
        app = TopApp(cluster, notifier=lambda title, message: sent.append((title, message)))
        async with app.run_test(size=(140, 44)) as pilot:
            await settle(app, pilot)
            self.assertEqual(sent, [])
            cluster.output = SNAPSHOT.replace("10183|vllm-serve|RUNNING|00:14:27", "10183|vllm-serve|FAILED|00:14:27")
            await pilot.press("r")
            await settle(app, pilot)
            self.assertEqual([title for title, _ in sent], ["Job failed"])

    async def test_tunnel_opens_on_the_node_of_the_job_and_closes(self):
        cluster = FakeCluster()
        app = TopApp(cluster, notifier=lambda *_: None)
        async with app.run_test(size=(140, 44)) as pilot:
            await settle(app, pilot)
            await pilot.press("t")
            await pilot.pause()
            await pilot.press("8", "0", "0", "0", "enter")
            await settle(app, pilot)
            port, node, tunnel = cluster.tunnels[0]
            self.assertEqual((port, node), (8000, "ainode02"))
            self.assertEqual(str(app.tables["jobs"].get_row("10183")[7]), "localhost:8000 ✓")
            await pilot.press("t")
            await settle(app, pilot)
            self.assertTrue(tunnel.closed)
            self.assertEqual(app.tunnels, {})

    async def test_tunnel_to_a_port_without_a_server_is_marked(self):
        app = TopApp(FakeCluster(), notifier=lambda *_: None)
        async with app.run_test(size=(140, 44)) as pilot:
            await settle(app, pilot)
            await pilot.press("t")
            await pilot.pause()
            await pilot.press("7", "8", "9", "0", "enter")
            await settle(app, pilot)
            self.assertEqual(str(app.tables["jobs"].get_row("10183")[7]), "localhost:7890 ✗ no server")

    async def test_refreshes_never_overlap(self):
        cluster, release = FakeCluster(), threading.Event()
        answer, started = cluster.run, []

        def slow(command):
            started.append(command)
            release.wait(5)
            return answer(command)

        cluster.run = slow
        app = TopApp(cluster, notifier=lambda *_: None)
        async with app.run_test(size=(140, 44)) as pilot:
            await pilot.press("r", "r", "r")
            await pilot.pause(0.2)
            self.assertEqual(len(started), 1)
            release.set()
            await settle(app, pilot)
            self.assertEqual(app.tables["jobs"].row_count, 2)

    async def test_a_cluster_that_does_not_answer_is_reported(self):
        cluster = FakeCluster()

        def hang(command):
            raise subprocess.TimeoutExpired(command, 30)

        cluster.run = hang
        app = TopApp(cluster, notifier=lambda *_: None)
        async with app.run_test(size=(140, 44)) as pilot:
            await settle(app, pilot)
            self.assertFalse(app.loading)
            self.assertEqual(app.tables["jobs"].row_count, 0)

    async def test_log_of_a_finished_array_task_is_found_by_its_raw_job_id(self):
        cluster = FakeCluster()
        cluster.output = ARRAY
        app = TopApp(cluster, notifier=lambda *_: None)
        async with app.run_test(size=(140, 44)) as pilot:
            await settle(app, pilot)
            history = app.tables["history"]
            history.focus()
            history.move_cursor(row=history.get_row_index("10212"))
            await settle(app, pilot)
            self.assertEqual(history.get_row("10212")[0], "10211_1")
            self.assertIn("/home/u1/projects/hpc/*-10212.out", cluster.commands[-1])
            self.assertEqual(app.query_one(DetailsPanel).border_title, "Details · 10211_1 demo")

    async def test_a_key_lists_the_jobs_of_every_user_and_back(self):
        cluster = FakeCluster()
        app = TopApp(cluster, notifier=lambda *_: None)
        async with app.run_test(size=(140, 44)) as pilot:
            await settle(app, pilot)
            jobs = app.tables["jobs"]
            self.assertEqual(jobs.border_title, "My jobs")
            self.assertIn('-u "$USER"', cluster.commands[-1])
            cluster.output = EVERYONE
            await pilot.press("a")
            await settle(app, pilot)
            self.assertEqual(jobs.border_title, "All jobs")
            self.assertNotIn('-u "$USER"', cluster.commands[-1])
            self.assertEqual(jobs.row_count, 3)
            self.assertEqual(jobs.get_row("10190")[0], "u2")
            # Only my jobs are counted in the title bar.
            self.assertIn("1 running", str(app.title_bar.content))
            cluster.output = SNAPSHOT
            await pilot.press("a")
            await settle(app, pilot)
            self.assertEqual(jobs.border_title, "My jobs")
            self.assertIn('-u "$USER"', cluster.commands[-1])
            self.assertEqual(jobs.get_row("10183")[0], "10183")

    async def test_a_job_of_another_user_is_listed_but_left_alone(self):
        cluster = FakeCluster()
        cluster.output = EVERYONE
        app = TopApp(cluster, notifier=lambda *_: None)
        async with app.run_test(size=(140, 44)) as pilot:
            await settle(app, pilot)
            await pilot.press("a")
            await settle(app, pilot)
            app.tables["jobs"].move_cursor(row=app.tables["jobs"].get_row_index("10190"))
            await settle(app, pilot)
            # Its log, usage and efficiency are not read.
            self.assertIsNone(app.selected)
            self.assertNotIn("secret", cluster.commands[-1])
            self.assertNotIn("10190", cluster.commands[-1])
            await pilot.press("c")
            await pilot.pause()
            await pilot.press("y")
            await pilot.press("t")
            await settle(app, pilot)
            self.assertFalse([c for c in cluster.commands if c.startswith("scancel")])
            self.assertEqual(cluster.tunnels, [])

    async def test_cancel_asks_for_confirmation(self):
        cluster = FakeCluster()
        app = TopApp(cluster, notifier=lambda *_: None)
        async with app.run_test(size=(120, 40)) as pilot:
            await settle(app, pilot)
            await pilot.press("c")
            await pilot.pause()
            self.assertNotIn("scancel 10183", cluster.commands)
            await pilot.press("y")
            await settle(app, pilot)
            self.assertIn("scancel 10183", cluster.commands)

    async def test_cancel_can_be_declined(self):
        cluster = FakeCluster()
        app = TopApp(cluster, notifier=lambda *_: None)
        async with app.run_test(size=(120, 40)) as pilot:
            await settle(app, pilot)
            await pilot.press("c")
            await pilot.pause()
            await pilot.press("n")
            await settle(app, pilot)
            self.assertFalse([c for c in cluster.commands if c.startswith("scancel")])


if __name__ == "__main__":
    unittest.main()
