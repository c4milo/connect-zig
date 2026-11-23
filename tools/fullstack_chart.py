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
import re
import sys

log_path, run, commit, transport = sys.argv[1:5]
suffix = {"tls": "", "cleartext": "-cleartext", "validate": "-validate"}[transport]
out = sys.argv[5] if len(sys.argv) > 5 else f"docs/images/fullstack{suffix}.svg"
validate = transport == "validate"
over = "over cleartext h2" if transport == "cleartext" else "over TLS"
# Each server's name in the report, its name in the legend, and its color: one color a server, in
# every chart of the README. A receiver that validates takes a lighter shade of its library's.
looks = {
    "connect-zig": ("connect-zig", "--zig"),
    "Collector": ("OpenTelemetry Collector", "--otel"),
    "Vector": ("Vector", "--vector"),
    "Rotel": ("Rotel", "--rotel"),
    "connect-go": ("connect-go", "--go"),
    "connect-rust": ("connect-rust", "--rust"),
}
if validate:
    looks = {
        "connect-zig": ("connect-zig", "--zig"),
        "connect-zig + protovalidate": ("connect-zig + protovalidate", "--zigv"),
        "connect-go": ("connect-go", "--go"),
        "connect-go + protovalidate-go": ("connect-go + protovalidate-go", "--gov"),
        "connect-rust": ("connect-rust", "--rust"),
        "connect-rust + protovalidate-buffa": ("connect-rust + protovalidate-buffa", "--rustv"),
    }
# A lighter shade is too faint against the surface to show a bar's edge or a line, so a bar of one
# takes an outline in its library's color, and its line is that color, dashed.
outlines = {"--zigv": "--zig", "--gov": "--go", "--rustv": "--rust"}
# Each receiver that validates, and its twin that does not.
twins = {"connect-zig + protovalidate": "connect-zig", "connect-go + protovalidate-go": "connect-go",
         "connect-rust + protovalidate-buffa": "connect-rust"}
# The Connect libraries, which the title names when the table holds them (decision 46).
libraries = ("connect-go", "connect-rust")
limit_ms = 100


def number(text):
    return float(text.replace(",", "").replace("+", "").rstrip("%"))


# The time GitHub writes before each line of a job's log, which a log saved from a run holds.
stamp = re.compile(r"^\d{4}-\d\d-\d\dT[0-9:.]+Z ")
held, steps, machine, section, columns, held_columns = {}, [], None, False, None, None
for line in open(log_path):
    line = stamp.sub("", line.strip())
    if line.startswith("## "):
        section = line.startswith(f"## Full stack, production {over}")
        continue
    if not section:
        continue
    if line.startswith("Machine: ") and machine is None:
        machine = ", ".join(part.strip() for part in line[len("Machine: "):].rstrip(".").split(",")[:2])
    if not line.startswith("|") or "---" in line:
        continue
    cells = [cell.strip() for cell in line.strip("|").split("|")]
    if cells[0] == "server":
        # The table of the rates held, or another table whose rows also start with a server's
        # name, such as the long step's, which this reads none of.
        held_columns = {name: index for index, name in enumerate(cells)} if "spans/s held" in cells else None
    elif cells[0] == "exports a connection a second":
        columns = {cells[index][:-len(" p99")]: index for index in range(2, len(cells), 2)}
    elif cells[0] in looks and held_columns and cells[held_columns["spans/s held"]] != "none":
        row = {name: cells[index] for name, index in held_columns.items()}
        # The resolution: how far above the rate held the rate the core holds may lie. An older
        # report gives none.
        gap = number(row["resolution"]) / 100 if row.get("resolution") else None
        # A report with resolutions gives none for a climb whose every step passed: its rate is a
        # floor.
        floor = "resolution" in row and not row["resolution"]
        held[cells[0]] = {"spans": number(row["spans/s held"]), "p99": number(row["p99 ms"]), "gap": gap, "floor": floor}
        # The least and the greatest rate the rounds held. An older report of one climb gives none.
        if row.get("range"):
            low, high = row["range"].split("–")
            held[cells[0]]["low"], held[cells[0]]["high"] = number(low), number(high)
    elif columns and re.fullmatch(r"[0-9.]+", cells[0]):
        row = {"sent": number(cells[1])}
        for name, index in columns.items():
            if cells[index]:
                value = re.match(r"([0-9.,]+)(?: \((\w+)\))?", cells[index])
                row[name] = (number(value.group(1)), value.group(2))
        steps.append(row)
servers = [name for name in looks if name in held]
if "connect-zig" not in held or len(servers) < 2 or not steps:
    sys.exit(f"{log_path}: no production table {over} with connect-zig and another server")
if validate and "connect-zig + protovalidate" not in held:
    sys.exit(f"{log_path}: no production table {over} with connect-zig + protovalidate")

others = [name for name in servers if name != "connect-zig"]
# Four ratios do not fit one title, so a table with the Connect libraries names them alone, and
# each bar gives its own ratio.
titled = [name for name in others if name in libraries] or others


def bound(top, bottom):
    """How a ratio of two rates held reads: a rate whose climb passed every step is a floor, so
    a ratio over it is at most its value, and a ratio of it at least. Two floors bound nothing,
    and the ratio is marked so."""
    if held[top]["floor"] and held[bottom]["floor"]:
        return "?", "about "
    if held[top]["floor"]:
        return "≥", "at least "
    if held[bottom]["floor"]:
        return "≤", "at most "
    return "", ""


ratios = [f"{bound('connect-zig', name)[1]}{held['connect-zig']['spans'] / held[name]['spans']:.1f} times "
          f"{'the ' if name == 'Collector' else ''}{name}'s" for name in titled]
# The longest title the chart's width holds at its font: a longer one leaves out the limit, which
# the subtitle states.
title_len_max = 90
title = f"One core holds {' and '.join(ratios)} spans a second, with p99 under {limit_ms} ms"
if len(title) > title_len_max:
    title = f"One core holds {' and '.join(ratios)} spans a second"
if validate:
    kept = [f"{twin} {bound(name, twin)[0]}{held[name]['spans'] / held[twin]['spans'] * 100:.0f}%" for name, twin in twins.items()
            if name in held and twin in held]
    title = f"Rate kept with protovalidate: {', '.join(kept)}"

pad_l = 24
subtitle = [
    f"Each server holds 516 connections {over}, as one core of a 64-core gateway for 33,000 servers, and",
    f"takes gzip OTLP exports of 16, 128 and 512 spans. The rate climbs until p99 passes {limit_ms} ms or a call is refused.",
]
ranges = any("low" in item for item in held.values())
whiskers = ranges or any(item["gap"] is not None for item in held.values())
# What a whisker spans: the rates the rounds held, or, in a report of one climb, the gap to the
# step that failed.
whisker_text = ("Each bar is the median of the rounds, and its whisker spans the rates they held." if ranges else
                "A whisker reaches the step that failed, so the rate a core holds lies inside it.")
if validate:
    subtitle.append("Each share is a receiver's spans a second with protovalidate over its own without. A dashed line is a")
    subtitle.append("receiver that validates." + (f" {whisker_text}" if whiskers else ""))
elif whiskers:
    subtitle.append(whisker_text)
if ranges:
    subtitle.append("The right panel gives each server's first round, which climbs from the lowest rate.")
sub_line_h = 18
legend_y = 56 + (len(subtitle) + 1) * sub_line_h + 2
bar_h, bar_gap = 20, 22
W = 840
# The legend's entries, a row at a time: an entry that would pass the chart's right edge starts a
# row of its own, and each row past the first moves the panels down.
legend_row_h = 18
char_legend_w = 7
legend_rows, legend_x = [[]], pad_l
for name in servers:
    width = 18 + char_legend_w * len(looks[name][0]) + 24
    if legend_x + width > W - pad_l and legend_rows[-1]:
        legend_rows.append([])
        legend_x = pad_l
    legend_rows[-1].append((name, legend_x))
    legend_x += width
top = legend_y + 56 + (len(legend_rows) - 1) * legend_row_h
# The chart grows when its bars pass its foot.
plot_h = 128
# The room under the p99 panel for its ticks and the axis's name, so a chart of few servers does
# not cut them off.
axis_room = 44
H = max(340, top + 12 + len(servers) * (bar_h + bar_gap) + 8, top + plot_h + axis_room)
# The receivers that validate take longer names, so their bars start further right, and the panel
# of the climb starts further right too.
bar_left, bar_w = (pad_l + 208, 150) if validate else (pad_l + 104, 210)
line_left, line_right = (520, 810) if validate else (448, 800)
y_low, y_high = 0.5, 2000
x_high = max(step["sent"] for step in steps)


def sx(value):
    return line_left + value / x_high * (line_right - line_left)


def sy(ms):
    ms = min(max(ms, y_low), y_high)
    return top + plot_h - (math.log10(ms) - math.log10(y_low)) / (math.log10(y_high) - math.log10(y_low)) * plot_h


def thousands(value):
    return f"{value / 1000:,.0f}k"


parts = []
a = parts.append
a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">')
subject = "connect-zig, connect-go and connect-rust, each with and without protovalidate" if validate else f"connect-zig against {', '.join(others)}"
a(f'<title id="t">The spans a second one core holds {over}, {subject}, as one gateway core for 33,000 servers</title>')
climb = "; ".join(
    f"{name}: " + ", ".join(f"{thousands(step['sent'])} {step[name][0]:g} ms" + (f" {step[name][1]}" if step[name][1] else "")
                            for step in steps if name in step)
    for name in servers)
spans = ", ".join(f"{name} {held[name]['spans']:,.0f} spans a second at p99 {held[name]['p99']:g} ms" for name in servers)
a(f'<desc id="d">{title}. {spans}. p99 at each step: {climb}.</desc>')
a('''<style>
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
</style>''')
a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
a(f'<text class="title" x="{pad_l}" y="34">{title}</text>')
for index, text in enumerate(subtitle):
    a(f'<text class="sub" x="{pad_l}" y="{56 + index * sub_line_h}">{text}</text>')
where = f", {machine}" if machine else ""
a(f'<text class="sub" x="{pad_l}" y="{56 + len(subtitle) * sub_line_h}">One CI job ran all, and checked every span: '
  f'run {run}, commit {commit}{where}.</text>')


def edge(fill):
    """The outline a shade too faint for the surface takes, or none."""
    return f' stroke="var({outlines[fill]})" stroke-width="1.5"' if fill in outlines else ""


for row, entries in enumerate(legend_rows):
    y = legend_y + row * legend_row_h
    for name, x in entries:
        label, fill = looks[name]
        a(f'<rect x="{x}" y="{y - 10}" width="12" height="12" rx="2" fill="var({fill})"{edge(fill)}/>')
        a(f'<text class="legend" x="{x + 18}" y="{y}">{label}</text>')

a(f'<text class="panel" x="{pad_l}" y="{top - 14}">Spans a second one core holds</text>')
spans_high = max(item.get("high", item["spans"]) for item in held.values())
for index, name in enumerate(servers):
    fill = looks[name][1]
    y = top + 12 + index * (bar_h + bar_gap)
    width = max(held[name]["spans"] / spans_high * bar_w, 1)
    radius = min(4, width / 2)
    a(f'<text class="row" x="{bar_left - 10}" y="{y + bar_h / 2 + 4:.1f}" text-anchor="end">{name}</text>')
    a(f'<path d="M{bar_left},{y} h{width - radius:.1f} a{radius},{radius} 0 0 1 {radius},{radius} v{bar_h - 2 * radius} '
      f'a{radius},{radius} 0 0 1 {-radius},{radius} h{-(width - radius):.1f} z" fill="var({fill})"{edge(fill)}/>')
    middle = y + bar_h / 2
    if "low" in held[name]:
        # The range of the rounds, with a cap at each end.
        start = bar_left + held[name]["low"] / spans_high * bar_w
        end = bar_left + held[name]["high"] / spans_high * bar_w
        a(f'<line x1="{start:.1f}" y1="{middle}" x2="{end:.1f}" y2="{middle}" stroke="var(--ink)" stroke-width="1.5"/>')
        for x in (start, end):
            a(f'<line x1="{x:.1f}" y1="{middle - 4}" x2="{x:.1f}" y2="{middle + 4}" stroke="var(--ink)" stroke-width="1.5"/>')
    elif held[name]["gap"]:
        end = bar_left + width * (1 + held[name]["gap"])
        a(f'<line x1="{bar_left + width:.1f}" y1="{middle}" x2="{end:.1f}" y2="{middle}" stroke="var(--ink)" stroke-width="1.5"/>')
        a(f'<line x1="{end:.1f}" y1="{middle - 4}" x2="{end:.1f}" y2="{middle + 4}" stroke="var(--ink)" stroke-width="1.5"/>')
    ratio = "" if name == "connect-zig" else f", connect-zig {bound('connect-zig', name)[0]}{held['connect-zig']['spans'] / held[name]['spans']:.1f}×"
    if validate:
        twin = twins.get(name)
        ratio = f", {bound(name, twin)[0]}{held[name]['spans'] / held[twin]['spans'] * 100:.0f}%" if twin in held else ""
    floor = "≥" if held[name]["floor"] else ""
    a(f'<text class="val" x="{bar_left + 4:.1f}" y="{y + bar_h + 13}">{floor}{held[name]["spans"]:,.0f} spans/s, '
      f'p99 {held[name]["p99"]:g} ms{ratio}</text>')

a(f'<text class="panel" x="{line_left - 40}" y="{top - 14}">p99 as the rate climbs</text>')
for ms in (1, 10, 100, 1000):
    y = sy(ms)
    dash = ' stroke-dasharray="4 3"' if ms == limit_ms else ""
    stroke = "var(--ink2)" if ms == limit_ms else "var(--grid)"
    a(f'<line x1="{line_left}" y1="{y:.1f}" x2="{line_right}" y2="{y:.1f}" stroke="{stroke}" stroke-width="1"{dash}/>')
    name = f"limit {ms} ms" if ms == limit_ms else f"{ms:,} ms"
    a(f'<text class="tick" x="{line_left - 6}" y="{y + 4:.1f}" text-anchor="end">{name}</text>')
tick = 200_000 if x_high <= 1_000_000 else 400_000
for value in range(0, int(x_high) + 1, tick):
    a(f'<text class="tick" x="{sx(value):.1f}" y="{top + plot_h + 16}" text-anchor="middle">{thousands(value)}</text>')
a(f'<text class="tick" x="{line_right}" y="{top + plot_h + 32}" text-anchor="end">spans a second sent</text>')
labels = []
for name in servers:
    fill = looks[name][1]
    stroke = outlines.get(fill, fill)
    dash = ' stroke-dasharray="5 3"' if fill in outlines else ""
    points = [(sx(step["sent"]), sy(step[name][0]), step[name]) for step in steps if name in step]
    a(f'<polyline points="{" ".join(f"{x:.1f},{y:.1f}" for x, y, _ in points)}" fill="none" stroke="var({stroke})" '
      f'stroke-width="2"{dash}/>')
    for x, y, (_, failed) in points:
        inside = "var(--surface)" if failed else f"var({fill})"
        a(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{inside}" stroke="var({stroke})" stroke-width="2"/>')
    x, y, (last, failed) = points[-1]
    if failed:
        text = {"refused": "refused", "rate": "short of the rate", "load": "load full"}.get(failed, f"p99 {last:,.0f} ms")
        labels.append([max(y + 4, top + 8), x, text])
# Each label of a failed step sits beside its point, to the right, or above it and to the left at
# the right edge. A label that would cover the one above it moves down a line.
char_w, line_h = 6.2, 13
placed = []
merge_px = 6
unique = []
for label in sorted(labels):
    if any(text == label[2] and abs(x - label[1]) < merge_px and abs(y - label[0]) < merge_px for y, x, text in unique):
        continue
    unique.append(label)
for label in unique:
    y, x, text = label
    width = len(text) * char_w
    at_edge = x + 8 + width > line_right
    left = x - 8 - width if at_edge else x + 8
    if at_edge:
        y = max(y - 12, top + 8)
    for other_y, other_left, other_width in placed:
        if abs(y - other_y) < line_h and left < other_left + other_width and other_left < left + width:
            y = other_y + line_h
    placed.append((y, left, width))
    a(f'<text class="val" x="{left:.1f}" y="{y:.1f}">{text}</text>')
a('</svg>')
open(out, "w").write("\n".join(parts) + "\n")
