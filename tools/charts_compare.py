#!/usr/bin/env python3
"""Writes what changed since the previous tag, as Markdown, from two folders of the charts' files
of values (tools/chart_change.py, decision 44 as amended on 2026-11-25).

    tools/charts_compare.py <previous> <current>

<previous> holds the previous tag's `<chart>.json` files, and may be empty or absent. <current>
holds this tag's. The text gives a line of counts, a table of each connect-zig value that moved
by `chart_change.threshold` or more, and every value in a section a reader opens. A chart whose
machine differs from the previous one's compares nothing, and the text says so. The charts job
adds the text to the release's notes and to the run's summary.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import chart_change

# The heading of the text, which tools/charts_release.sh finds again in a release's notes.
heading = "## Benchmarks since the previous tag"


def charts_in(folder):
    """Each file of values in a folder, by its chart's name."""
    folder = pathlib.Path(folder)
    if not folder.is_dir():
        return {}
    loaded = {path.stem: chart_change.load(path) for path in sorted(folder.glob("*.json"))}
    return {name: values for name, values in loaded.items() if values is not None}


def number(value):
    """A value as the charts print it: a rate with thousands, a multiple with two decimals."""
    return f"{value:,.0f}" if value >= 1000 else f"{value:.2f}"


def verdict(share):
    """A change's cell: ▲ better or ▼ worse past the threshold, and ≈ within it."""
    if share is None:
        return "new"
    if not chart_change.moved(share):
        return f"≈ {share * 100:+.1f}%"
    arrow, word = ("▲", "better") if share > 0 else ("▼", "worse")
    return f"{arrow} {abs(share) * 100:.0f}% {word}"


def rows_of(name, current, previous):
    """A row for each value of a chart: the chart, the value's label, the previous value, the
    current one, the change, and the change as a share. None when the machines differ."""
    change = chart_change.Change(previous, current.get("machine"))
    if change.other_machine:
        return None
    rows = []
    for key, record in current["values"].items():
        change.record(key, record["label"], record["value"], record["higher_is_better"])
        was, share = change.was(key), change.share(key)
        was_text = "–" if was is None else number(was)
        rows.append((name, record["label"], was_text, number(record["value"]), verdict(share), share))
    return rows


def table(rows):
    lines = ["| Chart | Value | Previous | This tag | Change |", "| --- | --- | ---: | ---: | --- |"]
    lines += [f"| {name} | {label} | {was} | {now} | {cell} |" for name, label, was, now, cell, _ in rows]
    return lines


def compare(previous_folder, current_folder):
    """The Markdown text of what changed since the previous tag."""
    previous, current = charts_in(previous_folder), charts_in(current_folder)
    tag = next((values.get("tag") for values in previous.values() if values.get("tag")), None)
    lines = [heading, ""]
    if not previous:
        return "\n".join([*lines, "The previous tag has no file of values, so nothing compares.", ""])
    rows, other = [], []
    for name, values in current.items():
        found = rows_of(name, values, previous.get(name))
        if found is None:
            other.append(name)
        else:
            rows += found
    moved = [row for row in rows if chart_change.moved(row[5])]
    better = sum(1 for row in moved if row[5] > 0)
    lines.append(
        f"connect-zig's values against {tag or 'the previous tag'}: {better} better and {len(moved) - better} "
        f"worse by {chart_change.threshold * 100:.0f}% or more, of {len(rows)}. Each compares the value its chart draws."
    )
    lines.append("")
    if moved:
        lines += [*table(moved), ""]
    if other:
        lines += [
            f"These charts ran on another CPU model than {tag or 'the previous tag'}'s, so they compare nothing: {', '.join(other)}.",
            "",
        ]
    lines += ["<details>", "<summary>Every value</summary>", "", *table(rows), "", "</details>", ""]
    return "\n".join(lines)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: tools/charts_compare.py <previous> <current>")
    sys.stdout.write(compare(sys.argv[1], sys.argv[2]))


if __name__ == "__main__":
    main()
