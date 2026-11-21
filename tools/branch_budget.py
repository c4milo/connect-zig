#!/usr/bin/env python3
"""Finds the least value of a branch budget with which a build passes.

Usage: python3 tools/branch_budget.py <file> <constant> [-- <command...>]

A test states what a comptime evaluation may cost as a quota of branches, in a constant such as
`read_branches_max` of src/protovalidate/cel/cel_parse.zig (docs/performance.md, "The
compiler's time"). The compiler says when an evaluation passes its quota, and never how many
branches it took. This script rewrites the constant, runs the command, `zig build
test-protovalidate` when none is given, and halves the range until it holds the least value
that builds. It restores the file and prints the range. The commit that pays for a higher cost
sets the constant to that value and 2% more.
"""
import pathlib
import re
import subprocess
import sys


def main():
    path, name = sys.argv[1], sys.argv[2]
    command = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["zig", "build", "test-protovalidate"]
    file = pathlib.Path(path)
    original = file.read_text()
    pattern = re.compile(r"(const " + re.escape(name) + r" = )([0-9_]+);")
    if not pattern.search(original):
        sys.exit(f"{path} holds no constant {name}")

    def builds(value):
        file.write_text(pattern.sub(lambda found: f"{found.group(1)}{value};", original))
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0 and "backwards branches" not in result.stderr:
            file.write_text(original)
            sys.exit("the build fails for another reason:\n" + result.stderr[:2000])
        return result.returncode == 0

    try:
        low, high = 1000, 2000
        while not builds(high):
            low, high = high, high * 2
        # The range ends within half a percent of the least value.
        while high - low > max(1, high // 200):
            middle = (low + high) // 2
            if builds(middle):
                high = middle
            else:
                low = middle
    finally:
        file.write_text(original)
    print(f"{name}: the least value that builds lies above {low}, at most {high}")


main()
