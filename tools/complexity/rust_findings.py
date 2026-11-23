#!/usr/bin/env python3
"""Prints each Rust function over the limit, from rust-code-analysis's metrics (tools/complexity_check.sh).

    tools/complexity/rust_findings.py <limit> <metrics>

The metrics file holds the JSON that `rust-code-analysis-cli --metrics --output-format json`
writes: one object a line for each file, with a space for each function, closure, and impl block
inside it. A space's cognitive complexity counts the closures it holds, as SonarSource's method
does. The script prints each function and closure whose score passes the limit, and exits 1 when
it prints one.
"""

import json
import sys


def function_scores(space, path):
    """Yields the path, line, name, and score of each function or closure in the space."""
    if space["kind"] == "function":
        yield path, space["start_line"], space["name"], int(space["metrics"]["cognitive"]["sum"])
    for child in space.get("spaces", []):
        yield from function_scores(child, path)


def findings(lines, limit):
    """The finding lines of the functions over the limit."""
    found = []
    for line in lines:
        record = json.loads(line)
        for path, start, name, score in function_scores(record, record["name"]):
            if score > limit:
                found.append(f"{path}:{start}: {name} has cognitive complexity {score}, over {limit}")
    return found


def main(limit, metrics):
    """Prints the findings, and gives 1 when there is one."""
    with open(metrics, encoding="utf-8") as file:
        lines = findings((line for line in file if line.strip()), limit)
    for line in lines:
        print(line)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]), sys.argv[2]))
