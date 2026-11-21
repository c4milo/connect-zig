#!/usr/bin/env python3
"""Writes tools/wide/proto/wide/v1/wide.proto: one message of 600 fields with rules.

The message is wider than any a person writes by hand. It holds the build to three things a
message of about 500 fields or more needs (docs/design.md §8, "Large schemas"): the protobuf
module reads each of its fields at compile time, the plugin raises the compiler's branch quota in
its table, and `protovalidate` finds each field's rules without a search of the table.

Usage: python3 tools/wide/wide_proto.py, then tools/generate_check.sh --write.
"""
import pathlib

FIELDS = 600
CEL_EVERY = 60

lines = [
    "// Written by tools/wide/wide_proto.py. DO NOT EDIT.",
    'syntax = "proto3";',
    "",
    "package wide.v1;",
    "",
    'import "buf/validate/validate.proto";',
    "",
    "message Leaf {",
    "  string name = 1 [(buf.validate.field).string.min_len = 1];",
    "}",
    "",
    "// A message of 600 fields: an int32, a string, a list and a message, 150 times.",
    "message Wide {",
    "  option (buf.validate.message).cel = {",
    '    id: "wide.ends"',
    '    message: "f1 must not exceed f597"',
    '    expression: "this.f1 <= this.f597"',
    "  };",
]
for number in range(1, FIELDS + 1):
    kind = number % 4
    if kind == 1:
        rules = ["(buf.validate.field).int32 = {gte: 0, not_in: [-1]}"]
        if number % CEL_EVERY == 1:
            rules.append(f'(buf.validate.field).cel_expression = "this < {1000 + number}"')
        lines.append(f"  int32 f{number} = {number} [{', '.join(rules)}];")
    elif kind == 2:
        lines.append(f'  string f{number} = {number} [(buf.validate.field).string = {{max_len: {number}, not_in: ["x"]}}];')
    elif kind == 3:
        lines.append(f"  repeated int32 f{number} = {number} [(buf.validate.field).repeated = {{max_items: 4, items: {{int32: {{lt: 100}}}}}}];")
    else:
        lines.append(f"  Leaf f{number} = {number};")
lines.append("}")
pathlib.Path(__file__).parent.joinpath("proto/wide/v1/wide.proto").write_text("\n".join(lines) + "\n")
