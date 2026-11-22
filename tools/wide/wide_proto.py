#!/usr/bin/env python3
"""Writes tools/wide/proto/wide/v1/wide.proto: a message of 1,200 fields with rules, and a
message of 1,100 repeated and map fields.

The messages are wider than any a person writes by hand. The first holds the build to four things
a message of about 500 fields or more needs (docs/design.md §8, "Large schemas"): the protobuf
module reads each of its fields at compile time, the plugin raises the compiler's branch quota in
its table, `protovalidate` finds each field's rules without a search of the table, and each
function that reads every field raises the quota itself. The compiler's default quota is 1000
branches, so the message has more fields than that. The second holds the plugin to one more: it
declares each repeated type once in the file, since the compiler counts each call in the types
of a struct's fields against one quota.

Usage: python3 tools/wide/wide_proto.py, then tools/generate_check.sh --write.
"""
import pathlib

FIELDS = 1200
CEL_EVERY = 60
LISTS = 1100

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
    "// A message of 1,200 fields: an int32, a string, a list and a message, 300 times.",
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
lines += [
    "",
    "// A message of 1,100 repeated and map fields: a list of int32, of strings and of messages, and a",
    "// map, 275 times.",
    "message Lists {",
]
for number in range(1, LISTS + 1):
    kind = number % 4
    if kind == 1:
        lines.append(f"  repeated int32 f{number} = {number} [(buf.validate.field).repeated.max_items = 4];")
    elif kind == 2:
        lines.append(f"  repeated string f{number} = {number};")
    elif kind == 3:
        lines.append(f"  repeated Leaf f{number} = {number};")
    else:
        lines.append(f"  map<string, int32> f{number} = {number};")
lines.append("}")
pathlib.Path(__file__).parent.joinpath("proto/wide/v1/wide.proto").write_text("\n".join(lines) + "\n")
