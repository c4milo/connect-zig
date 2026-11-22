#!/usr/bin/env python3
"""Writes the cases of the CEL conformance check from cel-spec's conformance suite.

Usage: generate.py <out directory> <suite.json>...

Each <suite.json> is one file of cel-spec's tests/simple/testdata as JSON, a
cel.expr.conformance.test.SimpleTestFile that `buf convert` wrote. The script writes
<out>/cases.zig, one case for each test that the runner compiles, and <out>/expected.json, the
result each test expects, or why the check skips it, and whether the test turns the type
check off. A test is skipped when it declares
variables, binds values, names a container, sets a locale, turns the macros off, or asks for its
type alone: the runner compiles an expression that reads no name, as a rule's expression reads
only its own names.
"""
import json
import pathlib
import sys

# A test's fields that the runner does not read, each with why a test that sets it is skipped.
SKIPPED = {
    "typeEnv": "declares variables or functions",
    "bindings": "binds values to names",
    "container": "names a container",
    "locale": "sets a locale",
    "disableMacros": "turns the macros off",
    "checkOnly": "asks for its type alone",
}


def zig_string(text):
    """A Zig string literal of `text`'s UTF-8 octets."""
    out = []
    for octet in text.encode("utf-8"):
        character = chr(octet)
        if character == "\\":
            out.append("\\\\")
        elif character == '"':
            out.append('\\"')
        elif 0x20 <= octet < 0x7F:
            out.append(character)
        else:
            out.append(f"\\x{octet:02x}")
    return '"' + "".join(out) + '"'


# The result a test expects when it names none: "An unspecified result defaults to a matcher
# for the true boolean value", as cel-spec's proto/cel/expr/conformance/test/simple.proto says.
DEFAULT_RESULT = {"boolValue": True}
# The fields that name a test's result.
RESULT_FIELDS = ("value", "typedResult", "evalError", "anyEvalErrors", "unknown", "anyUnknowns")


def expected_of(test):
    """What a test expects: a value, an error, or a result the check skips."""
    if "value" in test:
        return {"value": test["value"]}
    if "typedResult" in test and "result" in test["typedResult"]:
        return {"value": test["typedResult"]["result"]}
    if "evalError" in test or "anyEvalErrors" in test:
        return {"error": True}
    if not any(field in test for field in RESULT_FIELDS):
        return {"value": DEFAULT_RESULT}
    return {"skip": "expects an unknown value"}


def main():
    out, paths = pathlib.Path(sys.argv[1]), sys.argv[2:]
    cases, expected = [], {}
    for path in sorted(paths):
        suite = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        for section in suite.get("section", []):
            for test in section.get("test", []):
                name = f"{suite['name']}/{section['name']}/{test['name']}"
                skipped = next((why for field, why in SKIPPED.items() if test.get(field)), None)
                result = {"skip": skipped} if skipped else expected_of(test)
                # The suite runs such a test with no check of its types, which a rule always has.
                if test.get("disableCheck") and "skip" not in result:
                    result["unchecked"] = True
                expected[name] = result
                if "skip" not in result:
                    cases.append((name, test["expr"]))
    lines = [
        "//! Written by tools/cel_conformance/generate.py from cel-spec's conformance suite. DO NOT EDIT.",
        "pub const Case = struct { name: []const u8, expr: []const u8 };",
        "",
        "pub const cases = [_]Case{",
    ]
    lines += [f"    .{{ .name = {zig_string(name)}, .expr = {zig_string(expr)} }}," for name, expr in cases]
    lines.append("};")
    (out / "cases.zig").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out / "expected.json").write_text(json.dumps(expected, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{len(cases)} cases of {len(expected)} tests")


main()
