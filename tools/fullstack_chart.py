#!/usr/bin/env python3
"""Draws docs/images/fullstack.svg from the production table of CI's fullstack job (decision 44).

    tools/fullstack_chart.py <log> <run> <commit> [out.svg]

<log> holds the job's whole output, or the report of tools/fullstack/production.sh. The chart
draws the production model: one gateway core for 33,000 servers, 516 TLS connections and a mix
of gzip exports. Its left panel gives the spans a second each server's core held with p99 at most
100 ms and no call refused. Its right panel gives each step's p99 against the spans a second
sent, on a log scale, with the 100 ms limit, so it shows where each server's queue grew. <run>
and <commit> name the run in the subtitle, as docs/performance.md asks of a published number.
"""
import math
import re
import sys

log_path, run, commit = sys.argv[1:4]
out = sys.argv[4] if len(sys.argv) > 4 else "docs/images/fullstack.svg"
servers = [("connect-zig", "connect-zig", "--zig"), ("Collector", "OpenTelemetry Collector", "--otel")]
limit_ms = 100


def number(text):
    return float(text.replace(",", "").rstrip("%"))


held, steps, machine, section = {}, [], None, None
for line in open(log_path):
    line = line.strip()
    if line.startswith("## "):
        section = "production" if "production" in line else "other"
        continue
    if section != "production":
        continue
    if line.startswith("Machine: ") and machine is None:
        machine = ", ".join(part.strip() for part in line[len("Machine: "):].rstrip(".").split(",")[:2])
    if not line.startswith("|") or "---" in line:
        continue
    cells = [cell.strip() for cell in line.strip("|").split("|")]
    if cells[0] in ("connect-zig", "Collector") and cells[1] not in ("none",):
        held[cells[0]] = {"spans": number(cells[1]), "p99": number(cells[4])}
    elif re.fullmatch(r"[0-9.]+", cells[0]):
        row = {"sent": number(cells[1])}
        for (name, _, _), (p99, _) in zip(servers, [(cells[2], cells[3]), (cells[4], cells[5])]):
            if p99:
                value = re.match(r"([0-9.,]+)(?: \((\w+)\))?", p99)
                row[name] = (number(value.group(1)), value.group(2))
        steps.append(row)
if len(held) < len(servers) or not steps:
    sys.exit(f"{log_path}: no production table with both servers")

ratio = held["connect-zig"]["spans"] / held["Collector"]["spans"]
title = f"One core holds {ratio:.1f} times the Collector's spans a second, with p99 under {limit_ms} ms"

W, H = 840, 330
pad_l = 24
legend_y = 112
top = 168
plot_h = 120
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
a('<title id="t">The spans a second one core holds, connect-zig against the OpenTelemetry Collector, as one gateway core for 33,000 servers</title>')
climb = "; ".join(
    f"{name}: " + ", ".join(f"{thousands(step['sent'])} {step[key][0]:g} ms" + (f" {step[key][1]}" if step[key][1] else "")
                            for step in steps if key in step)
    for key, name, _ in servers)
a(f'<desc id="d">{title}. connect-zig held {held["connect-zig"]["spans"]:,.0f} spans a second at p99 '
  f'{held["connect-zig"]["p99"]:g} ms, and the Collector {held["Collector"]["spans"]:,.0f} at p99 {held["Collector"]["p99"]:g} ms. '
  f'p99 at each step: {climb}.</desc>')
a('''<style>
svg { --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#8a8984; --grid:#e4e3df; --zig:#2a78d6; --otel:#b07d00; }
@media (prefers-color-scheme: dark) {
  svg { --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#8f8e86; --grid:#33332f; --zig:#3987e5; --otel:#c99512; }
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
a(f'<text class="sub" x="{pad_l}" y="56">Each server holds 516 TLS connections, as one core of a 64-core gateway for 33,000 servers, and takes</text>')
a(f'<text class="sub" x="{pad_l}" y="74">gzip OTLP exports of 16, 128 and 512 spans. The rate climbs until p99 passes {limit_ms} ms or a call is refused.</text>')
where = f", {machine}" if machine else ""
a(f'<text class="sub" x="{pad_l}" y="92">One CI job ran both, and checked every span: run {run}, commit {commit}{where}.</text>')
legend_x = pad_l
for _, name, fill in servers:
    a(f'<rect x="{legend_x}" y="{legend_y - 10}" width="12" height="12" rx="2" fill="var({fill})"/>')
    a(f'<text class="legend" x="{legend_x + 18}" y="{legend_y}">{name}</text>')
    legend_x += 18 + 7 * len(name) + 24

a(f'<text class="panel" x="{pad_l}" y="{top - 14}">Spans a second one core holds</text>')
bar_h, bar_gap = 22, 18
spans_high = max(item["spans"] for item in held.values())
for index, (key, name, fill) in enumerate(servers):
    y = top + 18 + index * (bar_h + bar_gap)
    width = max(held[key]["spans"] / spans_high * bar_w, 1)
    radius = min(4, width / 2)
    a(f'<text class="row" x="{bar_left - 10}" y="{y + bar_h / 2 + 4:.1f}" text-anchor="end">{key}</text>')
    a(f'<path d="M{bar_left},{y} h{width - radius:.1f} a{radius},{radius} 0 0 1 {radius},{radius} v{bar_h - 2 * radius} '
      f'a{radius},{radius} 0 0 1 {-radius},{radius} h{-(width - radius):.1f} z" fill="var({fill})"/>')
    a(f'<text class="val" x="{bar_left + 4:.1f}" y="{y + bar_h + 13}">{held[key]["spans"]:,.0f} spans/s, p99 {held[key]["p99"]:g} ms</text>')

a(f'<text class="panel" x="{line_left - 40}" y="{top - 14}">p99 as the rate climbs</text>')
for ms in (1, 10, 100, 1000):
    y = sy(ms)
    dash = ' stroke-dasharray="4 3"' if ms == limit_ms else ""
    stroke = "var(--ink2)" if ms == limit_ms else "var(--grid)"
    a(f'<line x1="{line_left}" y1="{y:.1f}" x2="{line_right}" y2="{y:.1f}" stroke="{stroke}" stroke-width="1"{dash}/>')
    name = f"limit {ms} ms" if ms == limit_ms else f"{ms:,} ms"
    a(f'<text class="tick" x="{line_left - 6}" y="{y + 4:.1f}" text-anchor="end">{name}</text>')
for value in range(0, int(x_high) + 1, 200_000):
    a(f'<text class="tick" x="{sx(value):.1f}" y="{top + plot_h + 16}" text-anchor="middle">{thousands(value)}</text>')
a(f'<text class="tick" x="{line_right}" y="{top + plot_h + 32}" text-anchor="end">spans a second sent</text>')
for key, _, fill in servers:
    points = [(sx(step["sent"]), sy(step[key][0]), step[key][1]) for step in steps if key in step]
    a(f'<polyline points="{" ".join(f"{x:.1f},{y:.1f}" for x, y, _ in points)}" fill="none" stroke="var({fill})" stroke-width="2"/>')
    for x, y, failed in points:
        inside = "var(--surface)" if failed else f"var({fill})"
        a(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{inside}" stroke="var({fill})" stroke-width="2"/>')
    last = [step for step in steps if key in step][-1][key]
    x, y, failed = points[-1]
    if failed:
        label = "refused" if failed == "refused" else f"p99 {last[0]:,.0f} ms"
        a(f'<text class="val" x="{x - 8:.1f}" y="{y - 8:.1f}" text-anchor="end">{label}</text>')
a('</svg>')
open(out, "w").write("\n".join(parts) + "\n")
