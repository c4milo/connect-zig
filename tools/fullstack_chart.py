#!/usr/bin/env python3
"""Draws a chart of docs/images/ from a production table of CI's fullstack job (decision 44).

    tools/fullstack_chart.py <log> <run> <commit> <transport> [out.svg]

<log> holds the job's whole output, or the reports of tools/fullstack/production.sh. <transport>
picks the table: `tls`, connect-zig against the Collector and Vector, or `cleartext`, against the
Collector and Rotel. `validate` draws the TLS table's receivers on connect-zig, connect-go and
connect-rust, each beside its twin that validates every export with protovalidate
(tools/fullstack/validate). The chart draws the production model: one gateway core for 33,000 servers,
516 connections and a mix of gzip exports. Its left panel gives the spans a second each server's
core held with p99 at most 100 ms and no call refused. Its right panel gives each step's p99
against the spans a second sent, on a log scale, with the 100 ms limit. <run> and <commit> name
the run in the subtitle, as docs/performance.md asks of a published number.
"""

import math
import pathlib
import re
import sys
import types

# A lighter shade is too faint against the surface to show a bar's edge or a line, so a bar of one
# takes an outline in its library's color, and its line is that color, dashed.
outlines = {"--zigv": "--zig", "--gov": "--go", "--rustv": "--rust"}
# Each receiver that validates, and its twin that does not.
twins = {
    "connect-zig + protovalidate": "connect-zig",
    "connect-go + protovalidate-go": "connect-go",
    "connect-rust + protovalidate-buffa": "connect-rust",
}
# The Connect libraries, which the title names when the table holds them (decision 46).
libraries = ("connect-go", "connect-rust")
limit_ms = 100
# The time GitHub writes before each line of a job's log, which a log saved from a run holds.
stamp = re.compile(r"^\d{4}-\d\d-\d\dT[0-9:.]+Z ")
# The longest title the chart's width holds at its font: a longer one leaves out the limit, which
# the subtitle states.
title_len_max = 90
# What the label of a climb's last step says when the step failed on anything but its p99.
failures = {"refused": "refused", "rate": "short of the rate", "load": "load full"}


def setting(transport):
    """Whether the chart draws protovalidate's receivers, the transport's words, and the looks."""
    validate = transport == "validate"
    return validate, "over cleartext h2" if transport == "cleartext" else "over TLS", looks_of(validate)


def number(text):
    return float(text.replace(",", "").replace("+", "").rstrip("%"))


def looks_of(validate):
    """Each server's name in the report, its name in the legend, and its color: one color a
    server, in every chart of the README. A receiver that validates takes a lighter shade of its
    library's."""
    if validate:
        return {
            "connect-zig": ("connect-zig", "--zig"),
            "connect-zig + protovalidate": ("connect-zig + protovalidate", "--zigv"),
            "connect-go": ("connect-go", "--go"),
            "connect-go + protovalidate-go": ("connect-go + protovalidate-go", "--gov"),
            "connect-rust": ("connect-rust", "--rust"),
            "connect-rust + protovalidate-buffa": ("connect-rust + protovalidate-buffa", "--rustv"),
        }
    return {
        "connect-zig": ("connect-zig", "--zig"),
        "Collector": ("OpenTelemetry Collector", "--otel"),
        "Vector": ("Vector", "--vector"),
        "Rotel": ("Rotel", "--rotel"),
        "connect-go": ("connect-go", "--go"),
        "connect-rust": ("connect-rust", "--rust"),
    }


def held_of(row):
    """A server's row of the table of the rates held."""
    # The resolution: how far above the rate held the rate the core holds may lie. An older report
    # gives none.
    gap = number(row["resolution"]) / 100 if row.get("resolution") else None
    # A report with resolutions gives none for a climb whose every step passed: its rate is a floor.
    floor = "resolution" in row and not row["resolution"]
    item = {"spans": number(row["spans/s held"]), "p99": number(row["p99 ms"]), "gap": gap, "floor": floor}
    # The least and the greatest rate the rounds held. An older report of one climb gives none.
    if row.get("range"):
        low, high = row["range"].split("–")
        item["low"], item["high"] = number(low), number(high)
    return item


def step_of(cells, columns):
    """A step of the first round: the spans a second sent, and each server's p99 and failure."""
    row = {"sent": number(cells[1])}
    for name, index in columns.items():
        if cells[index]:
            value = re.match(r"([0-9.,]+)(?: \((\w+)\))?", cells[index])
            row[name] = (number(value.group(1)), value.group(2))
    return row


class Reader:
    """The production table over a transport, read a line at a time from a log."""

    def __init__(self, over, looks):
        self.over, self.looks = over, looks
        self.held, self.steps, self.machine = {}, [], None
        self.section, self.columns, self.held_columns = False, None, None

    def line(self, line):
        if line.startswith("## "):
            self.section = line.startswith(f"## Full stack, production {self.over}")
            return
        if not self.section:
            return
        if line.startswith("Machine: ") and self.machine is None:
            self.machine = ", ".join(part.strip() for part in line[len("Machine: ") :].rstrip(".").split(",")[:2])
        if not line.startswith("|") or "---" in line:
            return
        self.row([cell.strip() for cell in line.strip("|").split("|")])

    def row(self, cells):
        if cells[0] == "server":
            # The table of the rates held, or another table whose rows also start with a server's
            # name, such as the long step's, which this reads none of.
            self.held_columns = {name: index for index, name in enumerate(cells)} if "spans/s held" in cells else None
        elif cells[0] == "exports a connection a second":
            self.columns = {cells[index][: -len(" p99")]: index for index in range(2, len(cells), 2)}
        elif cells[0] in self.looks and self.held_columns and cells[self.held_columns["spans/s held"]] != "none":
            self.held[cells[0]] = held_of({name: cells[index] for name, index in self.held_columns.items()})
        elif self.columns and re.fullmatch(r"[0-9.]+", cells[0]):
            self.steps.append(step_of(cells, self.columns))


def read(log_path, over, looks):
    """The rates held by server, the first round's steps, and the machine, from the log."""
    reader = Reader(over, looks)
    with open(log_path) as log:
        for line in log:
            reader.line(stamp.sub("", line.strip()))
    return reader.held, reader.steps, reader.machine


def bound(held, top, bottom):
    """How a ratio of two rates held reads: a ratio over a floor is at most its value, a ratio of a
    floor at least, and a ratio of two floors is marked so."""
    if held[top]["floor"] and held[bottom]["floor"]:
        return "?", "about "
    if held[top]["floor"]:
        return "≥", "at least "
    if held[bottom]["floor"]:
        return "≤", "at most "
    return "", ""


def whisker(item, spans_high, bar_left, bar_w, width):
    """A bar's whisker, its start, its end, and its capped ends: the range of the rounds, or in a
    report of one climb the gap to the step that failed. None when the bar has neither."""
    if "low" in item:
        start = bar_left + item["low"] / spans_high * bar_w
        end = bar_left + item["high"] / spans_high * bar_w
        return start, end, (start, end)
    if item["gap"]:
        end = bar_left + width * (1 + item["gap"])
        return bar_left + width, end, (end,)
    return None


def title_of(held, servers, validate):
    """The chart's title: connect-zig's rate over each other's, or each share protovalidate keeps."""
    if validate:
        kept = [
            f"{twin} {bound(held, name, twin)[0]}{held[name]['spans'] / held[twin]['spans'] * 100:.0f}%"
            for name, twin in twins.items()
            if name in held and twin in held
        ]
        return f"Rate kept with protovalidate: {', '.join(kept)}"
    others = [name for name in servers if name != "connect-zig"]
    # Four ratios do not fit one title, so a table with the Connect libraries names them alone, and
    # each bar gives its own ratio.
    titled = [name for name in others if name in libraries] or others
    ratios = [
        f"{bound(held, 'connect-zig', name)[1]}{held['connect-zig']['spans'] / held[name]['spans']:.1f} times "
        f"{'the ' if name == 'Collector' else ''}{name}'s"
        for name in titled
    ]
    title = f"One core holds {' and '.join(ratios)} spans a second, with p99 under {limit_ms} ms"
    if len(title) > title_len_max:
        title = f"One core holds {' and '.join(ratios)} spans a second"
    return title


def subtitle_of(held, validate, over):
    """The subtitle's lines, which say what a whisker spans when a bar has one."""
    subtitle = [
        f"Each server holds 516 connections {over}, as one core of a 64-core gateway for 33,000 servers, and",
        f"takes gzip OTLP exports of 16, 128 and 512 spans. The rate climbs until p99 passes {limit_ms} ms or a call is refused.",
    ]
    ranges = any("low" in item for item in held.values())
    whiskers = ranges or any(item["gap"] is not None for item in held.values())
    # What a whisker spans: the rates the rounds held, or, in a report of one climb, the gap to the
    # step that failed.
    whisker_text = (
        "Each bar is the median of the rounds, and its whisker spans the rates they held."
        if ranges
        else "A whisker reaches the step that failed, so the rate a core holds lies inside it."
    )
    if validate:
        subtitle.append(
            "Each share is a receiver's spans a second with protovalidate over its own without. A dashed line is a"
        )
        subtitle.append("receiver that validates." + (f" {whisker_text}" if whiskers else ""))
    elif whiskers:
        subtitle.append(whisker_text)
    if ranges:
        subtitle.append("The right panel gives each server's first round, which climbs from the lowest rate.")
    return subtitle


def legend_rows_of(servers, looks, pad_l, chart_w):
    """The legend's rows: an entry that would pass the chart's right edge starts a row of its own."""
    char_legend_w = 7
    legend_rows, legend_x = [[]], pad_l
    for name in servers:
        width = 18 + char_legend_w * len(looks[name][0]) + 24
        if legend_x + width > chart_w - pad_l and legend_rows[-1]:
            legend_rows.append([])
            legend_x = pad_l
        legend_rows[-1].append((name, legend_x))
        legend_x += width
    return legend_rows


def layout_of(held, steps, servers, looks, validate, subtitle):
    """Where each part of the chart goes."""
    lay = types.SimpleNamespace(pad_l=24, sub_line_h=18, bar_h=20, bar_gap=22, W=840, legend_row_h=18)
    lay.legend_y = 56 + (len(subtitle) + 1) * lay.sub_line_h + 2
    # Each row of the legend past the first moves the panels down.
    lay.legend_rows = legend_rows_of(servers, looks, lay.pad_l, lay.W)
    lay.top = lay.legend_y + 56 + (len(lay.legend_rows) - 1) * lay.legend_row_h
    # The chart grows when its bars pass its foot.
    lay.plot_h = 128
    # The room under the p99 panel for its ticks and the axis's name, so a chart of few servers does
    # not cut them off.
    axis_room = 44
    lay.H = max(340, lay.top + 12 + len(servers) * (lay.bar_h + lay.bar_gap) + 8, lay.top + lay.plot_h + axis_room)
    # The receivers that validate take longer names, so their bars start further right, and the panel
    # of the climb starts further right too.
    lay.bar_left, lay.bar_w = (lay.pad_l + 208, 150) if validate else (lay.pad_l + 104, 210)
    lay.line_left, lay.line_right = (520, 810) if validate else (448, 800)
    lay.y_low, lay.y_high = 0.5, 2000
    lay.x_high = max(step["sent"] for step in steps)
    return lay


def sx(lay, value):
    return lay.line_left + value / lay.x_high * (lay.line_right - lay.line_left)


def sy(lay, ms):
    ms = min(max(ms, lay.y_low), lay.y_high)
    low, high = math.log10(lay.y_low), math.log10(lay.y_high)
    return lay.top + lay.plot_h - (math.log10(ms) - low) / (high - low) * lay.plot_h


def thousands(value):
    return f"{value / 1000:,.0f}k"


def edge(fill):
    """The outline a shade too faint for the surface takes, or none."""
    return f' stroke="var({outlines[fill]})" stroke-width="1.5"' if fill in outlines else ""


# The chart's style sheet: its colors in light and dark, and its fonts.
style = """<style>
svg { --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#8a8984; --grid:#e4e3df; --zig:#2a78d6; --zigv:#8db8ea; --otel:#b07d00; --vector:#b8407f; --rotel:#722626; --go:#1a8a82; --gov:#8ccfc9; --rust:#b5562b; --rustv:#dfa283; }
@media (prefers-color-scheme: dark) {
  svg { --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#8f8e86; --grid:#33332f; --zig:#3987e5; --zigv:#1f5596; --otel:#c99512; --vector:#d0599a; --rotel:#b84545; --go:#2fa59c; --gov:#1d625d; --rust:#d06d3f; --rustv:#8a4524; }
}
text { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; fill: var(--ink); }
.title { font-size: 16px; font-weight: 600; }
.sub { font-size: 12.5px; fill: var(--ink2); }
.panel { font-size: 14px; font-weight: 600; }
.row { font-size: 12.5px; fill: var(--ink2); }
.val { font-size: 11px; font-weight: 600; paint-order: stroke; stroke: var(--surface); stroke-width: 3px; stroke-linejoin: round; }
.tick { font-size: 11px; fill: var(--muted); }
.legend { font-size: 12.5px; fill: var(--ink2); }
</style>"""


def description(title, held, steps, servers):
    """The chart's description: each server's rate held, and its p99 at each step."""
    climb = "; ".join(
        f"{name}: "
        + ", ".join(
            f"{thousands(step['sent'])} {step[name][0]:g} ms" + (f" {step[name][1]}" if step[name][1] else "")
            for step in steps
            if name in step
        )
        for name in servers
    )
    spans = ", ".join(
        f"{name} {held[name]['spans']:,.0f} spans a second at p99 {held[name]['p99']:g} ms" for name in servers
    )
    return f"{title}. {spans}. p99 at each step: {climb}."


def draw_head(a, lay, chart):
    """The chart's frame: its size, its title and description, its style, and its subtitle."""
    W, H, pad_l = lay.W, lay.H, lay.pad_l
    a(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">'
    )
    subject = (
        "connect-zig, connect-go and connect-rust, each with and without protovalidate"
        if chart.validate
        else f"connect-zig against {', '.join(name for name in chart.servers if name != 'connect-zig')}"
    )
    a(
        f'<title id="t">The spans a second one core holds {chart.over}, {subject}, as one gateway core for 33,000 servers</title>'
    )
    a(f'<desc id="d">{description(chart.title, chart.held, chart.steps, chart.servers)}</desc>')
    a(style)
    a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
    a(f'<text class="title" x="{pad_l}" y="34">{chart.title}</text>')
    for index, text in enumerate(chart.subtitle):
        a(f'<text class="sub" x="{pad_l}" y="{56 + index * lay.sub_line_h}">{text}</text>')
    where = f", {chart.machine}" if chart.machine else ""
    a(
        f'<text class="sub" x="{pad_l}" y="{56 + len(chart.subtitle) * lay.sub_line_h}">One CI job ran all, and checked every span: '
        f"run {chart.run}, commit {chart.commit}{where}.</text>"
    )


def draw_legend(a, lay, looks):
    for row, entries in enumerate(lay.legend_rows):
        y = lay.legend_y + row * lay.legend_row_h
        for name, x in entries:
            label, fill = looks[name]
            a(f'<rect x="{x}" y="{y - 10}" width="12" height="12" rx="2" fill="var({fill})"{edge(fill)}/>')
            a(f'<text class="legend" x="{x + 18}" y="{y}">{label}</text>')


def bar_ratio(held, name, validate):
    """The end of a bar's label: connect-zig's rate over the server's, or the share kept of its twin's."""
    top, bottom = (name, twins.get(name)) if validate else ("connect-zig", name)
    if bottom not in held or top == bottom:
        return ""
    if validate:
        return f", {bound(held, top, bottom)[0]}{held[top]['spans'] / held[bottom]['spans'] * 100:.0f}%"
    return f", connect-zig {bound(held, top, bottom)[0]}{held[top]['spans'] / held[bottom]['spans']:.1f}×"


def draw_whisker(a, line, middle):
    """A whisker's line, and a cap at each of its ends that takes one."""
    start, end, caps = line
    a(f'<line x1="{start:.1f}" y1="{middle}" x2="{end:.1f}" y2="{middle}" stroke="var(--ink)" stroke-width="1.5"/>')
    for x in caps:
        a(
            f'<line x1="{x:.1f}" y1="{middle - 4}" x2="{x:.1f}" y2="{middle + 4}" stroke="var(--ink)" stroke-width="1.5"/>'
        )


def draw_bars(a, lay, chart, looks):
    """The left panel: a bar for each server's rate held, with its whisker and its label."""
    held, bar_left, bar_h = chart.held, lay.bar_left, lay.bar_h
    a(f'<text class="panel" x="{lay.pad_l}" y="{lay.top - 14}">Spans a second one core holds</text>')
    spans_high = max(item.get("high", item["spans"]) for item in held.values())
    for index, name in enumerate(chart.servers):
        fill = looks[name][1]
        y = lay.top + 12 + index * (bar_h + lay.bar_gap)
        width = max(held[name]["spans"] / spans_high * lay.bar_w, 1)
        radius = min(4, width / 2)
        a(f'<text class="row" x="{bar_left - 10}" y="{y + bar_h / 2 + 4:.1f}" text-anchor="end">{name}</text>')
        a(
            f'<path d="M{bar_left},{y} h{width - radius:.1f} a{radius},{radius} 0 0 1 {radius},{radius} v{bar_h - 2 * radius} '
            f'a{radius},{radius} 0 0 1 {-radius},{radius} h{-(width - radius):.1f} z" fill="var({fill})"{edge(fill)}/>'
        )
        line = whisker(held[name], spans_high, bar_left, lay.bar_w, width)
        if line:
            draw_whisker(a, line, y + bar_h / 2)
        floor = "≥" if held[name]["floor"] else ""
        a(
            f'<text class="val" x="{bar_left + 4:.1f}" y="{y + bar_h + 13}">{floor}{held[name]["spans"]:,.0f} spans/s, '
            f"p99 {held[name]['p99']:g} ms{bar_ratio(held, name, chart.validate)}</text>"
        )


def draw_axes(a, lay):
    """The right panel's grid of p99, with the limit dashed, and its ticks of spans a second sent."""
    a(f'<text class="panel" x="{lay.line_left - 40}" y="{lay.top - 14}">p99 as the rate climbs</text>')
    for ms in (1, 10, 100, 1000):
        y = sy(lay, ms)
        dash = ' stroke-dasharray="4 3"' if ms == limit_ms else ""
        stroke = "var(--ink2)" if ms == limit_ms else "var(--grid)"
        a(
            f'<line x1="{lay.line_left}" y1="{y:.1f}" x2="{lay.line_right}" y2="{y:.1f}" stroke="{stroke}" stroke-width="1"{dash}/>'
        )
        name = f"limit {ms} ms" if ms == limit_ms else f"{ms:,} ms"
        a(f'<text class="tick" x="{lay.line_left - 6}" y="{y + 4:.1f}" text-anchor="end">{name}</text>')
    tick = 200_000 if lay.x_high <= 1_000_000 else 400_000
    for value in range(0, int(lay.x_high) + 1, tick):
        a(
            f'<text class="tick" x="{sx(lay, value):.1f}" y="{lay.top + lay.plot_h + 16}" text-anchor="middle">{thousands(value)}</text>'
        )
    a(
        f'<text class="tick" x="{lay.line_right}" y="{lay.top + lay.plot_h + 32}" text-anchor="end">spans a second sent</text>'
    )


def draw_climbs(a, lay, chart, looks):
    """The right panel's line of each server's climb, and the labels of the steps that failed."""
    labels = []
    for name in chart.servers:
        fill = looks[name][1]
        stroke = outlines.get(fill, fill)
        dash = ' stroke-dasharray="5 3"' if fill in outlines else ""
        points = [(sx(lay, step["sent"]), sy(lay, step[name][0]), step[name]) for step in chart.steps if name in step]
        a(
            f'<polyline points="{" ".join(f"{x:.1f},{y:.1f}" for x, y, _ in points)}" fill="none" stroke="var({stroke})" '
            f'stroke-width="2"{dash}/>'
        )
        for x, y, (_, failed) in points:
            inside = "var(--surface)" if failed else f"var({fill})"
            a(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{inside}" stroke="var({stroke})" stroke-width="2"/>')
        x, y, (last, failed) = points[-1]
        if failed:
            labels.append([max(y + 4, lay.top + 8), x, failures.get(failed, f"p99 {last:,.0f} ms")])
    return labels


def unique_labels(labels):
    """The labels in order of their height, without one that repeats a label a few pixels away."""
    merge_px = 6
    unique = []
    for label in sorted(labels):
        if any(
            text == label[2] and abs(x - label[1]) < merge_px and abs(y - label[0]) < merge_px for y, x, text in unique
        ):
            continue
        unique.append(label)
    return unique


def place_labels(lay, labels):
    """Where each label of a failed step goes: beside its point, to the right, or above it and to
    the left at the right edge. A label that would cover the one above it moves down a line."""
    char_w, line_h = 6.2, 13
    placed = []
    for y, x, text in unique_labels(labels):
        width = len(text) * char_w
        at_edge = x + 8 + width > lay.line_right
        left = x - 8 - width if at_edge else x + 8
        if at_edge:
            y = max(y - 12, lay.top + 8)
        for other_y, other_left, other_width, _ in placed:
            if abs(y - other_y) < line_h and left < other_left + other_width and other_left < left + width:
                y = other_y + line_h
        placed.append((y, left, width, text))
    return placed


def draw(transport, held, steps, machine, run, commit):
    """The chart's SVG text."""
    validate, over, looks = setting(transport)
    chart = types.SimpleNamespace(held=held, steps=steps, machine=machine, run=run, commit=commit, validate=validate)
    chart.over = over
    chart.servers = [name for name in looks if name in held]
    chart.title = title_of(held, chart.servers, validate)
    chart.subtitle = subtitle_of(held, validate, chart.over)
    lay = layout_of(held, steps, chart.servers, looks, validate, chart.subtitle)
    parts = []
    a = parts.append
    draw_head(a, lay, chart)
    draw_legend(a, lay, looks)
    draw_bars(a, lay, chart, looks)
    draw_axes(a, lay)
    for y, left, _, text in place_labels(lay, draw_climbs(a, lay, chart, looks)):
        a(f'<text class="val" x="{left:.1f}" y="{y:.1f}">{text}</text>')
    a("</svg>")
    return "\n".join(parts) + "\n"


def main():
    log_path, run, commit, transport = sys.argv[1:5]
    suffix = {"tls": "", "cleartext": "-cleartext", "validate": "-validate"}[transport]
    out = sys.argv[5] if len(sys.argv) > 5 else f"docs/images/fullstack{suffix}.svg"
    validate, over, looks = setting(transport)
    held, steps, machine = read(log_path, over, looks)
    servers = [name for name in looks if name in held]
    if "connect-zig" not in held or len(servers) < 2 or not steps:
        sys.exit(f"{log_path}: no production table {over} with connect-zig and another server")
    if validate and "connect-zig + protovalidate" not in held:
        sys.exit(f"{log_path}: no production table {over} with connect-zig + protovalidate")
    pathlib.Path(out).write_text(draw(transport, held, steps, machine, run, commit))


if __name__ == "__main__":
    main()
