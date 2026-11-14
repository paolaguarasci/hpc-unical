"""Rendering helpers and widgets: usage bars, job states and the node panel."""

from __future__ import annotations

from collections import deque
from datetime import datetime, timedelta

from rich.text import Text
from textual.widget import Widget

from hpc_top.data import WASTE_AFTER, Node, Record, Usage, free_text, megabytes, seconds

# Palette shared with the public page (site-src/input.css).
ACCENT = "#C6FF3D"
MUTE = "#86A092"
LINE = "#243E33"
WARM = "#FFD23D"
HOT = "#FF5C5C"
SKY = "#7FD4FF"
LOAD_SHADES = (ACCENT, WARM, HOT)  # CPU and memory
SLICE_SHADES = (SKY, "#B48CFF", "#FF6BD6")  # GPU slices
TREND_SAMPLES = 240  # refreshes kept for the trend lines

STATE_STYLES = {
    "RUNNING": f"bold {ACCENT}",
    "COMPLETED": "#3DDC97",
    "PENDING": WARM,
    "CANCELLED": "#FF9F3D",
    "FAILED": f"bold {HOT}",
    "TIMEOUT": "#FF6BD6",
    "PREEMPTED": "#B48CFF",
    "OUT_OF_MEMORY": f"bold {HOT}",
    "NODE_FAIL": f"bold {HOT}",
}


def state_text(state: str) -> Text:
    return Text(f"● {state}", style=STATE_STYLES.get(state, MUTE))


def bar(used: float, total: float, width: int, shades: tuple[str, str, str] = LOAD_SHADES) -> Text:
    """A usage bar whose filled cells move through three shades towards the right end.

    Custom because Rich and Textual bars are single-colour; the per-cell gradient is the point.
    """
    filled = round(width * used / total) if total else 0
    text = Text()
    for cell in range(width):
        position = cell / width
        colour = shades[0] if position < 0.5 else shades[1] if position < 0.8 else shades[2]
        text.append("█" if cell < filled else "░", style=colour if cell < filled else LINE)
    return text


def spark(values, width: int, colour: str = ACCENT) -> Text:
    """The latest `width` values (each between 0 and 1) as a one-line chart.

    Custom because Textual offers a sparkline only as a widget, not as text inside a panel.
    """
    blocks = "▁▂▃▄▅▆▇█"
    return Text("".join(blocks[min(int(value * 8), 7)] for value in list(values)[-width:]), style=colour)


def trends_text(rows: list[tuple[str, deque, str]], width: int) -> Text:
    """One labelled trend per row: (label, values, colour)."""
    label_width = max(len(label) for label, *_ in rows) + 1
    text = Text()
    for index, (label, values, colour) in enumerate(rows):
        if index:
            text.append("\n")
        text.append(label.ljust(label_width), style=MUTE)
        text.append_text(spark(values, max(width - label_width, 1), colour))
    return text


def bars_text(rows: list[tuple[str, float, float, str, tuple[str, str, str]]], width: int) -> Text:
    """One labelled bar per row: (label, used, total, value, shades), aligned in columns."""
    label_width = max(len(label) for label, *_ in rows)
    value_width = max(len(row[3]) for row in rows)
    bar_width = max(width - label_width - value_width - 2, 1)
    text = Text()
    for index, (label, used, total, value, shades) in enumerate(rows):
        if index:
            text.append("\n")
        text.append(label.ljust(label_width + 1), style=MUTE if shades is LOAD_SHADES else SKY)
        text.append_text(bar(used, total, bar_width, shades))
        text.append(" " + value.rjust(value_width), style="bold")
    return text


def node_text(node: Node, width: int) -> Text:
    return bars_text(
        [
            ("CPU", node.cpu_used, node.cpu_total, f"{node.cpu_used}/{node.cpu_total}", LOAD_SHADES),
            ("RAM", node.mem_used, node.mem_total, f"{round(100 * node.mem_used / node.mem_total)}%", LOAD_SHADES),
            *((profile, used, total, f"{used}/{total}", SLICE_SHADES) for profile, (used, total) in node.gpus.items()),
        ],
        width,
    )


def clock(timestamp: str) -> str:
    return datetime.fromisoformat(timestamp).strftime("%H:%M:%S")


def gpu_profile(record: Record) -> str | None:
    return next((key.split(":")[1] for key in record.requested if key.startswith("gres/gpu:")), None)


def gpu_slice_gb(record: Record) -> int | None:
    """GPU memory of the slice of a job, read from its MIG profile: "4g.71gb" -> 71."""
    profile = gpu_profile(record)
    return int(profile.split(".")[1].removesuffix("gb")) if profile else None


def details_text(record: Record, usage: Usage | None, efficiency: dict[str, str], width: int) -> Text:
    """State, timing, and requested against used resources of one job."""
    text = Text()
    text.append_text(state_text(record.state))
    text.append(f"  {record.node}  {record.account}\n", style=MUTE)

    timing = [f"submitted {clock(record.submit)}"]
    limit = seconds(record.limit)
    if record.start == "Unknown":
        timing.append("not started")
    else:
        start = datetime.fromisoformat(record.start)
        timing += [f"started {clock(record.start)}", f"queued {start - datetime.fromisoformat(record.submit)}"]
        if record.end != "Unknown":
            timing.append(f"ended {clock(record.end)}")
        elif limit is not None:
            timing.append(f"ends {start + timedelta(seconds=limit):%H:%M:%S}")
    text.append(" · ".join(timing) + "\n")

    # The request is used rather than the allocation, which is empty while a job is pending.
    gigabytes = megabytes(record.requested["mem"]) / 1024
    profile = gpu_profile(record)
    rows = []
    if limit is not None:
        elapsed = record.elapsed.removeprefix("00:")
        rows.append(("Time", seconds(record.elapsed), limit, f"{elapsed} / {record.limit.removeprefix('00:')}", LOAD_SHADES))
    if usage:
        rows.append(("RAM peak", usage.mem_mb / 1024, gigabytes, f"{usage.mem_mb / 1024:.1f} / {gigabytes:g} GB", LOAD_SHADES))
        if profile:
            slice_gb = gpu_slice_gb(record)
            rows.append((f"GPU {profile}", usage.gpu_mem_mb / 1024, slice_gb, f"{usage.gpu_mem_mb / 1024:.1f} / {slice_gb} GB", SLICE_SHADES))
    if rows:
        text.append_text(bars_text(rows, width))
        text.append("\n")

    summary = [f"{record.requested['cpu']} cores"]
    if usage:
        summary.append(f"CPU time {usage.cpu_time}")
    else:
        summary += [f"{gigabytes:g} GB requested", f"GPU {profile}" if profile else "no GPU"]
    if usage and not profile:
        summary.append("no GPU")
    text.append(" · ".join(summary), style=MUTE)

    share = usage.mem_mb / 1024 / gigabytes if usage else 1
    if share < 0.5 and seconds(record.elapsed) >= WASTE_AFTER:
        text.append(f"\n▲ RAM peak is {share:.0%} of the request: lower --mem", style=WARM)
    if not usage and "CPU Efficiency" in efficiency:
        text.append(
            f"\nCPU efficiency {efficiency['CPU Efficiency'].split()[0]} · memory {efficiency['Memory Utilized']}"
            f" ({efficiency['Memory Efficiency']})",
            style=SKY,
        )
    return text


class NodePanel(Widget):
    """Bar charts of the CPU, memory and GPU slice allocation of one node."""

    def __init__(self, node: Node):
        super().__init__(id=f"node-{node.name}")
        self.cpu_trend: deque[float] = deque(maxlen=TREND_SAMPLES)
        self.gpu_trend: deque[float] = deque(maxlen=TREND_SAMPLES)
        self.show(node)

    def show(self, node: Node) -> None:
        self.node = node
        self.cpu_trend.append(node.cpu_used / node.cpu_total)
        slices = list(node.gpus.values())
        self.gpu_trend.append(sum(used for used, _ in slices) / sum(total for _, total in slices) if slices else 0)
        self.border_title = f"{node.name} · {node.state}"
        self.border_subtitle = free_text(node)
        self.refresh()

    def render(self) -> Text:
        width = self.content_size.width
        text = node_text(self.node, width)
        text.append("\n")
        text.append_text(trends_text([("CPU trend", self.cpu_trend, ACCENT), ("GPU trend", self.gpu_trend, SKY)], width))
        return text


class DetailsPanel(Widget):
    """Timing and resources of the highlighted job."""

    def __init__(self):
        super().__init__(id="details")
        self.record = None
        self.show(None, None, {})

    def show(self, record: Record | None, usage: Usage | None, efficiency: dict[str, str]) -> None:
        if not (record and self.record and record.id == self.record.id):
            # Another job: its usage trends start from scratch.
            self.mem_trend: deque[float] = deque(maxlen=TREND_SAMPLES)
            self.gpu_trend: deque[float] = deque(maxlen=TREND_SAMPLES)
        if record and usage:
            self.mem_trend.append(min(usage.mem_now_mb / megabytes(record.requested["mem"]), 1))
            if gpu_slice_gb(record):
                self.gpu_trend.append(min(usage.gpu_mem_now_mb / 1024 / gpu_slice_gb(record), 1))
        self.record, self.usage, self.efficiency = record, usage, efficiency
        self.border_title = f"Details · {record.id} {record.name}" if record else "Details"
        self.refresh()

    def render(self) -> Text:
        if not self.record:
            return Text("No job selected.", style=MUTE)
        width = self.content_size.width
        text = details_text(self.record, self.usage, self.efficiency, width)
        trends = [("RAM now", self.mem_trend, ACCENT), ("GPU now", self.gpu_trend, SKY)]
        trends = [trend for trend in trends if trend[1]]
        if trends:
            text.append("\n")
            text.append_text(trends_text(trends, width))
        return text
