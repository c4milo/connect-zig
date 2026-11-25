#!/usr/bin/env python3
"""Draws a compression chart from the report of CI's fullstack-compression job
(tools/fullstack/compression.sh, design §8 step 37).

    tools/compression_chart.py <log> <run> <commit> <transport> [out.svg]

<log> holds the job's whole output, or the report of tools/fullstack/compression_report.py.
<transport> picks the report: `tls` or `cleartext`. Each row is one Connect receiver with exports
in one coding, as a share of the same receiver uncompressed, so each library's bars read on its
own scale of 100%. The left panel gives the spans a second its core held in the climb: the median
of the rounds' shares, each round's coding over uncompressed in the same round, with a whisker
over their range. A report of one climb gives a whisker to the next step, which failed. The
right panel gives the median calls a second at the peak, with exports of 512 spans, and a
whisker over the range of the rounds. <run> and <commit> name the run in the subtitle, as docs/performance.md
asks of a published number.
"""

import re
import sys
import types

# Each receiver's color, as in every chart of the README. A row's label names its coding.
colors = {"connect-zig": "--zig", "connect-go": "--go", "connect-rust": "--rust"}
codings = ["uncompressed", "gzip", "zstd", "brotli"]
peak_spans = "512 spans"
percent = 100


def number(text):
    return float(text.replace(",", "").replace("+", "").rstrip("%"))


def split_range(text):
    """The two ends of a range such as "1,000–2,000"."""
    low, high = text.split("–")
    return number(low), number(high)


def held_of(row):
    """A row of the climb's table: the spans a second held, and what the report gives besides."""
    gap = number(row["resolution"]) / percent if row.get("resolution") else None
    # A climb that ended on a refused call ran out of the receiver's slots for calls in flight, not
    # of its core: connect-zig's sink holds 64.
    refused = row.get("the next step") == "a call refused"
    item = {"spans": number(row["spans/s held"]), "gap": gap, "refused": refused}
    # A report of rounds gives each coding's median share of uncompressed and its range, and each
    # row's range of spans a second; one of a single climb gives neither.
    if row.get("share"):
        item["share"] = number(row["share"])
        if row.get("share range"):
            item["share_low"], item["share_high"] = split_range(row["share range"])
    if row.get("range"):
        item["low"], item["high"] = split_range(row["range"])
    return item


class Reader:
    """The compression report over a transport, read a line at a time from a log. Each table's
    columns are found by their headers."""

    # The time GitHub writes before each line of a job's log, which a log saved from a run holds.
    stamp = re.compile(r"^\d{4}-\d\d-\d\dT[0-9:.]+Z ")

    def __init__(self, over):
        self.over = over
        self.held, self.peak, self.machine = {}, {}, None
        self.section, self.columns, self.table = False, {}, None

    def line(self, line):
        line = self.stamp.sub("", line.strip())
        if line.startswith("## "):
            self.section = line.startswith(f"## Full stack, compression {self.over}")
            return
        if not self.section:
            return
        if line.startswith("Machine: ") and self.machine is None:
            self.machine = ", ".join(part.strip() for part in line[len("Machine: ") :].rstrip(".").split(",")[:2])
        if not line.startswith("|") or "---" in line:
            return
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if "spans/s held" in cells or "calls/s range" in cells:
            self.columns = {name: index for index, name in enumerate(cells)}
            self.table = "climb" if "spans/s held" in cells else "peak"
            return
        self.row({name: cells[index] for name, index in self.columns.items() if index < len(cells)})

    def row(self, row):
        if self.table == "climb" and row.get("server") in colors and row["spans/s held"] != "no step":
            self.held[(row["server"], row["coding"])] = held_of(row)
        elif (
            self.table == "peak"
            and row.get("export") == peak_spans
            and row.get("server") in colors
            and row["calls/s"] != "absent"
        ):
            low, high = split_range(row["calls/s range"])
            self.peak[(row["server"], row["coding"])] = {"rate": number(row["calls/s"]), "low": low, "high": high}


def read(path, over):
    """Each row of the climb's table and of the peak's, keyed by server and coding, and the
    machine."""
    reader = Reader(over)
    with open(path) as log:
        for line in log:
            reader.line(line)
    return reader.held, reader.peak, reader.machine


def rows_of(held):
    """The chart's rows: each receiver with each coding its report holds."""
    return [(server, coding) for server in colors for coding in codings if (server, coding) in held]


def climb_share(held, server, coding):
    """The rate held as a share of uncompressed, and the whisker's two ends: the range of the
    rounds' shares, or for uncompressed its rounds' range over its median. A report of one climb
    gives the share of the next step, which failed, as the whisker's upper end."""
    plain = held.get((server, "uncompressed"))
    if plain is None:
        return None
    item = held[(server, coding)]
    if "share" in item:
        if coding == "uncompressed":
            return (
                percent,
                item.get("low", item["spans"]) / item["spans"] * percent,
                item.get("high", item["spans"]) / item["spans"] * percent,
            )
        return item["share"], item.get("share_low", item["share"]), item.get("share_high", item["share"])
    share = item["spans"] / plain["spans"] * percent
    return share, share, share * (1 + item["gap"]) if item["gap"] is not None else share


def peak_share(peak, server, coding):
    """The median calls a second as a share of uncompressed, and the range of the rounds."""
    plain = peak.get((server, "uncompressed"))
    item = peak.get((server, coding))
    if plain is None or item is None:
        return None
    return tuple(item[key] / plain["rate"] * percent for key in ("rate", "low", "high"))


def caps(share, low, upper):
    """The ends of a whisker from `low` to `upper` that take a cap: each that is not the end of the
    bar, at `share`."""
    return sorted({low, upper} - {share})


# The chart's style sheet: its colors in light and dark, and its fonts.
style = """<style>
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
</style>"""


def joined(words):
    """Words joined as a list in prose: "a", "a and b", or "a, b and c"."""
    return words[0] if len(words) == 1 else f"{', '.join(words[:-1])} and {words[-1]}"


def title_of(held, over):
    """The chart's title: the share of its uncompressed rate connect-zig holds in each coding."""
    coded = [coding for coding in codings[1:] if ("connect-zig", coding) in held]
    if not coded:
        return f"connect-zig's spans a second {over}, uncompressed"
    kept = [f"{climb_share(held, 'connect-zig', coding)[0]:.0f}%" for coding in coded]
    return f"In {joined(coded)}, connect-zig holds {joined(kept)} of its uncompressed rate"


def subtitle_of(held, transport, over):
    """The subtitle's lines, with a line for each mark a label carries."""
    # The work a smaller export saves: the kernel's, which moves fewer octets through the socket,
    # most of all, then the decryption over TLS and HTTP/2's framing (docs/benchmarks.md).
    saved = "the kernel, TLS, and HTTP/2 work" if transport == "tls" else "the kernel and HTTP/2 work"
    rounds = any("share" in item for item in held.values())
    subtitle = [
        f"Each receiver runs on one core {over}, on its library's own decoders. stdx's encoders wrote each export as a",
        "connect-zig client does: gzip at stdx's default level, zstd and brotli at level 1. Each bar is a share of the",
        f"same receiver uncompressed, net of {saved} a smaller export saves. "
        + ("A whisker spans the rounds: in the climb," if rounds else "A whisker reaches the step that"),
        (
            "each round's share of uncompressed in the same round."
            if rounds
            else "failed in the climb, and spans the rounds at peak."
        ),
    ]
    # Each mark a label can carry, explained on a line of its own only when a label carries it.
    if any(item["gap"] is None for item in held.values()):
        subtitle.append("≥ marks a climb whose every step passed.")
    if any(item["refused"] for item in held.values()):
        subtitle.append(
            '"slots full" marks a climb that ended on a call refused, every slot for a call in flight taken.'
        )
    return subtitle


def layout_of(held, peak, rows, subtitle):
    """Where each part of the chart goes, and each panel's greatest share."""
    lay = types.SimpleNamespace(W=840, pad_l=24, line_h=18, row_h=18, row_gap=8, group_gap=14, heading_h=22)
    lay.top = 56 + (len(subtitle) + 1) * lay.line_h + 40
    lay.label_right = lay.pad_l + 110
    lay.climb_left, lay.climb_w = lay.label_right + 12, 170
    lay.peak_left, lay.peak_w = lay.climb_left + lay.climb_w + 200, 160
    groups = len({server for server, _ in rows})
    lay.H = (
        lay.top
        + 12
        + len(rows) * (lay.row_h + lay.row_gap)
        + (groups - 1) * lay.group_gap
        + groups * lay.heading_h
        + 20
    )
    lay.climb_high = max([110.0] + [climb_share(held, *row)[2] for row in rows if climb_share(held, *row)])
    lay.peak_high = max([110.0] + [share[2] for share in (peak_share(peak, *row) for row in rows) if share])
    return lay


def description(title, held, peak, rows):
    """The chart's description: each row's rate held, its share, and its calls a second at peak."""
    described = "; ".join(
        f"{server} {coding}: {held[(server, coding)]['spans']:,.0f} spans a second held"
        + (
            f", {climb_share(held, server, coding)[0]:.0f}% of uncompressed"
            if coding != "uncompressed" and climb_share(held, server, coding)
            else ""
        )
        + (f", {peak[(server, coding)]['rate']:,.0f} calls a second at peak" if (server, coding) in peak else "")
        for server, coding in rows
    )
    return f"{title}. {described}."


def draw_head(a, lay, chart):
    """The chart's frame: its size, its title and description, its style, its subtitle, and the
    names of its panels."""
    W, H, pad_l = lay.W, lay.H, lay.pad_l
    a(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">'
    )
    a(
        f'<title id="t">What gzip, zstd and brotli leave of each Connect receiver\'s rate {chart.over}, as a share of the same receiver '
        "uncompressed</title>"
    )
    a(f'<desc id="d">{description(chart.title, chart.held, chart.peak, chart.rows)}</desc>')
    a(style)
    a(f'<rect width="{W}" height="{H}" rx="8" fill="var(--surface)"/>')
    a(f'<text class="title" x="{pad_l}" y="34">{chart.title}</text>')
    for index, text in enumerate(chart.subtitle):
        a(f'<text class="sub" x="{pad_l}" y="{56 + index * lay.line_h}">{text}</text>')
    where = f", {chart.machine}" if chart.machine else ""
    a(
        f'<text class="sub" x="{pad_l}" y="{56 + len(chart.subtitle) * lay.line_h}">One CI job ran all, and checked every span: '
        f"run {chart.run}, commit {chart.commit}{where}.</text>"
    )
    a(f'<text class="panel" x="{lay.climb_left}" y="{lay.top - 22}">Spans a second held in the climb</text>')
    a(f'<text class="panel" x="{lay.peak_left}" y="{lay.top - 22}">Calls a second at peak, {peak_spans}</text>')


def draw_axis(a, lay, left, width, high, bottom):
    """The panel's line at 100%, the share of each receiver uncompressed."""
    x = left + 100 / high * width
    a(
        f'<line x1="{x:.1f}" y1="{lay.top - 6}" x2="{x:.1f}" y2="{bottom}" stroke="var(--muted)" stroke-width="1" stroke-dasharray="4 3"/>'
    )
    a(f'<text class="tick" x="{x:.1f}" y="{lay.top - 8}" text-anchor="middle">100%</text>')


def draw_bar(a, lay, panel, y, fill, shares, label):
    """A bar to the share, a whisker from its low end to its upper end, and the label past the
    whisker. `panel` is the panel's left edge, its width, and its greatest share."""
    left, width, high = panel
    share, low, upper = shares
    scale = width / high
    a(f'<rect x="{left}" y="{y}" width="{max(share * scale, 1):.1f}" height="{lay.row_h}" rx="3" fill="var({fill})"/>')
    middle = y + lay.row_h / 2
    if upper > low:
        a(
            f'<line x1="{left + low * scale:.1f}" y1="{middle}" x2="{left + upper * scale:.1f}" y2="{middle}" '
            f'stroke="var(--ink)" stroke-width="1.5"/>'
        )
        # A cap at each end of the whisker that is not the bar's own end.
        for end in caps(share, low, upper):
            a(
                f'<line x1="{left + end * scale:.1f}" y1="{middle - 4}" x2="{left + end * scale:.1f}" y2="{middle + 4}" '
                f'stroke="var(--ink)" stroke-width="1.5"/>'
            )
    a(f'<text class="val" x="{left + max(share, upper) * scale + 8:.1f}" y="{middle + 4:.1f}">{label}</text>')


def climb_label(item, share, coding):
    """The label of a climb's bar: the spans a second held, a floor marked, after the share."""
    # A climb whose every step passed gives no resolution: its rate is a floor.
    floor = "≥" if item["gap"] is None else ""
    spans = f"{floor}{item['spans']:,.0f}/s"
    label = spans if coding == "uncompressed" else f"{share[0]:.0f}% · {spans}"
    return label + " · slots full" if item["refused"] else label


def draw_row(a, lay, chart, row, y):
    """A row's bars: its climb's and its peak's."""
    server, coding = row
    fill = colors[server]
    a(f'<text class="row" x="{lay.label_right}" y="{y + lay.row_h / 2 + 4:.1f}" text-anchor="end">{coding}</text>')
    share = climb_share(chart.held, server, coding)
    if share:
        label = climb_label(chart.held[row], share, coding)
        draw_bar(a, lay, (lay.climb_left, lay.climb_w, lay.climb_high), y, fill, share, label)
    rates = peak_share(chart.peak, server, coding)
    if rates:
        calls = f"{chart.peak[row]['rate']:,.0f}/s"
        label = calls if coding == "uncompressed" else f"{rates[0]:.0f}% · {calls}"
        draw_bar(a, lay, (lay.peak_left, lay.peak_w, lay.peak_high), y, fill, rates, label)


def draw_rows(a, lay, chart):
    """Each receiver's heading, and a row for each of its codings."""
    y = lay.top + 12
    previous = None
    for server, coding in chart.rows:
        if previous is not None and server != previous:
            y += lay.group_gap
        if server != previous:
            a(f'<text class="server" x="{lay.pad_l}" y="{y + lay.row_h / 2 + 4:.1f}">{server}</text>')
            y += lay.heading_h
        draw_row(a, lay, chart, (server, coding), y)
        y += lay.row_h + lay.row_gap
        previous = server


def draw(transport, held, peak, machine, run, commit):
    """The chart's SVG text."""
    chart = types.SimpleNamespace(held=held, peak=peak, machine=machine, run=run, commit=commit)
    chart.over = "over TLS" if transport == "tls" else "over cleartext h2"
    chart.rows = rows_of(held)
    chart.title = title_of(held, chart.over)
    chart.subtitle = subtitle_of(held, transport, chart.over)
    lay = layout_of(held, peak, chart.rows, chart.subtitle)
    parts = []
    a = parts.append
    draw_head(a, lay, chart)
    bottom = lay.H - 16
    draw_axis(a, lay, lay.climb_left, lay.climb_w, lay.climb_high, bottom)
    if peak:
        draw_axis(a, lay, lay.peak_left, lay.peak_w, lay.peak_high, bottom)
    draw_rows(a, lay, chart)
    a("</svg>")
    return "\n".join(parts) + "\n"


def main():
    log_path, run, commit, transport = sys.argv[1:5]
    suffix = "" if transport == "tls" else "-cleartext"
    out = sys.argv[5] if len(sys.argv) > 5 else f"fullstack-compression{suffix}.svg"
    over = "over TLS" if transport == "tls" else "over cleartext h2"
    held, peak, machine = read(log_path, over)
    if ("connect-zig", "uncompressed") not in held:
        sys.exit(f"{log_path}: no compression report {over} with connect-zig uncompressed")
    text = draw(transport, held, peak, machine, run, commit)
    with open(out, "w") as file:
        file.write(text)
    print(f"{out}: {len(rows_of(held))} rows {over}, run {run}", file=sys.stderr)


if __name__ == "__main__":
    main()
