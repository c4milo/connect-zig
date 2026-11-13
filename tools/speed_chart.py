#!/usr/bin/env python3
"""Draws docs/images/speed-vs-go.svg from the table of CI's bench-compare job (tools/bench_check.sh).

    tools/speed_chart.py <table.md> <run> <commit> [out.svg]

<table.md> holds the job's table. The chart draws a bar for connect-zig and a bar for Buffa: a
runtime's speed in multiples of Go's, which is Go's time over the runtime's time. Go is the unit,
a line at 1. The column "Go time / Zig time" gives connect-zig's bar, and "Go ns/op" over
"Rust ns/op" gives Buffa's. A cell that reads "absent" draws no bar. <run> and <commit> name the
run in the chart's subtitle, as docs/performance.md asks of a published number. The title states
what the numbers show, so a row where Buffa beats connect-zig changes it.
A PNG for places that show no SVG comes from any browser's screenshot of the file.
"""
import math
import re
import sys

table_path, run, commit = sys.argv[1:4]
out = sys.argv[4] if len(sys.argv) > 4 else "docs/images/speed-vs-go.svg"
ops = ["Binary encode", "Binary decode, every field read", "JSON encode", "JSON decode"]
op_keys = ["binary encode", "binary decode+walk", "JSON encode", "JSON decode"]
msgs = ["Small, 40 B", "Medium, 1 KB", "Large, 180 KB", "Deep, 50 levels"]
msg_keys = ["small", "medium", "large", "deep"]
# The table's columns the chart reads.
go_over_zig = "Go time / Zig time"
rust_over_zig = "Rust time / Zig time"
go_time, rust_time = "Go ns/op", "Rust ns/op"


def pinned(path, pattern):
    """The version a lock file pins, so the legend names what ran."""
    match = re.search(pattern, open(path).read())
    return match.group(1) if match else "unknown"


go_version = pinned("bench/go/go.mod", r"google\.golang\.org/protobuf (v[0-9.]+)")
buffa_version = pinned("bench/rust/Cargo.lock", r'name = "buffa"\nversion = "([0-9.]+)"')

# Read the table by its header, so a column added or moved does not break the chart.
columns = None


def number(cells, name):
    """A cell's number, or None when the table has no such column or the cell reads "absent"."""
    if name not in columns or cells[columns[name]] == "absent":
        return None
    return float(cells[columns[name]])


# For each message and operation: connect-zig's and Buffa's speed in multiples of Go's, and
# Buffa's time over connect-zig's, which says who is faster in the cell.
zig_speed, buffa_speed, buffa_over_zig = {}, {}, {}
for line in open(table_path):
    if not line.startswith("|"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if cells[0] == "message":
        columns = {name: index for index, name in enumerate(cells)}
        continue
    if columns is None or cells[0] not in msg_keys or cells[1] not in op_keys:
        continue
    key = (cells[0], cells[1])
    zig_speed[key] = number(cells, go_over_zig)
    buffa_over_zig[key] = number(cells, rust_over_zig)
    go_ns, rust_ns = number(cells, go_time), number(cells, rust_time)
    buffa_speed[key] = go_ns / rust_ns if go_ns and rust_ns else None
missing = [(m, o) for m in msg_keys for o in op_keys if (m, o) not in zig_speed]
if missing:
    sys.exit(f"{table_path}: no row for {missing[0][0]}, {missing[0][1]}")
if None in zig_speed.values():
    sys.exit(f"{table_path}: Go did not run, and Go's time is the chart's unit")

# The two runtimes the chart draws: their speeds, the legend's name, and the CSS variable of the bar.
series = [
    (zig_speed, "connect-zig", "--zig"),
    (buffa_speed, f"Rust (Buffa {buffa_version})", "--rust"),
]


def present(numbers):
    return [v for v in numbers.values() if v is not None]


def span(numbers):
    return f"{min(numbers):.1f} to {max(numbers):.1f} times"


# The title states what the numbers show and nothing more: for each baseline, the range when
# connect-zig is faster in every cell, and otherwise how many cells the baseline wins.
def claim(numbers, name):
    if not numbers:
        return f"{name} did not run"
    if min(numbers) > 1:
        return f"connect-zig is {span(numbers)} faster than {name}"
    beaten = sum(1 for v in numbers if v < 1)
    return f"{name} beats connect-zig in {beaten} of {len(numbers)} cells"


title = f"{claim(present(zig_speed), 'Go')}; {claim(present(buffa_over_zig), 'Buffa')}"
title = title.replace("; connect-zig is ", " and ").replace("; Buffa beats connect-zig", "; Buffa beats it")

W, H = 840, 560
pad_l = 24
legend_y = 92
pad_t = 116
panel_w, panel_h = 384, 196
gap_x, gap_y = 24, 24
label_w = 112        # message names
plot_w = panel_w - label_w - 44
x_max = max(2, math.ceil(max(present(zig_speed) + present(buffa_speed))))
tick_step = 1 if x_max <= 8 else 2
bar_h, bar_gap, group_gap = 13, 2, 10
group_h = 2 * bar_h + bar_gap
row_h = group_h + group_gap


def sx(v):
    return v / x_max * plot_w


def bar(x, y, width, fill):
    """A bar with a 4px rounded data end, square at the baseline."""
    radius = min(4, width / 2)
    return (f'<path d="M{x:.1f},{y} h{width - radius:.1f} a{radius:.1f},{radius:.1f} 0 0 1 {radius:.1f},{radius:.1f} '
            f'v{bar_h - 2 * radius:.1f} a{radius:.1f},{radius:.1f} 0 0 1 {-radius:.1f},{radius:.1f} '
            f'h{-(width - radius):.1f} z" fill="var({fill})"/>')


def describe(speeds):
    return "; ".join(
        f"{m}: " + ", ".join(
            f"{o} " + ("absent" if speeds[(k, ok)] is None else f"{speeds[(k, ok)]:.1f}x")
            for o, ok in zip(ops, op_keys))
        for m, k in zip(msgs, msg_keys))


parts = []
a = parts.append
a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">')
a('<title id="t">connect-zig and Buffa against Go\'s protobuf runtime</title>')
a(f'<desc id="d">{title}. Each bar is a runtime\'s speed in multiples of Go\'s, which is the time of Go, '
  f'google.golang.org/protobuf {go_version}, over the runtime\'s time, for four messages and four '
  f'operations. connect-zig: {describe(zig_speed)}. Rust, Buffa {buffa_version}: {describe(buffa_speed)}.</desc>')
a('''<style>
svg { --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#8a8984; --grid:#e4e3df; --zig:#2a78d6; --rust:#eb6834; --unit:#52514e; }
@media (prefers-color-scheme: dark) {
  svg { --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#8f8e86; --grid:#33332f; --zig:#3987e5; --rust:#d95926; --unit:#c3c2b7; }
}
text { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; fill: var(--ink); }
.title { font-size: 17px; font-weight: 600; }
.sub { font-size: 12.5px; fill: var(--ink2); }
.panel { font-size: 14px; font-weight: 600; }
.row { font-size: 12.5px; fill: var(--ink2); }
.val { font-size: 11px; font-weight: 600; paint-order: stroke; stroke: var(--surface); stroke-width: 3px; stroke-linejoin: round; }
.tick { font-size: 11px; fill: var(--muted); }
.note { font-size: 11.5px; fill: var(--ink2); }
.legend { font-size: 12.5px; fill: var(--ink2); }
</style>''')
a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
a(f'<text class="title" x="{pad_l}" y="34">{title}</text>')
a(f'<text class="sub" x="{pad_l}" y="56">Each bar is a runtime\'s speed in multiples of Go\'s: Go\'s time over the runtime\'s time. '
  f'A longer bar is faster.</text>')
a(f'<text class="sub" x="{pad_l}" y="74">The three programs ran in one CI job and wrote the same octets: run {run}, commit {commit}.</text>')
legend_x = pad_l
for _, name, fill in series:
    a(f'<rect x="{legend_x}" y="{legend_y - 10}" width="12" height="12" rx="2" fill="var({fill})"/>')
    a(f'<text class="legend" x="{legend_x + 18}" y="{legend_y}">{name}</text>')
    legend_x += 18 + 7 * len(name) + 24
# Go is the unit: the legend shows its line, not a bar.
a(f'<line x1="{legend_x}" y1="{legend_y - 4}" x2="{legend_x + 16}" y2="{legend_y - 4}" stroke="var(--unit)" stroke-width="1.5" stroke-dasharray="4 3"/>')
a(f'<text class="legend" x="{legend_x + 22}" y="{legend_y}">Go (google.golang.org/protobuf {go_version}), the unit</text>')
for k, op in enumerate(ops):
    px = pad_l + (k % 2) * (panel_w + gap_x)
    py = pad_t + (k // 2) * (panel_h + gap_y)
    ox = px + label_w
    a(f'<text class="panel" x="{px}" y="{py + 14}">{op}</text>')
    top = py + 30
    bottom = top + row_h * len(msgs) - group_gap
    for t in range(0, x_max + 1, tick_step):
        x = ox + sx(t)
        a(f'<line x1="{x:.1f}" y1="{top - 4}" x2="{x:.1f}" y2="{bottom + 4}" stroke="var(--grid)" stroke-width="1"/>')
        a(f'<text class="tick" x="{x:.1f}" y="{bottom + 18}" text-anchor="middle">{t}×</text>')
    for r, (m, key) in enumerate(zip(msgs, msg_keys)):
        y = top + r * row_h
        a(f'<text class="row" x="{ox - 10}" y="{y + group_h / 2 + 4:.1f}" text-anchor="end">{m}</text>')
        for s, (speeds, _, fill) in enumerate(series):
            by = y + s * (bar_h + bar_gap)
            v = speeds[(key, op_keys[k])]
            if v is None:
                a(f'<text class="val" x="{ox + 6:.1f}" y="{by + bar_h - 3}">absent</text>')
                continue
            w = max(sx(v), 1)
            a(bar(ox, by, w, fill))
            a(f'<text class="val" x="{ox + w + 5:.1f}" y="{by + bar_h - 3}">{v:.1f}×</text>')
    x1 = ox + sx(1)
    a(f'<line x1="{x1:.1f}" y1="{top - 8}" x2="{x1:.1f}" y2="{bottom + 4}" stroke="var(--unit)" stroke-width="1.5" stroke-dasharray="4 3"/>')
    if k == 0:
        a(f'<text class="note" x="{x1 + 4:.1f}" y="{top - 10}">1× = as fast as Go</text>')
a('</svg>')
open(out, 'w').write("\n".join(parts) + "\n")
