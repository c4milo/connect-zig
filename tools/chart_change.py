"""What changed since the previous tag, for the charts of tools/*_chart.py (decision 44 as amended
on 2026-11-25).

A chart records the value of each connect-zig bar it draws in a file of values beside its SVG,
`<chart>.json`, which CI attaches to the tag's release beside the chart. A chart drawn with
`--previous <file>`, the same chart's values from the previous tag, marks each connect-zig bar:

- a gray line across the bar at the previous tag's value;
- after the bar's label, ▲ and the change when the value is `threshold` or more better, and ▼
  when it is that much worse.

The marks compare the value the bar draws. Two values of runs on different CPU models do not
compare, so a chart whose machine differs from the previous one's marks nothing, and says so.
tools/charts_compare.py writes the same comparison as a table, for the release's notes and the
run's summary.
"""

import json
import os
import pathlib

# The least change, as a share of the previous value, that a chart marks better or worse. The
# three rounds of the full stack spread less than this on arm64.
threshold = 0.05
# The digits of a share that a comparison with the threshold reads.
share_digits = 9
# The version of the file of values: a reader refuses a file of another version.
format_version = 1
# The command-line option that names the previous tag's file of values.
option = "--previous"
# The style of the marks, which each chart adds to its style sheet.
style = """.better { fill: #1a7f37; } .worse { fill: #cf222e; }
@media (prefers-color-scheme: dark) { .better { fill: #3fb950; } .worse { fill: #f85149; } }
.was { stroke: var(--ink2); stroke-width: 1.5; stroke-dasharray: 2 2; }"""


def moved(share):
    """Whether a change moved by the threshold or more. The share is rounded first, so that 105
    against 100, whose quotient a float holds as a hair over 5%, counts as 5% exactly."""
    return share is not None and round(abs(share), share_digits) >= threshold


def split_arguments(arguments):
    """The arguments without `--previous <file>`, and the previous tag's values, or None when the
    option is absent or names no file."""
    if option not in arguments:
        return arguments, None
    index = arguments.index(option)
    path = pathlib.Path(arguments[index + 1])
    rest = arguments[:index] + arguments[index + 2 :]
    return rest, load(path) if path.exists() else None


def load(path):
    """A file of values, or None when it holds another version."""
    values = json.loads(pathlib.Path(path).read_text())
    return values if values.get("version") == format_version else None


class Change:
    """The values a chart draws for connect-zig, and their changes since the previous tag."""

    def __init__(self, previous, machine):
        self.machine = machine
        self.records = {}
        same_machine = previous is not None and previous.get("machine") == machine
        self.previous = previous if same_machine else None
        self.other_machine = previous is not None and not same_machine
        self.tag = None
        if previous is not None:
            self.tag = previous.get("tag") or f"run {previous.get('run')}"

    def record(self, key, label, value, higher_is_better=True):
        """Keeps a value the chart draws, under a key that names it in every tag's file."""
        self.records[key] = {"label": label, "value": value, "higher_is_better": higher_is_better}

    def was(self, key):
        """The previous tag's value of `key`, or None."""
        if self.previous is None:
            return None
        record = self.previous["values"].get(key)
        return None if record is None else record["value"]

    def share(self, key):
        """How much better the value of `key` is than the previous tag's, as a share of it: below
        zero when it is worse. None when there is nothing to compare."""
        was, record = self.was(key), self.records.get(key)
        if not was or record is None:
            return None
        change = record["value"] / was - 1
        return change if record["higher_is_better"] else -change

    def mark(self, key):
        """The text after a bar's label: ▲ or ▼ and the change, or nothing."""
        change = self.share(key)
        if not moved(change):
            return ""
        kind, arrow = ("better", "▲") if change > 0 else ("worse", "▼")
        return f' <tspan class="{kind}">{arrow}{abs(change) * 100:.0f}%</tspan>'

    def end(self, key, x_of, bar_end):
        """Where a bar's label may start: past the bar's end, and past the line at the previous
        tag's value when that line lies beyond it."""
        was = self.was(key)
        return bar_end if was is None else max(bar_end, x_of(was) + 2)

    def line(self, key, x_of, top, height):
        """A gray line across a bar at the previous tag's value, where `x_of` places a value."""
        was = self.was(key)
        if was is None:
            return ""
        x = x_of(was)
        return f'<line class="was" x1="{x:.1f}" y1="{top - 2:.1f}" x2="{x:.1f}" y2="{top + height + 2:.1f}"/>'

    def bar(self, a, key, label, value, place):
        """Records a connect-zig bar's value, draws the line at the previous tag's value, and gives
        the mark after the bar's label and where that label may start. `place` is the bar's
        `x_of`, which places a value, its top, its height, and its end."""
        x_of, top, height, bar_end = place
        self.record(key, label, value)
        a(self.line(key, x_of, top, height))
        return self.mark(key), self.end(key, x_of, bar_end)

    def note(self):
        """The line that explains the marks, or None when the chart draws none."""
        if self.previous is not None:
            return (
                f"▲ marks a value {threshold * 100:.0f}% or more better than {self.tag}'s, ▼ one that much "
                f"worse, and a dashed line {self.tag}'s value."
            )
        if self.other_machine:
            return f"{self.tag} ran on another CPU model, so this chart marks no change since it."
        return None

    def write(self, svg_path, chart_name, run, commit):
        """Writes the values beside the chart's SVG, as `<chart>.json`."""
        tag = os.environ.get("GITHUB_REF_NAME") if os.environ.get("GITHUB_REF_TYPE") == "tag" else None
        values = {
            "version": format_version,
            "chart": chart_name,
            "machine": self.machine,
            "run": run,
            "commit": commit,
            "tag": tag,
            "values": self.records,
        }
        pathlib.Path(svg_path).with_suffix(".json").write_text(json.dumps(values, indent=1) + "\n")


def note_height(change):
    """The height a chart adds for its line of marks."""
    return 22 if change.note() else 0


def draw_note(a, change, x, height):
    """The line that explains the marks, at the chart's foot, whose height includes it."""
    note = change.note()
    if note:
        a(f'<text class="sub" x="{x}" y="{height - 12}">{note}</text>')
