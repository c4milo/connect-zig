#!/usr/bin/env python3
"""Draws a compression chart of docs/images/ from the report of CI's fullstack-compression job
(tools/fullstack/compression.sh, design §8 step 37).

    tools/compression_chart.py <log> <run> <commit> <transport> [out.svg]

<log> holds the job's whole output, or the report of tools/fullstack/compression_report.py.
<transport> picks the report: `tls` or `cleartext`. Each row is one Connect receiver with exports
in one coding. The left panel gives the spans a second its core held in the climb, with p99 at
most 100 ms and no call refused, and its share of the spans the receiver held with no coding. The
right panel gives the CPU time of a call at the peak, with exports of 512 spans. <run> and
<commit> name the run in the subtitle, as docs/performance.md asks of a published number.
"""
import re
import sys

log_path, run, commit, transport = sys.argv[1:5]
suffix = "" if transport == "tls" else "-cleartext"
out = sys.argv[5] if len(sys.argv) > 5 else f"docs/images/fullstack-compression{suffix}.svg"
over = "over TLS" if transport == "tls" else "over cleartext h2"
# Each receiver's color, as in every chart of the README, and each coding's share of it.
colors = {"connect-zig": "--zig", "connect-go": "--go", "connect-rust": "--rust"}
shades = {"none": 1.0, "gzip": 0.78, "zstd": 0.6, "brotli": 0.44}
peak_spans = "512 spans"


def number(text):
    return float(text.replace(",", ""))


held, peak, machine, section, table = {}, {}, None, False, None
for line in open(log_path):
    line = line.strip()
    if line.startswith("## "):
        section = line.startswith(f"## Full stack, compression {over}")
        continue
    if not section:
        continue
    if line.startswith("Machine: ") and machine is None:
        machine = ", ".join(part.strip() for part in line[len("Machine: "):].rstrip(".").split(",")[:2])
    if not line.startswith("|") or "---" in line:
        continue
    cells = [cell.strip() for cell in line.strip("|").split("|")]
    if cells[:2] == ["server", "coding"]:
        table = "climb"
    elif cells[:3] == ["export", "server", "coding"]:
        table = "peak"
    elif table == "climb" and cells[0] in colors and cells[2] != "none":
        held[(cells[0], cells[1])] = {"spans": number(cells[2]), "p99": number(cells[3])}
    elif table == "peak" and cells[0] == peak_spans and cells[1] in colors and cells[3] != "absent":
        peak[(cells[1], cells[2])] = number(cells[5])
rows = [(server, coding) for server in colors for coding in shades if (server, coding) in held]
if not rows or ("connect-zig", "none") not in held:
    sys.exit(f"{log_path}: no compression report {over} with connect-zig")


def share(server, coding):
    plain = held.get((server, "none"))
    return held[(server, coding)]["spans"] / plain["spans"] * 100 if plain else None


coded = [coding for coding in ("gzip", "zstd", "brotli") if ("connect-zig", coding) in held]
kept = [f"{share('connect-zig', coding):.0f}%" for coding in coded]
title = (f"In {', '.join(coded[:-1])} and {coded[-1]}, connect-zig keeps {', '.join(kept[:-1])} and {kept[-1]} "
         f"of its spans a second")

W = 840
pad_l = 24
top = 150
row_h, row_gap, group_gap = 20, 8, 14
label_right = pad_l + 150
bar_left, bar_w = label_right + 12, 250
peak_left, peak_w = bar_left + bar_w + 140, 150
groups = len({server for server, _ in rows})
H = top + 12 + len(rows) * (row_h + row_gap) + (groups - 1) * group_gap + 24

parts = []
a = parts.append
a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">')
a(f'<title id="t">The spans a second one core holds {over} with exports in no coding, gzip, zstd and brotli, '
  'for connect-zig, connect-go and connect-rust</title>')
described = "; ".join(f"{server} in {coding}: {held[(server, coding)]['spans']:,.0f} spans a second"
                      + (f", {peak[(server, coding)]:,.0f} µs of CPU a call of {peak_spans}" if (server, coding) in peak else "")
                      for server, coding in rows)
a(f'<desc id="d">{title}. {described}.</desc>')
a('''<style>
svg { --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#8a8984; --grid:#e4e3df; --zig:#2a78d6; --go:#1a8a82; --rust:#b5562b; }
@media (prefers-color-scheme: dark) {
  svg { --surface:#1a1a19; --ink:#f0efec; --ink2:#c3c2b7; --muted:#8f8e86; --grid:#33332f; --zig:#3987e5; --go:#2fa59c; --rust:#d06d3f; }
}
text { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; fill: var(--ink); }
.title { font-size: 16px; font-weight: 600; }
.sub { font-size: 12.5px; fill: var(--ink2); }
.panel { font-size: 14px; font-weight: 600; }
.server { font-size: 12.5px; font-weight: 600; }
.row { font-size: 12.5px; fill: var(--ink2); }
.val { font-size: 11px; font-weight: 600; fill: var(--ink2); }
</style>''')
a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
a(f'<text class="title" x="{pad_l}" y="34">{title}</text>')
a(f'<text class="sub" x="{pad_l}" y="56">Each receiver runs on one core {over}. stdx\'s encoders wrote each export as a connect-zig client does:</text>')
a(f'<text class="sub" x="{pad_l}" y="74">gzip at stdx\'s default level, zstd and brotli at level 1. The climb sends the production mix to 516 connections</text>')
a(f'<text class="sub" x="{pad_l}" y="92">until p99 passes 100 ms; the peak sends exports of 512 spans as fast as each answers.</text>')
where = f", {machine}" if machine else ""
a(f'<text class="sub" x="{pad_l}" y="110">One CI job ran all, and checked every span: run {run}, commit {commit}{where}.</text>')
a(f'<text class="panel" x="{bar_left}" y="{top - 14}">Spans a second one core holds</text>')
a(f'<text class="panel" x="{peak_left}" y="{top - 14}">CPU µs a call, {peak_spans}</text>')

spans_high = max(item["spans"] for item in held.values())
peak_high = max(peak.values()) if peak else 1
y = top + 12
previous = None
for server, coding in rows:
    if previous is not None and server != previous:
        y += group_gap
    fill = colors[server]
    opacity = shades[coding]
    if server != previous:
        a(f'<text class="server" x="{pad_l}" y="{y + row_h / 2 + 4:.1f}">{server}</text>')
    a(f'<text class="row" x="{label_right}" y="{y + row_h / 2 + 4:.1f}" text-anchor="end">{coding}</text>')
    width = max(held[(server, coding)]["spans"] / spans_high * bar_w, 1)
    a(f'<rect x="{bar_left}" y="{y}" width="{width:.1f}" height="{row_h}" rx="3" fill="var({fill})" fill-opacity="{opacity}"/>')
    kept_share = share(server, coding)
    note = "" if coding == "none" or kept_share is None else f", {kept_share:.0f}%"
    a(f'<text class="val" x="{bar_left + width + 6:.1f}" y="{y + row_h / 2 + 4:.1f}">{held[(server, coding)]["spans"]:,.0f}{note}</text>')
    if (server, coding) in peak:
        width = max(peak[(server, coding)] / peak_high * peak_w, 1)
        a(f'<rect x="{peak_left}" y="{y}" width="{width:.1f}" height="{row_h}" rx="3" fill="var({fill})" fill-opacity="{opacity}"/>')
        a(f'<text class="val" x="{peak_left + width + 6:.1f}" y="{y + row_h / 2 + 4:.1f}">{peak[(server, coding)]:,.0f}</text>')
    y += row_h + row_gap
    previous = server
a('</svg>')
with open(out, "w") as file:
    file.write("\n".join(parts) + "\n")
print(f"{out}: {len(rows)} rows {over}, run {run}", file=sys.stderr)
