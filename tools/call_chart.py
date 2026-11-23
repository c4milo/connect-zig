#!/usr/bin/env python3
"""Draws docs/images/call-vs-go.svg from the table of CI's bench-compare job (tools/bench_check.sh).

    tools/call_chart.py <table.md> <run> <commit> [out.svg]

<table.md> holds the job's table, or the job's whole output, as for tools/speed_chart.py. The
chart draws the routed unary call of bench/call.zig: one call in memory through the router, the
route, the protocol and the codec, with no socket, no TLS and no HTTP/2 framing. Each bar is an
implementation's speed in multiples of connect-go's: connect-go's time over the implementation's
time. connect-go is the unit, a line at 1. The column "Go time / Zig time" gives connect-zig's
bar, and "Go ns/op" over "Rust ns/op" gives connect-rust's. <run> and <commit> name the run in
the subtitle, as docs/performance.md asks of a published number.
"""

import math
import pathlib
import re
import sys

table_path, run, commit = sys.argv[1:4]
out = sys.argv[4] if len(sys.argv) > 4 else "docs/images/call-vs-go.svg"
protocols = ["Connect", "gRPC"]
op_keys = ["Connect unary call", "gRPC unary call"]
msgs = ["Small, 40 B", "Medium, 1 KB"]
msg_keys = ["small", "medium"]
go_over_zig = "Go time / Zig time"
go_time, rust_time, zig_time = "Go ns/op", "Rust ns/op", "Zig ns/op"


def pinned(path, pattern):
    """The version a lock file pins, so the legend names what ran."""
    match = re.search(pattern, pathlib.Path(path).read_text())
    return match.group(1) if match else "unknown"


connect_go_version = pinned("bench/go/go.mod", r"connectrpc\.com/connect (v[0-9.]+)")
connect_rust_version = pinned("bench/rust/Cargo.lock", r'name = "connectrpc"\nversion = "([0-9.]+)"')

columns = None


def number(cells, name):
    """A cell's number, or None when the table has no such column or the cell reads "absent"."""
    if name not in columns or cells[columns[name]] == "absent":
        return None
    return float(cells[columns[name]])


# For each message and protocol: connect-zig's and connect-rust's speed in multiples of
# connect-go's, and connect-zig's time a call in microseconds.
zig_speed, rust_speed, zig_us = {}, {}, {}
machine = None
with open(table_path) as table:
    for line in table:
        if line.startswith("Machine: "):
            machine = ", ".join(part.strip() for part in line[len("Machine: ") :].split(",")[:2])
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
        go_ns, rust_ns = number(cells, go_time), number(cells, rust_time)
        rust_speed[key] = go_ns / rust_ns if go_ns and rust_ns else None
        zig_us[key] = number(cells, zig_time) / 1000
missing = [(m, o) for m in msg_keys for o in op_keys if (m, o) not in zig_speed]
if missing:
    sys.exit(f"{table_path}: no row for {missing[0][0]}, {missing[0][1]}")
if None in zig_speed.values():
    sys.exit(f"{table_path}: connect-go did not run, and its time is the chart's unit")

series = [
    (zig_speed, "connect-zig", "--zig"),
    (rust_speed, f"connect-rust {connect_rust_version}", "--rust"),
]


def present(numbers):
    return [v for v in numbers.values() if v is not None]


def span(numbers):
    return f"{min(numbers):.1f} to {max(numbers):.1f} times"


zig_over_rust = [zig_speed[k] / rust_speed[k] for k in zig_speed if rust_speed[k] is not None]
title = f"connect-zig is {span(present(zig_speed))} as fast as connect-go"
if zig_over_rust:
    title += f", {span(zig_over_rust)} connect-rust"

W, H = 840, 272
pad_l = 24
legend_y = 110
pad_t = 134
panel_w, panel_h = 384, 120
gap_x = 24
label_w = 112
# The room past the longest bar for its label, "23.4×, 0.35 µs".
value_label_w = 92
plot_w = panel_w - label_w - value_label_w
x_max = max(2, math.ceil(max(present(zig_speed) + present(rust_speed))))
# The least pixels between two ticks, so that "20×" and "25×" stay apart.
tick_gap_min = 28
tick_step = next(step for step in (1, 2, 5, 10, 20, 50) if step * plot_w / x_max >= tick_gap_min)
bar_h, bar_gap, group_gap = 13, 2, 10
group_h = 2 * bar_h + bar_gap
row_h = group_h + group_gap


def sx(v):
    return v / x_max * plot_w


def bar(x, y, width, fill):
    """A bar with a 4px rounded data end, square at the baseline."""
    radius = min(4, width / 2)
    return (
        f'<path d="M{x:.1f},{y} h{width - radius:.1f} a{radius:.1f},{radius:.1f} 0 0 1 {radius:.1f},{radius:.1f} '
        f"v{bar_h - 2 * radius:.1f} a{radius:.1f},{radius:.1f} 0 0 1 {-radius:.1f},{radius:.1f} "
        f'h{-(width - radius):.1f} z" fill="var({fill})"/>'
    )


def describe(speeds):
    return "; ".join(
        f"{p}: "
        + ", ".join(
            f"{m} " + ("absent" if speeds[(mk, op)] is None else f"{speeds[(mk, op)]:.1f}x")
            for m, mk in zip(msgs, msg_keys, strict=True)
        )
        for p, op in zip(protocols, op_keys, strict=True)
    )


parts = []
a = parts.append
a(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">'
)
a('<title id="t">A routed unary call through connect-zig and connect-rust, against connect-go</title>')
a(
    f'<desc id="d">{title}. Each bar is an implementation\'s speed in multiples of connect-go '
    f"{connect_go_version}'s, which is connect-go's time a call over the implementation's, for a small and a "
    f"medium message in Connect and gRPC. connect-zig: {describe(zig_speed)}. connect-rust "
    f"{connect_rust_version}: {describe(rust_speed)}.</desc>"
)
a("""<style>
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
</style>""")
a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
a(f'<text class="title" x="{pad_l}" y="34">{title}</text>')
a(
    f'<text class="sub" x="{pad_l}" y="56">One unary call in memory: router, route, protocol and codec, with no socket, no TLS and '
    f"no HTTP/2 framing.</text>"
)
a(
    f'<text class="sub" x="{pad_l}" y="74">Each bar is a speed in multiples of connect-go\'s: its time over the bar\'s time. '
    f"A longer bar is faster.</text>"
)
where = f", {machine}" if machine else ""
a(
    f'<text class="sub" x="{pad_l}" y="92">One CI job ran all three, and each answered the same octets: run {run}, '
    f"commit {commit}{where}.</text>"
)
legend_x = pad_l
for _, name, fill in series:
    a(f'<rect x="{legend_x}" y="{legend_y - 10}" width="12" height="12" rx="2" fill="var({fill})"/>')
    a(f'<text class="legend" x="{legend_x + 18}" y="{legend_y}">{name}</text>')
    legend_x += 18 + 7 * len(name) + 24
# connect-go is the unit: the legend shows its line, not a bar.
a(
    f'<line x1="{legend_x}" y1="{legend_y - 4}" x2="{legend_x + 16}" y2="{legend_y - 4}" stroke="var(--unit)" stroke-width="1.5" stroke-dasharray="4 3"/>'
)
a(f'<text class="legend" x="{legend_x + 22}" y="{legend_y}">connect-go {connect_go_version}: the unit</text>')
for k, (protocol, op) in enumerate(zip(protocols, op_keys, strict=True)):
    px = pad_l + k * (panel_w + gap_x)
    ox = px + label_w
    a(f'<text class="panel" x="{px}" y="{pad_t + 14}">{protocol}</text>')
    top = pad_t + 30
    bottom = top + row_h * len(msgs) - group_gap
    for t in range(0, x_max + 1, tick_step):
        x = ox + sx(t)
        a(f'<line x1="{x:.1f}" y1="{top - 4}" x2="{x:.1f}" y2="{bottom + 4}" stroke="var(--grid)" stroke-width="1"/>')
        a(f'<text class="tick" x="{x:.1f}" y="{bottom + 18}" text-anchor="middle">{t}×</text>')
    for r, (m, mk) in enumerate(zip(msgs, msg_keys, strict=True)):
        y = top + r * row_h
        a(f'<text class="row" x="{ox - 10}" y="{y + group_h / 2 + 4:.1f}" text-anchor="end">{m}</text>')
        for s, (speeds, _, fill) in enumerate(series):
            by = y + s * (bar_h + bar_gap)
            v = speeds[(mk, op)]
            if v is None:
                a(f'<text class="val" x="{ox + 6:.1f}" y="{by + bar_h - 3}">absent</text>')
                continue
            w = max(sx(v), 1)
            a(bar(ox, by, w, fill))
            label = f"{v:.1f}×, {zig_us[(mk, op)]:.2f} µs" if s == 0 else f"{v:.1f}×"
            a(f'<text class="val" x="{ox + w + 5:.1f}" y="{by + bar_h - 3}">{label}</text>')
    x1 = ox + sx(1)
    a(
        f'<line x1="{x1:.1f}" y1="{top - 8}" x2="{x1:.1f}" y2="{bottom + 4}" stroke="var(--unit)" stroke-width="1.5" stroke-dasharray="4 3"/>'
    )
    if k == 0:
        a(f'<text class="note" x="{x1 + 4:.1f}" y="{top - 10}">1× = as fast as connect-go</text>')
a("</svg>")
pathlib.Path(out).write_text("\n".join(parts) + "\n")
