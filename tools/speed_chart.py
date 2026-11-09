#!/usr/bin/env python3
"""Draws docs/images/speed-vs-go.svg from the table of CI's go-bench job (tools/bench_check.sh).

    tools/speed_chart.py <table.md> <run> <commit> [out.svg]

<table.md> holds the job's table, whose last column is Go's time over connect-zig's. <run> and
<commit> name the run in the chart's subtitle, as docs/performance.md asks of a published number.
A PNG for places that show no SVG comes from any browser's screenshot of the file.
"""
import sys
table_path, run, commit = sys.argv[1:4]
out = sys.argv[4] if len(sys.argv) > 4 else "docs/images/speed-vs-go.svg"
ops = ["Binary encode", "Binary decode, every field read", "JSON encode", "JSON decode"]
op_keys = ["binary encode", "binary decode+walk", "JSON encode", "JSON decode"]
msgs = ["Small, 40 B", "Medium, 1 KB", "Large, 180 KB", "Deep, 50 levels"]
msg_keys = ["small", "medium", "large", "deep"]
ratios = {}
for line in open(table_path):
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) == 9 and cells[0] in msg_keys and cells[1] in op_keys:
        ratios[(cells[0], cells[1])] = float(cells[8])
data = {m: [ratios[(k, o)] for o in op_keys] for m, k in zip(msgs, msg_keys)}
low = min(min(v) for v in data.values())
high = max(max(v) for v in data.values())
W, H = 840, 500
pad_l, pad_t = 24, 92
panel_w, panel_h = 384, 168
gap_x, gap_y = 24, 36
label_w = 112        # message names
plot_w = panel_w - label_w - 44
x_max = 7.0
bar_h, row_h = 18, 34
def sx(v): return v / x_max * plot_w
parts = []
a = parts.append
a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">')
a('<title id="t">connect-zig against Go\'s protobuf runtime</title>')
a('<desc id="d">How many times faster connect-zig is than google.golang.org/protobuf v1.36.12, '
  'Go\'s time over connect-zig\'s, for four messages and four operations. Every value is above 1: '
  + "; ".join(f"{m}: " + ", ".join(f"{o} {data[m][i]:.1f}x" for i, o in enumerate(ops)) for m in msgs) + '.</desc>')
a('''<style>
svg { --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#8a8984; --grid:#e4e3df; --bar:#2a78d6; --parity:#52514e; }
@media (prefers-color-scheme: dark) {
  svg { --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#8f8e86; --grid:#33332f; --bar:#3987e5; --parity:#c3c2b7; }
}
text { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; fill: var(--ink); }
.title { font-size: 20px; font-weight: 600; }
.sub { font-size: 13px; fill: var(--ink2); }
.panel { font-size: 14px; font-weight: 600; }
.row { font-size: 12.5px; fill: var(--ink2); }
.val { font-size: 12.5px; font-weight: 600; }
.tick { font-size: 11px; fill: var(--muted); }
.note { font-size: 11.5px; fill: var(--ink2); }
</style>''')
a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
a(f'<text class="title" x="{pad_l}" y="36">connect-zig is {low:.1f} to {high:.1f} times faster than Go\'s protobuf runtime</text>')
a(f'<text class="sub" x="{pad_l}" y="58">Go\'s time over connect-zig\'s (higher is faster), against google.golang.org/protobuf v1.36.12, the runtime connect-go uses.</text>')
a(f'<text class="sub" x="{pad_l}" y="76">Both ran in one CI job and wrote the same octets: run {run}, commit {commit}.</text>')
for k, op in enumerate(ops):
    px = pad_l + (k % 2) * (panel_w + gap_x)
    py = pad_t + (k // 2) * (panel_h + gap_y)
    ox = px + label_w
    a(f'<text class="panel" x="{px}" y="{py + 14}">{op}</text>')
    top = py + 30
    bottom = top + row_h * len(msgs) - (row_h - bar_h)
    for t in range(0, int(x_max) + 1):
        x = ox + sx(t)
        a(f'<line x1="{x:.1f}" y1="{top - 4}" x2="{x:.1f}" y2="{bottom + 4}" stroke="var(--grid)" stroke-width="1"/>')
        a(f'<text class="tick" x="{x:.1f}" y="{bottom + 18}" text-anchor="middle">{t}×</text>')
    for r, m in enumerate(msgs):
        y = top + r * row_h
        v = data[m][k]
        w = sx(v)
        a(f'<text class="row" x="{ox - 10}" y="{y + bar_h - 5}" text-anchor="end">{m}</text>')
        # 4px rounded data end, square at the baseline
        a(f'<path d="M{ox:.1f},{y} h{w - 4:.1f} a4,4 0 0 1 4,4 v{bar_h - 8} a4,4 0 0 1 -4,4 h{-(w - 4):.1f} z" fill="var(--bar)"/>')
        a(f'<text class="val" x="{ox + w + 6:.1f}" y="{y + bar_h - 5}">{v:.1f}×</text>')
    x1 = ox + sx(1)
    a(f'<line x1="{x1:.1f}" y1="{top - 8}" x2="{x1:.1f}" y2="{bottom + 4}" stroke="var(--parity)" stroke-width="1.5" stroke-dasharray="4 3"/>')
    if k == 0:
        a(f'<text class="note" x="{x1 + 4:.1f}" y="{top - 10}">1× = as fast as Go</text>')
a('</svg>')
open(out, 'w').write("\n".join(parts) + "\n")
