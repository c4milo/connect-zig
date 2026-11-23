#!/usr/bin/env python3
"""Draws docs/images/call-routes.svg from the table of CI's bench-compare job (tools/bench_check.sh).

    tools/routes_chart.py <table.md> <run> <commit> [out.svg]

<table.md> holds the job's table, or the job's whole output, as for tools/speed_chart.py. The
chart draws how the small message's routed unary call (bench/call.zig) changes as its route table
grows: for connect-zig, connect-rust and connect-go, the time of a call in a table of 16 and of
256 routes over the time of the same call in a table of one route. Each implementation is its own
unit, so a flat line means the router's match costs the same at any size. A row whose cell reads
"absent" draws no point. <run> and <commit> name the run in the subtitle, as docs/performance.md
asks of a published number.
"""

import pathlib
import re
import sys

table_path, run, commit = sys.argv[1:4]
out = sys.argv[4] if len(sys.argv) > 4 else "docs/images/call-routes.svg"
protocols = [("Connect", "Connect unary call"), ("gRPC", "gRPC unary call")]
time_columns = [
    ("connect-zig", "Zig ns/op", "--zig"),
    ("connect-rust", "Rust ns/op", "--rust"),
    ("connect-go", "Go ns/op", "--go"),
]

columns = None
machine = None
# For each protocol and route count: each implementation's time a call, in nanoseconds.
times = {}
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
        if columns is None or cells[0] != "small":
            continue
        for _, operation in protocols:
            match = re.fullmatch(re.escape(operation) + r"(?:, (\d+) routes)?", cells[1])
            if not match:
                continue
            routes = int(match.group(1) or 1)
            times[(operation, routes)] = {
                name: (None if cells[columns[column]] == "absent" else float(cells[columns[column]]))
                for name, column, _ in time_columns
            }
counts = sorted({routes for _, routes in times})
if len(counts) < 2 or 1 not in counts:
    sys.exit(f"{table_path}: the table holds no calls in tables of more than one route")
for _, operation in protocols:
    for routes in counts:
        if (operation, routes) not in times:
            sys.exit(f"{table_path}: no row for {operation} in a table of {routes} routes")


def percent(change):
    """A ratio's change in whole percent, with its sign; a change that rounds to 0 reads +0%."""
    return f"{round(change * 100 - 100):+d}%"


def ratio(operation, routes, name):
    """A call's time in a table of `routes` routes over its time in a table of one."""
    base, now = times[(operation, 1)][name], times[(operation, routes)][name]
    return None if base is None or now is None else now / base


largest = counts[-1]
changes = []
for name, _, _ in time_columns:
    values = [ratio(operation, largest, name) for _, operation in protocols]
    values = [v for v in values if v is not None]
    if values:
        changes.append(f"{name} {percent(max(values))}")
title = f"1 to {largest} routes, a call's time at most: " + ", ".join(changes)

W, H = 840, 320
pad_l = 24
legend_y = 110
pad_t = 134
panel_w = 384
gap_x = 24
plot_l, plot_r = 52, 96
plot_h = 120
ratios = [ratio(o, r, n) for _, o in protocols for r in counts for n, _, _ in time_columns]
ratios = [v for v in ratios if v is not None]
y_low = min(0.9, min(ratios))
y_high = max(1.1, max(ratios))
# The axis steps by 5% of the one-route time, or by 10% when the span is wide.
step = 0.05 if y_high - y_low <= 0.5 else 0.1
y_low = step * int(y_low / step)
y_high = step * (int(y_high / step) + 1)


def sy(v, top):
    return top + plot_h - (v - y_low) / (y_high - y_low) * plot_h


parts = []
a = parts.append
a(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">'
)
a(
    '<title id="t">The time of a routed call as its route table grows, for connect-zig, connect-rust and connect-go</title>'
)
description = "; ".join(
    f"{protocol}, {name}: "
    + ", ".join(
        f"{routes} routes {times[(operation, routes)][name]:.1f} ns"
        if times[(operation, routes)][name] is not None
        else f"{routes} routes absent"
        for routes in counts
    )
    for protocol, operation in protocols
    for name, _, _ in time_columns
)
a(
    f'<desc id="d">{title}. Each line is one implementation\'s time a call over its time with one route. {description}.</desc>'
)
a("""<style>
svg { --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#8a8984; --grid:#e4e3df; --zig:#2a78d6; --rust:#eb6834; --go:#6f6e69; }
@media (prefers-color-scheme: dark) {
  svg { --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#8f8e86; --grid:#33332f; --zig:#3987e5; --rust:#d95926; --go:#a8a79f; }
}
text { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; fill: var(--ink); }
.title { font-size: 16px; font-weight: 600; }
.sub { font-size: 12.5px; fill: var(--ink2); }
.panel { font-size: 14px; font-weight: 600; }
.val { font-size: 11px; font-weight: 600; paint-order: stroke; stroke: var(--surface); stroke-width: 3px; stroke-linejoin: round; }
.tick { font-size: 11px; fill: var(--muted); }
.legend { font-size: 12.5px; fill: var(--ink2); }
</style>""")
a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
a(f'<text class="title" x="{pad_l}" y="34">{title}</text>')
a(
    f'<text class="sub" x="{pad_l}" y="56">The small message\'s routed call in memory, its route among more methods and services. Each line is one</text>'
)
a(
    f'<text class="sub" x="{pad_l}" y="74">implementation\'s time a call over its own time with one route: a flat line costs the same at any size.</text>'
)
where = f", {machine}" if machine else ""
a(f'<text class="sub" x="{pad_l}" y="92">One CI job ran all three: run {run}, commit {commit}{where}.</text>')
legend_x = pad_l
for name, _, fill in time_columns:
    a(
        f'<line x1="{legend_x}" y1="{legend_y - 4}" x2="{legend_x + 16}" y2="{legend_y - 4}" stroke="var({fill})" stroke-width="2.5"/>'
    )
    a(f'<text class="legend" x="{legend_x + 22}" y="{legend_y}">{name}</text>')
    legend_x += 22 + 7 * len(name) + 24
for k, (protocol, operation) in enumerate(protocols):
    px = pad_l + k * (panel_w + gap_x)
    a(f'<text class="panel" x="{px}" y="{pad_t + 14}">{protocol}</text>')
    top = pad_t + 28
    left, right = px + plot_l, px + panel_w - plot_r
    xs = {routes: left + i * (right - left) / (len(counts) - 1) for i, routes in enumerate(counts)}
    for i in range(round((y_high - y_low) / step) + 1):
        v = y_low + i * step
        y = sy(v, top)
        a(f'<line x1="{left}" y1="{y:.1f}" x2="{right}" y2="{y:.1f}" stroke="var(--grid)" stroke-width="1"/>')
        a(f'<text class="tick" x="{left - 6}" y="{y + 4:.1f}" text-anchor="end">{v:.2f}×</text>')
    for routes, x in xs.items():
        a(
            f'<text class="tick" x="{x:.1f}" y="{top + plot_h + 18}" text-anchor="middle">{routes} route{"s" if routes > 1 else ""}</text>'
        )
    labels = []
    for name, _, fill in time_columns:
        points = [(xs[r], sy(ratio(operation, r, name), top)) for r in counts if ratio(operation, r, name) is not None]
        if not points:
            continue
        a(
            f'<polyline points="{" ".join(f"{x:.1f},{y:.1f}" for x, y in points)}" fill="none" stroke="var({fill})" stroke-width="2.5"/>'
        )
        for x, y in points:
            a(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="var({fill})" stroke="var(--surface)" stroke-width="2"/>')
        last = ratio(operation, counts[-1], name)
        if last is not None and points[-1][0] == xs[counts[-1]]:
            labels.append([points[-1][1] + 4, points[-1][0] + 9, f"{name} {percent(last)}"])
    # The end labels keep a line's height apart, so two lines that end close stay readable.
    labels.sort()
    label_gap = 13
    for i in range(1, len(labels)):
        labels[i][0] = max(labels[i][0], labels[i - 1][0] + label_gap)
    for y, x, text in labels:
        a(f'<text class="val" x="{x:.1f}" y="{y:.1f}">{text}</text>')
a("</svg>")
pathlib.Path(out).write_text("\n".join(parts) + "\n")
