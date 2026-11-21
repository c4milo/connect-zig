#!/usr/bin/env python3
"""Draws docs/images/validate-vs-go.svg from the table of CI's validate-compare job
(tools/validate_compare_check.sh).

    tools/validate_chart.py <table.md> <run> <commit> [out.svg]

<table.md> holds the job's output. The chart draws its first table: for each message, the
nanoseconds of one decode with one validation of what it gives, which a server runs for each
request. Each bar is an implementation's speed in multiples of protovalidate-go's: its time over
the implementation's time. protovalidate-go is the unit, a line at 1. The axis is logarithmic,
since the implementations differ by up to a thousand times. <run> and <commit> name the run in
the subtitle, as docs/performance.md asks of a published number.
"""
import json
import math
import re
import sys

table_path, run, commit = sys.argv[1:4]
out = sys.argv[4] if len(sys.argv) > 4 else "docs/images/validate-vs-go.svg"
cases = ["small valid", "small invalid", "medium valid", "medium invalid", "rules valid", "rules invalid"]


def pinned(path, pattern):
    """The version a lock file pins, so the legend names what ran."""
    match = re.search(pattern, open(path).read())
    return match.group(1) if match else "unknown"


go_version = pinned("bench/validate/go/go.mod", r"buf\.build/go/protovalidate (v[0-9.]+)")
es_version = json.load(open("bench/validate/node/package.json"))["dependencies"]["@bufbuild/protovalidate"]
buffa_version = pinned("bench/validate/rust/Cargo.lock", r'name = "protovalidate-buffa"\nversion = "([0-9.]+)"')
prost_version = pinned("bench/validate/rust/Cargo.lock", r'name = "prost-protovalidate"\nversion = "([0-9.]+)"')

columns, times, machine = None, {}, None
for line in open(table_path):
    if line.startswith("Machine: "):
        machine = line[len("Machine: "):].strip()
    if not line.startswith("|"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if cells[0] == "case":
        # The first table is decode and validate; the second, validate alone, is not drawn.
        if columns is not None:
            break
        columns = {name: index for index, name in enumerate(cells)}
        continue
    if columns is None or cells[0] not in cases:
        continue
    times[cells[0]] = {label: float(cells[columns[f"{label} total ns"]]) for label in ("Zig", "Go", "Node", "buffa", "prost")}
missing = [case for case in cases if case not in times]
if missing:
    sys.exit(f"{table_path}: no row for {missing[0]}")

series = [
    ("Zig", "connect-zig", "--zig"),
    ("buffa", f"protovalidate-buffa {buffa_version}", "--buffa"),
    ("prost", f"prost-protovalidate {prost_version}", "--prost"),
    ("Node", f"protovalidate-es {es_version}", "--es"),
]
speed = {case: {label: times[case]["Go"] / times[case][label] for label, _, _ in series} for case in cases}
everything = [v for case in cases for v in speed[case].values()]
zig_speeds = [speed[case]["Zig"] for case in cases]
fastest = sum(1 for case in cases if max(speed[case], key=speed[case].get) == "Zig")
title = f"connect-zig decodes and validates {min(zig_speeds):.0f} to {max(zig_speeds):.0f} times as fast as protovalidate-go"

W = 840
pad_l = 24
legend_y = 128
pad_t = 170
label_w = 140
plot_w = W - pad_l - label_w - 96
low = math.floor(math.log10(min(everything + [1])))
high = math.ceil(math.log10(max(everything + [1])))
bar_h, bar_gap, group_gap = 12, 2, 14
group_h = len(series) * bar_h + (len(series) - 1) * bar_gap
row_h = group_h + group_gap
H = pad_t + 16 + row_h * len(cases) + 40


def sx(v):
    return (math.log10(v) - low) / (high - low) * plot_w


def bar(x, y, width, fill):
    """A bar with a 4px rounded data end, square at the baseline."""
    radius = min(4, width / 2)
    return (f'<path d="M{x:.1f},{y} h{width - radius:.1f} a{radius:.1f},{radius:.1f} 0 0 1 {radius:.1f},{radius:.1f} '
            f'v{bar_h - 2 * radius:.1f} a{radius:.1f},{radius:.1f} 0 0 1 {-radius:.1f},{radius:.1f} '
            f'h{-(width - radius):.1f} z" fill="var({fill})"/>')


def multiple(v):
    return f"{v:.0f}×" if v >= 10 else f"{v:.1f}×" if v >= 1 else f"{v:.2f}×"


def tick(e):
    return f"{10 ** e:g}×"


describe = "; ".join(f"{case}: " + ", ".join(f"{name} {multiple(speed[case][label])}" for label, name, _ in series) for case in cases)
parts = []
a = parts.append
a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">')
a('<title id="t">A decode and a validation of one message by five protovalidate implementations, against protovalidate-go</title>')
a(f'<desc id="d">{title}. Each bar is an implementation\'s speed in multiples of protovalidate-go {go_version}\'s, '
  f'which is protovalidate-go\'s time over the implementation\'s, on a logarithmic axis. {describe}.</desc>')
a('''<style>
svg { --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#8a8984; --grid:#e4e3df; --zig:#2a78d6; --buffa:#eb6834; --prost:#c79a2c; --es:#3a9b6c; --unit:#52514e; }
@media (prefers-color-scheme: dark) {
  svg { --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#8f8e86; --grid:#33332f; --zig:#3987e5; --buffa:#d95926; --prost:#d6aa3e; --es:#4caf7d; --unit:#c3c2b7; }
}
text { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; fill: var(--ink); }
.title { font-size: 17px; font-weight: 600; }
.sub { font-size: 12.5px; fill: var(--ink2); }
.row { font-size: 12.5px; fill: var(--ink2); }
.val { font-size: 11px; font-weight: 600; paint-order: stroke; stroke: var(--surface); stroke-width: 3px; stroke-linejoin: round; }
.tick { font-size: 11px; fill: var(--muted); }
.note { font-size: 11.5px; fill: var(--ink2); }
.legend { font-size: 12.5px; fill: var(--ink2); }
</style>''')
a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
a(f'<text class="title" x="{pad_l}" y="34">{title}</text>')
a(f'<text class="sub" x="{pad_l}" y="56">One decode of a request message and one validation of it against the rules of its schema, '
  f'in memory.</text>')
a(f'<text class="sub" x="{pad_l}" y="74">Each bar is a speed in multiples of protovalidate-go {go_version}\'s: its time over the '
  f'bar\'s time, on a logarithmic axis.</text>')
a(f'<text class="sub" x="{pad_l}" y="92">connect-zig is the fastest in {fastest} of {len(cases)} cases. Each implementation gave '
  f'each message the same verdict.</text>')
where = f", {machine}" if machine else ""
a(f'<text class="sub" x="{pad_l}" y="110">One CI job ran all five: run {run}, commit {commit}{where}.</text>')
legend_x = pad_l
for _, name, fill in series:
    a(f'<rect x="{legend_x}" y="{legend_y - 10}" width="12" height="12" rx="2" fill="var({fill})"/>')
    a(f'<text class="legend" x="{legend_x + 18}" y="{legend_y}">{name}</text>')
    legend_x += 18 + 7 * len(name) + 20
# protovalidate-go is the unit: the legend's second row shows its line, not a bar.
unit_y = legend_y + 20
a(f'<line x1="{pad_l}" y1="{unit_y - 4}" x2="{pad_l + 16}" y2="{unit_y - 4}" stroke="var(--unit)" stroke-width="1.5" stroke-dasharray="4 3"/>')
a(f'<text class="legend" x="{pad_l + 22}" y="{unit_y}">protovalidate-go {go_version}: the unit</text>')
ox = pad_l + label_w
top = pad_t + 16
bottom = top + row_h * len(cases) - group_gap
for e in range(low, high + 1):
    x = ox + sx(10 ** e)
    a(f'<line x1="{x:.1f}" y1="{top - 4}" x2="{x:.1f}" y2="{bottom + 4}" stroke="var(--grid)" stroke-width="1"/>')
    a(f'<text class="tick" x="{x:.1f}" y="{bottom + 18}" text-anchor="middle">{tick(e)}</text>')
for r, case in enumerate(cases):
    y = top + r * row_h
    a(f'<text class="row" x="{ox - 10}" y="{y + group_h / 2 + 4:.1f}" text-anchor="end">{case}</text>')
    for s, (label, _, fill) in enumerate(series):
        by = y + s * (bar_h + bar_gap)
        v = speed[case][label]
        w = max(sx(v), 1)
        a(bar(ox, by, w, fill))
        text = f"{multiple(v)}, {times[case][label]:,.0f} ns" if label == "Zig" else multiple(v)
        a(f'<text class="val" x="{ox + w + 5:.1f}" y="{by + bar_h - 2}">{text}</text>')
x1 = ox + sx(1)
a(f'<line x1="{x1:.1f}" y1="{top - 8}" x2="{x1:.1f}" y2="{bottom + 4}" stroke="var(--unit)" stroke-width="1.5" stroke-dasharray="4 3"/>')
a(f'<text class="note" x="{x1 + 4:.1f}" y="{top - 10}">1× = as fast as protovalidate-go</text>')
a('</svg>')
open(out, "w").write("\n".join(parts) + "\n")
