#!/usr/bin/env python3
"""Draws a compression chart of docs/images/ from the report of CI's fullstack-compression job
(tools/fullstack/compression.sh, design §8 step 37).

    tools/compression_chart.py <log> <run> <commit> <transport> [out.svg]

<log> holds the job's whole output, or the report of tools/fullstack/compression_report.py.
<transport> picks the report: `tls` or `cleartext`. Each row is one Connect receiver with exports
in one coding, as a share of the same receiver uncompressed, so each library's bars read on its
own scale of 100%. The left panel gives the spans a second its core held in the climb, and a
whisker to the next step, which failed: the rate the core holds lies between the two. The right
panel gives the median calls a second at the peak, with exports of 512 spans, and a whisker over
the range of the rounds. <run> and <commit> name the run in the subtitle, as docs/performance.md
asks of a published number.
"""
import re
import sys

log_path, run, commit, transport = sys.argv[1:5]
suffix = "" if transport == "tls" else "-cleartext"
out = sys.argv[5] if len(sys.argv) > 5 else f"docs/images/fullstack-compression{suffix}.svg"
over = "over TLS" if transport == "tls" else "over cleartext h2"
# The work a smaller export saves on the wire.
saved = "the TLS and HTTP/2" if transport == "tls" else "the HTTP/2"
# Each receiver's color, as in every chart of the README. A row's label names its coding.
colors = {"connect-zig": "--zig", "connect-go": "--go", "connect-rust": "--rust"}
codings = ["uncompressed", "gzip", "zstd", "brotli"]
peak_spans = "512 spans"
percent = 100


def number(text):
    return float(text.replace(",", "").replace("+", "").rstrip("%"))


def read(path):
    """Each row of the climb's table and of the peak's, keyed by server and coding, and the
    machine. Each table's columns are found by their headers."""
    # The time GitHub writes before each line of a job's log, which a log saved from a run holds.
    stamp = re.compile(r"^\d{4}-\d\d-\d\dT[0-9:.]+Z ")
    held, peak, machine, section, columns, table = {}, {}, None, False, {}, None
    for line in open(path):
        line = stamp.sub("", line.strip())
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
        if "spans/s held" in cells or "calls/s range" in cells:
            columns = {name: index for index, name in enumerate(cells)}
            table = "climb" if "spans/s held" in cells else "peak"
            continue
        row = {name: cells[index] for name, index in columns.items() if index < len(cells)}
        if table == "climb" and row.get("server") in colors and row["spans/s held"] != "no step":
            gap = number(row["resolution"]) / percent if row.get("resolution") else None
            # A climb that ended on a refused call ran out of the receiver's slots for calls in
            # flight, not of its core: connect-zig's sink holds 64.
            refused = row.get("the next step") == "a call refused"
            held[(row["server"], row["coding"])] = {"spans": number(row["spans/s held"]), "gap": gap, "refused": refused}
        elif table == "peak" and row.get("export") == peak_spans and row.get("server") in colors and row["calls/s"] != "absent":
            low, high = row["calls/s range"].split("–")
            peak[(row["server"], row["coding"])] = {"rate": number(row["calls/s"]), "low": number(low), "high": number(high)}
    return held, peak, machine


held, peak, machine = read(log_path)
rows = [(server, coding) for server in colors for coding in codings if (server, coding) in held]
if ("connect-zig", "uncompressed") not in held:
    sys.exit(f"{log_path}: no compression report {over} with connect-zig uncompressed")


def climb_share(server, coding):
    """The rate held as a share of uncompressed, and the share of the next step, which failed."""
    plain = held.get((server, "uncompressed"))
    if plain is None:
        return None
    item = held[(server, coding)]
    share = item["spans"] / plain["spans"] * percent
    return share, share * (1 + item["gap"]) if item["gap"] is not None else share


def peak_share(server, coding):
    """The median calls a second as a share of uncompressed, and the range of the rounds."""
    plain = peak.get((server, "uncompressed"))
    item = peak.get((server, coding))
    if plain is None or item is None:
        return None
    return tuple(item[key] / plain["rate"] * percent for key in ("rate", "low", "high"))


coded = [coding for coding in codings[1:] if ("connect-zig", coding) in held]
kept = [f"{climb_share('connect-zig', coding)[0]:.0f}%" for coding in coded]
if coded:
    names = coded[0] if len(coded) == 1 else f"{', '.join(coded[:-1])} and {coded[-1]}"
    shares = kept[0] if len(kept) == 1 else f"{', '.join(kept[:-1])} and {kept[-1]}"
    title = f"In {names}, connect-zig holds {shares} of its uncompressed rate"
else:
    title = f"connect-zig's spans a second {over}, uncompressed"

W = 840
pad_l = 24
subtitle = [
    f"Each receiver runs on one core {over}, on its library's own decoders. stdx's encoders wrote each export as a",
    "connect-zig client does: gzip at stdx's default level, zstd and brotli at level 1. Each bar is a share of the",
    f"same receiver uncompressed, net of {saved} a smaller export saves. A whisker reaches the step that",
    "failed in the climb, and spans the rounds at peak; ≥ marks a climb whose every step passed, and \"slots full\"",
    "one that ended on a call refused because every slot for a call in flight was taken.",
]
line_h = 18
top = 56 + (len(subtitle) + 1) * line_h + 40
row_h, row_gap, group_gap, heading_h = 18, 8, 14, 22
label_right = pad_l + 110
climb_left, climb_w = label_right + 12, 170
peak_left, peak_w = climb_left + climb_w + 200, 160
groups = len({server for server, _ in rows})
H = top + 12 + len(rows) * (row_h + row_gap) + (groups - 1) * group_gap + groups * heading_h + 20
climb_high = max([110.0] + [climb_share(*row)[1] for row in rows if climb_share(*row)])
peak_high = max([110.0] + [share[2] for share in (peak_share(*row) for row in rows) if share])

parts = []
a = parts.append
a(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">')
a(f'<title id="t">What gzip, zstd and brotli leave of each Connect receiver\'s rate {over}, as a share of the same receiver '
  'uncompressed</title>')
described = "; ".join(
    f"{server} {coding}: {held[(server, coding)]['spans']:,.0f} spans a second held"
    + (f", {climb_share(server, coding)[0]:.0f}% of uncompressed" if coding != "uncompressed" and climb_share(server, coding) else "")
    + (f", {peak[(server, coding)]['rate']:,.0f} calls a second at peak" if (server, coding) in peak else "")
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
.panel { font-size: 13px; font-weight: 600; }
.server { font-size: 12.5px; font-weight: 600; }
.row { font-size: 12.5px; fill: var(--ink2); }
.val { font-size: 11px; font-weight: 600; fill: var(--ink2); }
.tick { font-size: 11px; fill: var(--muted); }
</style>''')
a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
a(f'<text class="title" x="{pad_l}" y="34">{title}</text>')
for index, text in enumerate(subtitle):
    a(f'<text class="sub" x="{pad_l}" y="{56 + index * line_h}">{text}</text>')
where = f", {machine}" if machine else ""
a(f'<text class="sub" x="{pad_l}" y="{56 + len(subtitle) * line_h}">One CI job ran all, and checked every span: '
  f'run {run}, commit {commit}{where}.</text>')
a(f'<text class="panel" x="{climb_left}" y="{top - 22}">Spans a second held in the climb</text>')
a(f'<text class="panel" x="{peak_left}" y="{top - 22}">Calls a second at peak, {peak_spans}</text>')


def axis(left, width, high, bottom):
    """The panel's line at 100%, the share of each receiver uncompressed."""
    x = left + 100 / high * width
    a(f'<line x1="{x:.1f}" y1="{top - 6}" x2="{x:.1f}" y2="{bottom}" stroke="var(--muted)" stroke-width="1" stroke-dasharray="4 3"/>')
    a(f'<text class="tick" x="{x:.1f}" y="{top - 8}" text-anchor="middle">100%</text>')


def bar(left, width, high, y, fill, share, low, upper, label):
    """A bar to `share`, a whisker from `low` to `upper`, and the label past the whisker."""
    scale = width / high
    a(f'<rect x="{left}" y="{y}" width="{max(share * scale, 1):.1f}" height="{row_h}" rx="3" fill="var({fill})"/>')
    middle = y + row_h / 2
    if upper > low:
        a(f'<line x1="{left + low * scale:.1f}" y1="{middle}" x2="{left + upper * scale:.1f}" y2="{middle}" '
          f'stroke="var(--ink)" stroke-width="1.5"/>')
        a(f'<line x1="{left + upper * scale:.1f}" y1="{middle - 4}" x2="{left + upper * scale:.1f}" y2="{middle + 4}" '
          f'stroke="var(--ink)" stroke-width="1.5"/>')
    a(f'<text class="val" x="{left + max(share, upper) * scale + 8:.1f}" y="{middle + 4:.1f}">{label}</text>')


bottom = H - 16
axis(climb_left, climb_w, climb_high, bottom)
if peak:
    axis(peak_left, peak_w, peak_high, bottom)
y = top + 12
previous = None
for server, coding in rows:
    if previous is not None and server != previous:
        y += group_gap
    fill = colors[server]
    if server != previous:
        a(f'<text class="server" x="{pad_l}" y="{y + row_h / 2 + 4:.1f}">{server}</text>')
        y += heading_h
    a(f'<text class="row" x="{label_right}" y="{y + row_h / 2 + 4:.1f}" text-anchor="end">{coding}</text>')
    share = climb_share(server, coding)
    if share:
        # A climb whose every step passed gives no resolution: its rate is a floor.
        floor = "≥" if held[(server, coding)]["gap"] is None else ""
        spans = f"{floor}{held[(server, coding)]['spans']:,.0f}/s"
        label = spans if coding == "uncompressed" else f"{share[0]:.0f}% · {spans}"
        if held[(server, coding)]["refused"]:
            label += " · slots full"
        bar(climb_left, climb_w, climb_high, y, fill, share[0], share[0], share[1], label)
    rates = peak_share(server, coding)
    if rates:
        calls = f"{peak[(server, coding)]['rate']:,.0f}/s"
        label = calls if coding == "uncompressed" else f"{rates[0]:.0f}% · {calls}"
        bar(peak_left, peak_w, peak_high, y, fill, rates[0], rates[1], rates[2], label)
    y += row_h + row_gap
    previous = server
a('</svg>')
with open(out, "w") as file:
    file.write("\n".join(parts) + "\n")
print(f"{out}: {len(rows)} rows {over}, run {run}", file=sys.stderr)
