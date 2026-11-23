#!/usr/bin/env python3
"""Compares the results of the CEL conformance runner with what cel-spec's suite expects.

Usage: compare.py <expected.json> <results.txt> <known.txt>

<expected.json> is what generate.py wrote. <results.txt> holds one line for each case that the
runner printed: the test's full name, a tab, and the result as JSON. <known.txt> holds the
differences that pass, one a line of three fields split by tabs: a regular expression over the
full name, one over what differs, and the reason. What differs is the problem of an expression
that does not compile, or the expected and the given value of one that runs. A line that starts
with `#` and an empty line are comments.

Each test ends in one of six groups:

- pass: the value is the value the suite expects, or the expression fails where the suite
  expects an error.
- known: the result differs, and a line of known.txt names the test.
- unchecked: the expression does not compile, and the test turns the type check off. The
  suite then expects the run to find the mistake that the module's compiler finds, and a rule's
  expression is always checked.
- refused: the expression does not compile, and no line of known.txt names the test.
- wrong: the result differs, and no line of known.txt names the test.
- skipped: generate.py did not write the test, and says why.

The script prints a count of each group and each test of the groups refused and wrong, and
exits 1 when either holds a test, or when a line of known.txt names no test that differs.
"""

import base64
import json
import math
import pathlib
import re
import sys
from datetime import UTC, datetime

# Every second of the protobuf duration's text is this many nanoseconds.
NANOS_PER_SECOND = 1_000_000_000
# The fraction's digits that a protobuf timestamp's text holds at most.
FRACTION_DIGITS_MAX = 9
TIMESTAMP_TYPE = "type.googleapis.com/google.protobuf.Timestamp"
DURATION_TYPE = "type.googleapis.com/google.protobuf.Duration"


def timestamp_of(text):
    """The seconds and nanoseconds of a protobuf timestamp's JSON text."""
    match = re.fullmatch(r"(.*?)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)", text)
    whole = datetime.fromisoformat(match.group(1) + ("+00:00" if match.group(3) == "Z" else match.group(3)))
    fraction = (match.group(2) or "").ljust(FRACTION_DIGITS_MAX, "0")
    seconds = int((whole - datetime(1970, 1, 1, tzinfo=UTC)).total_seconds())
    return [seconds, int(fraction)]


def duration_of(text):
    """The seconds and nanoseconds of a protobuf duration's JSON text, such as `-1.5s`."""
    match = re.fullmatch(r"(-?)(\d+)(?:\.(\d{1,9}))?s", text)
    sign = -1 if match.group(1) else 1
    fraction = (match.group(3) or "").ljust(FRACTION_DIGITS_MAX, "0")
    return [sign * int(match.group(2)), sign * int(fraction)]


def double_of(value):
    """A double from the suite's JSON, a number or one of "NaN", "Infinity" and "-Infinity"."""
    if isinstance(value, str):
        return float({"NaN": "nan", "Infinity": "inf", "-Infinity": "-inf"}.get(value, value))
    return float(value)


def object_of(value):
    """A well-known object in the runner's form, or None for one the runner cannot write."""
    if value.get("@type") == TIMESTAMP_TYPE:
        return {"timestamp": timestamp_of(value["value"])}
    if value.get("@type") == DURATION_TYPE:
        return {"duration": duration_of(value["value"])}
    return None


def normal(value):
    """A cel.expr.Value of the suite in the form the runner writes it, or None."""
    kind, held = next(iter(value.items()))
    if kind == "bytesValue":
        return {"bytesHex": base64.b64decode(held).hex()}
    if kind == "doubleValue":
        return {"doubleValue": double_of(held)}
    if kind == "listValue":
        values = [normal(element) for element in held.get("values", [])]
        return None if None in values else {"listValue": {"values": values}}
    if kind == "mapValue":
        entries = [(normal(entry["key"]), normal(entry["value"])) for entry in held.get("entries", [])]
        if any(None in entry for entry in entries):
            return None
        return {"mapValue": sorted((json.dumps(key, sort_keys=True), item) for key, item in entries)}
    if kind == "objectValue":
        return object_of(held)
    if kind in ("boolValue", "int64Value", "uint64Value", "stringValue", "typeValue", "nullValue"):
        return {kind: held}
    return None


def runner_normal(value):
    """A value the runner wrote, with doubles read as numbers and a map's entries sorted."""
    kind, held = next(iter(value.items()))
    if kind == "doubleValue":
        return {"doubleValue": double_of(held)}
    if kind == "listValue":
        return {"listValue": {"values": [runner_normal(element) for element in held["values"]]}}
    if kind == "mapValue":
        entries = [(runner_normal(entry["key"]), runner_normal(entry["value"])) for entry in held["entries"]]
        return {"mapValue": sorted((json.dumps(key, sort_keys=True), item) for key, item in entries)}
    return value


def same(expected, actual):
    """Whether two values are equal, a double NaN equal to NaN and 0.0 apart from -0.0 no more."""
    if isinstance(expected, float) and isinstance(actual, float):
        return (math.isnan(expected) and math.isnan(actual)) or expected == actual
    if isinstance(expected, dict) and isinstance(actual, dict):
        return expected.keys() == actual.keys() and all(same(expected[k], actual[k]) for k in expected)
    if isinstance(expected, (list, tuple)) and isinstance(actual, (list, tuple)):
        return len(expected) == len(actual) and all(same(e, a) for e, a in zip(expected, actual, strict=True))
    return expected == actual


def verdict(expected, actual):
    """`pass`, `refused` or `wrong`, with what differs."""
    if "error" in expected:
        if "error" in actual:
            return "pass", ""
        if "refused" in actual:
            return "pass", ""
        return "wrong", f"expected an error, got {json.dumps(actual)}"
    if "refused" in actual:
        return ("unchecked" if expected.get("unchecked") else "refused"), actual["refused"]
    want = normal(expected["value"])
    if want is None:
        return "wrong", f"expects {json.dumps(expected['value'])}, which the check cannot compare"
    if "error" in actual:
        return "wrong", f"expected {json.dumps(want)}, got {json.dumps(actual)}"
    got = runner_normal(actual)
    if same(want, got):
        return "pass", ""
    return "wrong", f"expected {json.dumps(want)}, got {json.dumps(got)}"


def read_known(path):
    known = []
    with open(path, encoding="utf-8") as lines:
        for line in lines:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            name, detail, reason = line.split("\t", 2)
            known.append([re.compile(name), re.compile(detail), reason, 0])
    return known


def read_results(path):
    """Each test's result, by its full name, from the runner's lines."""
    results = {}
    with open(path, encoding="utf-8") as lines:
        for line in lines:
            name, text = line.rstrip("\n").split("\t", 1)
            results[name] = json.loads(text)
    return results


def group_of(name, want, results, known):
    """The group of a test that the suite does not skip, and what differs, or the reason of the
    line of known.txt that names it, whose count it adds to."""
    group, detail = verdict(want, results[name]) if name in results else ("wrong", "no result")
    if group in ("pass", "unchecked"):
        return group, detail
    entry = next((entry for entry in known if entry[0].fullmatch(name) and entry[1].search(detail)), None)
    if entry is None:
        return group, detail
    entry[3] += 1
    return "known", entry[2]


def main():
    expected = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    known = read_known(sys.argv[3])
    results = read_results(sys.argv[2])
    groups = {"pass": [], "known": [], "unchecked": [], "refused": [], "wrong": [], "skipped": []}
    for name, want in sorted(expected.items()):
        if "skip" in want:
            groups["skipped"].append((name, want["skip"]))
            continue
        group, detail = group_of(name, want, results, known)
        groups[group].append((name, detail))
    for group in ("refused", "wrong"):
        for name, detail in groups[group]:
            print(f"{group}\t{name}\t{json.dumps(detail)[1:-1]}")
    unused = [entry for entry in known if entry[3] == 0]
    for entry in unused:
        print(f"unused\t{entry[0].pattern}\t{entry[1].pattern}\tnames no test that differs")
    print(" ".join(f"{group} {len(tests)}" for group, tests in groups.items()))
    return 1 if groups["refused"] or groups["wrong"] or unused else 0


if __name__ == "__main__":
    sys.exit(main())
