#!/usr/bin/env python3
"""Writes the schema whose build tools/compile_time_check.sh times, to standard output.

Usage: schema.py <messages> <fields> [plain]

The schema holds `messages` message types of `fields` fields each, and one message, All, that
holds each of them. Each field has a standard rule and a CEL rule of its own text, and each
message has three CEL rules that read several of its fields, so no two expressions are one
text. With `plain` the schema has the same fields and no CEL rule: the build of the two shows
what the CEL rules cost the compiler.
"""

import sys


def field(message, number, total, plain):
    """One field of the six kinds in turn: its line in the schema."""
    unique = message * total + number
    kind = number % 6
    if kind == 1:
        rules = [f"(buf.validate.field).string = {{min_len: 1, max_len: {50 + number}}}"]
        cel = f"this.size() < {100 + unique} && !this.startsWith('x{unique}')"
        declared = f"string f{number}"
    elif kind == 2:
        rules = [f"(buf.validate.field).int32 = {{gte: 0, lt: {1000 + number}}}"]
        cel = f"this % {2 + number % 7} == 0 || this > {unique}"
        declared = f"int32 f{number}"
    elif kind == 3:
        rules = [f"(buf.validate.field).repeated.max_items = {10 + number % 5}"]
        cel = f"this.all(x, x.size() > {unique % 5}) && this.size() < {unique + 20}"
        declared = f"repeated string f{number}"
    elif kind == 4:
        rules = [f"(buf.validate.field).map.max_pairs = {10 + number % 5}"]
        cel = f"this.all(key, this[key] >= {unique % 9}) && !('k{unique}' in this)"
        declared = f"map<string, int32> f{number}"
    elif kind == 5:
        rules = ["(buf.validate.field).required = true"]
        cel = f"this < duration('{unique}s') || this >= duration('{unique + 1}h')"
        declared = f"google.protobuf.Duration f{number}"
    else:
        rules = ["(buf.validate.field).required = true"]
        cel = f"this.name.size() != {unique}"
        declared = f"Leaf f{number}"
    if not plain:
        rules.append(
            f'(buf.validate.field).cel = {{id: "m{message}.f{number}", message: "wrong", expression: "{cel}"}}'
        )
    return f"  {declared} = {number} [{', '.join(rules)}];"


def main():
    messages, fields = int(sys.argv[1]), int(sys.argv[2])
    plain = len(sys.argv) > 3 and sys.argv[3] == "plain"
    lines = [
        'syntax = "proto3";',
        "",
        "package timed.v1;",
        "",
        'import "buf/validate/validate.proto";',
        'import "google/protobuf/duration.proto";',
        "",
        "message Leaf {",
        "  string name = 1 [(buf.validate.field).string.min_len = 1];",
        "}",
    ]
    for message in range(messages):
        lines += ["", f"message M{message} {{"]
        if not plain:
            # A message's rules read its first and its last string, and its first and its last int.
            last_string = fields - (fields - 1) % 6
            last_int = fields - (fields - 2) % 6
            for name, text in [
                ("sizes", f"this.f1.size() + this.f{last_string}.size() < {1000 + message}"),
                ("order", f"this.f2 <= this.f{last_int} || this.f{last_int} == {message}"),
                ("either", f"this.f1 != '' ? true : this.f2 > {message}"),
            ]:
                lines.append(
                    f'  option (buf.validate.message).cel = {{id: "m{message}.{name}", message: "wrong", expression: "{text}"}};'
                )
        lines += [field(message, number, fields, plain) for number in range(1, fields + 1)]
        lines.append("}")
    lines += ["", "message All {"]
    lines += [f"  M{message} m{message} = {message + 1};" for message in range(messages)]
    lines.append("}")
    print("\n".join(lines))


main()
