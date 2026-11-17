#!/usr/bin/env python3
"""Draws a chart of docs/images/ from a production table of CI's fullstack job (decision 44).

    tools/fullstack_chart.py <log> <run> <commit> <transport> [out.svg]

<log> holds the job's whole output, or the reports of tools/fullstack/production.sh. <transport>
picks the table: `tls`, connect-zig against the Collector and Vector, or `cleartext`, against the
Collector and Rotel. The chart draws the production model: one gateway core for 33,000 servers,
516 connections and a mix of gzip exports. Its left panel gives the spans a second each server's
core held with p99 at most 100 ms and no call refused. Its right panel gives each step's p99
against the spans a second sent, on a log scale, with the 100 ms limit. <run> and <commit> name
the run in the subtitle, as docs/performance.md asks of a published number.
"""
import math
import re
import sys

log_path, run, commit, transport = sys.argv[1:5]
out = sys.argv[5] if len(sys.argv) > 5 else f"docs/images/fullstack{'' if transport == 'tls' else '-cleartext'}.svg"
over = "over TLS" if transport == "tls" else "over cleartext h2"
# Each server's name in the report, its name in the legend, and its color: one color a server, in
# every chart of the README.
looks = {
    "connect-zig": ("connect-zig", "--zig"),
    "Collector": ("OpenTelemetry Collector", "--otel"),
    "Vector": ("Vector", "--vector"),
    "Rotel": ("Rotel", "--rotel"),
}
limit_ms = 100


def number(text):
    return float(text.replace(",", "").rstrip("%"))


held, steps, machine, section, columns = {}, [], None, False, None
for line in open(log_path):
    line = line.strip()
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
    if cells[0] == "exports a connection a second":
        columns = {cells[index][:-len(" p99")]: index for index in range(2, len(cells), 2)}
    elif cells[0] in looks and cells[1] != "none":
        held[cells[0]] = {"spans": number(cells[1]), "p99": number(cells[4])}
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

others = [name for name in servers if name != "connect-zig"]
ratios = [f"{held['connect-zig']['spans'] / held[name]['spans']:.1f} times {'the ' if name == 'Collector' else ''}{name}'s"
          for name in others]
title = f"One core holds {' and '.join(ratios)} spans a second, with p99 under {limit_ms} ms"

W, H = 840, 340
pad_l = 24
legend_y = 112
top = 168
plot_h = 128
bar_left, bar_w = pad_l + 104, 210
line_left, line_right = 448, 800
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
a(f'<title id="t">The spans a second one core holds {over}, connect-zig against {", ".join(others)}, as one gateway core for 33,000 servers</title>')
climb = "; ".join(
    f"{name}: " + ", ".join(f"{thousands(step['sent'])} {step[name][0]:g} ms" + (f" {step[name][1]}" if step[name][1] else "")
                            for step in steps if name in step)
    for name in servers)
spans = ", ".join(f"{name} {held[name]['spans']:,.0f} spans a second at p99 {held[name]['p99']:g} ms" for name in servers)
a(f'<desc id="d">{title}. {spans}. p99 at each step: {climb}.</desc>')
a('''<style>
svg { --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#8a8984; --grid:#e4e3df; --zig:#2a78d6; --otel:#b07d00; --vector:#b8407f; --rotel:#722626; }
@media (prefers-color-scheme: dark) {
  svg { --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#8f8e86; --grid:#33332f; --zig:#3987e5; --otel:#c99512; --vector:#d0599a; --rotel:#b84545; }
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
a(f'<text class="sub" x="{pad_l}" y="56">Each server holds 516 connections {over}, as one core of a 64-core gateway for 33,000 servers, and</text>')
a(f'<text class="sub" x="{pad_l}" y="74">takes gzip OTLP exports of 16, 128 and 512 spans. The rate climbs until p99 passes {limit_ms} ms or a call is refused.</text>')
where = f", {machine}" if machine else ""
a(f'<text class="sub" x="{pad_l}" y="92">One CI job ran all, and checked every span: run {run}, commit {commit}{where}.</text>')
legend_x = pad_l
for name in servers:
    label, fill = looks[name]
    a(f'<rect x="{legend_x}" y="{legend_y - 10}" width="12" height="12" rx="2" fill="var({fill})"/>')
    a(f'<text class="legend" x="{legend_x + 18}" y="{legend_y}">{label}</text>')
    legend_x += 18 + 7 * len(label) + 24

a(f'<text class="panel" x="{pad_l}" y="{top - 14}">Spans a second one core holds</text>')
bar_h, bar_gap = 20, 22
spans_high = max(item["spans"] for item in held.values())
for index, name in enumerate(servers):
    fill = looks[name][1]
    y = top + 12 + index * (bar_h + bar_gap)
    width = max(held[name]["spans"] / spans_high * bar_w, 1)
    radius = min(4, width / 2)
    a(f'<text class="row" x="{bar_left - 10}" y="{y + bar_h / 2 + 4:.1f}" text-anchor="end">{name}</text>')
    a(f'<path d="M{bar_left},{y} h{width - radius:.1f} a{radius},{radius} 0 0 1 {radius},{radius} v{bar_h - 2 * radius} '
      f'a{radius},{radius} 0 0 1 {-radius},{radius} h{-(width - radius):.1f} z" fill="var({fill})"/>')
    a(f'<text class="val" x="{bar_left + 4:.1f}" y="{y + bar_h + 13}">{held[name]["spans"]:,.0f} spans/s, p99 {held[name]["p99"]:g} ms</text>')

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
    points = [(sx(step["sent"]), sy(step[name][0]), step[name]) for step in steps if name in step]
    a(f'<polyline points="{" ".join(f"{x:.1f},{y:.1f}" for x, y, _ in points)}" fill="none" stroke="var({fill})" stroke-width="2"/>')
    for x, y, (_, failed) in points:
        inside = "var(--surface)" if failed else f"var({fill})"
        a(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{inside}" stroke="var({fill})" stroke-width="2"/>')
    x, y, (last, failed) = points[-1]
    if failed:
        text = "refused" if failed == "refused" else ("short of the rate" if failed == "rate" else f"p99 {last:,.0f} ms")
        labels.append([max(y + 4, top + 8), x, text])
# Each label of a failed step sits beside its point, to the right, or above it and to the left at
# the right edge. A label that would cover the one above it moves down a line.
char_w, line_h = 6.2, 13
placed = []
for label in sorted(labels):
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
