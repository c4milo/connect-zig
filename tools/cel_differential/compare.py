#!/usr/bin/env python3
"""Compares the verdicts of this library with those of protovalidate-go.

Usage: compare.py <schema.proto> <zig.txt> <go.txt> <refused.txt> <known.txt>

Each of zig.txt and go.txt holds a line for each pair of a rule and a message: the rule's
number, the message's number and the verdict. refused.txt holds the reason of each rule this
library does not compile. known.txt holds the differences that are known: a line is a regular
expression and, after a tab, its reason. A difference is known when an expression of known.txt
matches this library's reason for it. The script prints each other difference with its rule's
expression, and exits 1 when there is one.
"""

import collections
import pathlib
import re
import sys


def verdicts(path):
    table = {}
    # A message may hold octets that are not UTF-8, which `format` copied from bytes: each shows
    # as an escape, the same on both sides.
    with open(path, encoding="utf-8", errors="backslashreplace") as file:
        for line in file:
            rule, message, verdict = line.rstrip("\n").split(" ", 2)
            table[int(rule), int(message)] = verdict
    return table


def read_expressions(schema):
    """Each rule's expression, in the order the schema declares them."""
    expressions = re.findall(r'expression: "((?:[^"\\]|\\.)*)"', pathlib.Path(schema).read_text(encoding="utf-8"))
    return [text.replace('\\"', '"').replace("\\\\", "\\") for text in expressions]


def read_reasons(refused_path):
    """Why this library refused each rule it refused, by the rule's number."""
    reasons = {}
    with open(refused_path, encoding="utf-8") as lines:
        for line in lines:
            found = re.match(r"M(\d+) is refused: (.*)", line.rstrip("\n"))
            if found:
                reasons[int(found.group(1))] = found.group(2)
    return reasons


def read_known(known_path):
    """Each line of known.txt: a pattern of a refusal's reason, and why the difference passes."""
    known = []
    with open(known_path, encoding="utf-8") as lines:
        for line in lines:
            if line.strip() and not line.startswith("#"):
                pattern, reason = line.rstrip("\n").split("\t", 1)
                known.append((re.compile(pattern), reason))
    return known


def sort_pairs(zig, go, reasons, known):
    """The verdicts both sides gave, by kind; the differences known.txt excuses, by reason; and the
    differences it does not, by rule."""
    agreed = collections.Counter()
    excused = collections.Counter()
    unknown = {}
    for pair in sorted(zig):
        if zig[pair] == go[pair]:
            agreed[zig[pair].split(":")[0]] += 1
            continue
        reason = reasons.get(pair[0], "")
        excuse = next((why for pattern, why in known if zig[pair] == "refused" and pattern.search(reason)), None)
        if excuse:
            excused[excuse] += 1
        else:
            unknown.setdefault(pair[0], []).append((pair[1], zig[pair], go[pair]))
    return agreed, excused, unknown


def write_unknown(unknown, expressions, reasons):
    """Each rule whose verdicts differ with no reason known.txt gives, with its first message."""
    for rule, pairs in sorted(unknown.items()):
        message, ours, theirs = pairs[0]
        print(f"DIFFERENT rule {rule}: `{expressions[rule]}`")
        print(
            f"  message {message}: this library says {ours}, protovalidate-go says {theirs} ({len(pairs)} messages differ)"
        )
        if rule in reasons:
            print(f"  refused: {reasons[rule]}")


def main():
    schema, zig_path, go_path, refused_path, known_path = sys.argv[1:6]
    expressions = read_expressions(schema)
    reasons = read_reasons(refused_path)
    known = read_known(known_path)
    zig, go = verdicts(zig_path), verdicts(go_path)
    if zig.keys() != go.keys():
        sys.exit(f"the two sides hold verdicts of different pairs: {len(zig)} and {len(go)}")
    agreed, excused, unknown = sort_pairs(zig, go, reasons, known)
    print(
        f"{len(zig)} verdicts of {len(expressions)} rules: "
        + ", ".join(f"{count} {name}" for name, count in sorted(agreed.items()))
        + " on both sides"
    )
    for excuse, count in sorted(excused.items()):
        print(f"{count} known differences: {excuse}")
    write_unknown(unknown, expressions, reasons)
    if unknown:
        sys.exit(1)


if __name__ == "__main__":
    main()
