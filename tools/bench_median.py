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

# The cells of a row: message, operation, bytes, ns/op, and MB/s.
cells_count = 5
ns_column = 3


def read(paths):
    """Each row's cells from every round that holds it, by message and operation, and the keys in
    the order the first round to hold each gives them."""
    rows, order = {}, []
    for path in paths:
        with open(path) as table:
            for line in table:
                cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
                if (
                    not line.startswith("| ")
                    or len(cells) != cells_count
                    or cells[0] == "message"
                    or set(cells[0]) <= set("-: ")
                ):
                    continue
                key = (cells[0], cells[1])
                if key not in rows:
                    order.append(key)
                rows.setdefault(key, []).append(cells)
    return rows, order


def median_row(rounds):
    """The cells of the round whose ns/op is the median, the lower of the two middle ones for an
    even count."""
    middle = statistics.median_low(float(cells[ns_column]) for cells in rounds)
    return next(cells for cells in rounds if float(cells[ns_column]) == middle)


def main():
    rows, order = read(sys.argv[1:])
    for key in order:
        print("| " + " | ".join(median_row(rows[key])) + " |")


if __name__ == "__main__":
    main()
