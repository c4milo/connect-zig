#!/usr/bin/env python3
"""Writes one benchmark table from the tables of several rounds (tools/bench_check.sh).

    tools/bench_median.py <round.md>...

Each table row is "| message | operation | bytes | ns/op | MB/s |". For each message and
operation, the script prints the row of the round whose ns/op is the median: the lower of the two
middle ones for an even count, so each row printed is one a round measured. The rows keep the
first table's order. A row that a round lacks takes the median of the rounds that hold it.
"""
import statistics
import sys

rows, order = {}, []
for path in sys.argv[1:]:
    for line in open(path):
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not line.startswith("| ") or len(cells) != 5 or cells[0] == "message" or set(cells[0]) <= set("-: "):
            continue
        key = (cells[0], cells[1])
        if key not in rows:
            order.append(key)
        rows.setdefault(key, []).append(cells)
for key in order:
    middle = statistics.median_low(float(cells[3]) for cells in rows[key])
    chosen = next(cells for cells in rows[key] if float(cells[3]) == middle)
    print("| " + " | ".join(chosen) + " |")
