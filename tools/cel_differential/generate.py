#!/usr/bin/env python3
"""Writes a schema of random CEL rules and a file of random messages for the differential check.

Usage: generate.py <seed> <rules> <messages> <out directory>

The schema, <out>/proto/diff/v1/diff.proto, holds one message type for each rule, M0, M1 and so
on. Each type has the same fields and one `(buf.validate.message).cel` rule, so one encoded
message is a message of each type. <out>/messages.txt holds one message a line, as hexadecimal
digits of its protobuf encoding. A seed gives the same files each time.
"""
import random
import struct
import sys

FIELDS = """  string s = 1;
  string t = 2;
  int32 i = 3;
  int64 j = 4;
  uint32 u = 5;
  uint64 v = 6;
  double d = 7;
  bool b = 8;
  bytes y = 9;
  repeated string rs = 10;
  repeated int32 ri = 11;
  map<string, int32> msi = 12;
  google.protobuf.Duration dur = 13;
  Leaf leaf = 14;
"""

STRINGS = ["", "a", "b", "ab", "x1", "foo@example.com", "example.com", "1.2.3.4", "::1", "héllo", "https://a.example/b", "10", "-7", "true", "k"]
INTS = [0, 1, -1, 2, 3, 7, 10, 100, -100, 2**31 - 1, -(2**31)]
LONGS = INTS + [2**62, -(2**62), 2**63 - 1, -(2**63)]
UINTS = [0, 1, 2, 5, 100, 2**32 - 1]
ULONGS = UINTS + [2**63, 2**64 - 1]
DOUBLES = ["0.0", "1.5", "2.0", "-2.25", "100.0", "1e300"]
DURATIONS = ["0s", "1s", "5s", "90s", "1h", "-3s", "1.5s"]


class Generator:
    """Writes expressions of a type the caller names, from the fields and the functions that
    protovalidate's CEL holds. `variables` holds a macro's variables in scope, by type."""

    def __init__(self, rng):
        self.rng = rng
        self.variables = {"string": [], "int": []}
        self.counter = 0

    def pick(self, choices):
        return self.rng.choice(choices)

    def literal_string(self):
        text = self.pick(STRINGS)
        return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"

    def string(self, depth):
        leaves = ["this.s", "this.t", "this.leaf.name", self.literal_string(), self.literal_string()] + self.variables["string"]
        if depth <= 0 or self.rng.random() < 0.6:
            return self.pick(leaves)
        kind = self.rng.randrange(4)
        if kind == 0:
            return f"this.rs[{self.int(0)}]"
        if kind == 1:
            return f"({self.bool(depth - 1)} ? {self.string(depth - 1)} : {self.string(depth - 1)})"
        if kind == 2:
            return f"string({self.string(depth - 1)})"
        return self.pick(leaves)

    def int(self, depth):
        leaves = ["this.i", "this.j", "this.leaf.count", str(self.pick(INTS)), str(self.pick(INTS))] + self.variables["int"]
        if depth <= 0 or self.rng.random() < 0.4:
            return self.pick(leaves)
        kind = self.rng.randrange(12)
        if kind < 4:
            return f"({self.int(depth - 1)} {self.pick(['+', '-', '*', '/', '%'])} {self.int(depth - 1)})"
        if kind == 4:
            return f"-{self.pick(['this.i', 'this.j', '(' + self.int(depth - 1) + ')'])}"
        if kind == 5:
            return f"{self.string(depth - 1)}.size()"
        if kind == 6:
            return self.pick(["this.rs.size()", "this.ri.size()", "this.msi.size()", "this.y.size()"])
        if kind == 7:
            return f"int({self.pick([self.uint(depth - 1), self.double(depth - 1), self.string(0)])})"
        if kind == 8:
            return f"this.ri[{self.int(0)}]"
        if kind == 9:
            return f"this.msi[{self.string(0)}]"
        if kind == 10:
            return f"({self.bool(depth - 1)} ? {self.int(depth - 1)} : {self.int(depth - 1)})"
        return self.pick(leaves)

    def uint(self, depth):
        leaves = ["this.u", "this.v", f"{self.pick(UINTS)}u"]
        if depth <= 0 or self.rng.random() < 0.5:
            return self.pick(leaves)
        kind = self.rng.randrange(3)
        if kind == 0:
            return f"({self.uint(depth - 1)} {self.pick(['+', '-', '*', '/', '%'])} {self.uint(depth - 1)})"
        if kind == 1:
            return f"uint({self.pick([self.int(depth - 1), self.double(depth - 1), self.string(0)])})"
        return self.pick(leaves)

    def double(self, depth):
        leaves = ["this.d", self.pick(DOUBLES)]
        if depth <= 0 or self.rng.random() < 0.5:
            return self.pick(leaves)
        kind = self.rng.randrange(3)
        if kind == 0:
            return f"({self.double(depth - 1)} {self.pick(['+', '-', '*', '/'])} {self.double(depth - 1)})"
        if kind == 1:
            return f"double({self.pick([self.int(depth - 1), self.uint(depth - 1), self.string(0)])})"
        return self.pick(leaves)

    def duration(self):
        return self.pick(["this.dur", f"duration('{self.pick(DURATIONS)}')"])

    def variable(self):
        self.counter += 1
        return f"x{self.counter}"

    def macro(self, depth):
        name = self.variable()
        macro = self.pick(["all", "exists", "exists_one"])
        source = self.rng.randrange(4)
        if source == 0:
            collection, kind = "this.rs", "string"
        elif source == 1:
            collection, kind = "this.ri", "int"
        elif source == 2:
            collection, kind = "this.msi", "string"
        else:
            collection, kind = "[" + ", ".join(str(self.pick(INTS)) for _ in range(self.rng.randrange(1, 4))) + "]", "int"
        self.variables[kind].append(name)
        body = self.bool(depth - 1)
        self.variables[kind].pop()
        return f"{collection}.{macro}({name}, {body})"

    def comparison(self, depth):
        kind = self.rng.randrange(7)
        order = self.pick(["==", "!=", "<", "<=", ">", ">="])
        if kind == 0:
            return f"{self.int(depth)} {order} {self.int(depth)}"
        if kind == 1:
            return f"{self.uint(depth)} {order} {self.uint(depth)}"
        if kind == 2:
            return f"{self.double(depth)} {order} {self.double(depth)}"
        if kind == 3:
            return f"{self.string(depth)} {order} {self.string(depth)}"
        if kind == 4:
            return f"{self.duration()} {order} {self.duration()}"
        if kind == 5:
            return f"this.y {self.pick(['==', '!='])} {self.pick(['this.y', 'bytes(this.s)', 'b' + self.literal_string()])}"
        # Numbers of two types, which protovalidate's CEL compares.
        left, right = self.rng.sample([self.int(depth), self.uint(depth), self.double(depth)], 2)
        return f"{left} {order} {right}"

    def bool(self, depth):
        if depth <= 0:
            return self.pick(["true", "false", "this.b", self.comparison(0)])
        kind = self.rng.randrange(16)
        if kind < 5:
            return self.comparison(depth - 1)
        if kind < 7:
            return f"({self.bool(depth - 1)} {self.pick(['&&', '||'])} {self.bool(depth - 1)})"
        if kind == 7:
            return f"!({self.bool(depth - 1)})"
        if kind == 8:
            return f"({self.bool(depth - 1)} ? {self.bool(depth - 1)} : {self.bool(depth - 1)})"
        if kind == 9:
            return f"{self.string(depth - 1)}.{self.pick(['startsWith', 'endsWith', 'contains'])}({self.string(depth - 1)})"
        if kind == 10:
            return self.pick([f"{self.string(depth - 1)} in this.rs", f"{self.int(depth - 1)} in this.ri", f"{self.string(depth - 1)} in this.msi", f"{self.int(depth - 1)} in [1, 2, 3]"])
        if kind == 11:
            return self.macro(depth)
        if kind == 12:
            return f"has({self.pick(['this.leaf', 'this.leaf.name', 'this.s', 'this.i', 'this.dur', 'this.b'])})"
        if kind == 13:
            function = self.pick(["isEmail()", "isHostname()", "isIp()", "isIp(4)", "isIp(6)", "isUri()", "isUriRef()", "isIpPrefix()", "isHostAndPort(true)"])
            return f"{self.string(depth - 1)}.{function}"
        if kind == 14:
            return f"{self.double(depth - 1)}.{self.pick(['isNan()', 'isInf()', 'isInf(1)', 'isInf(-1)'])}"
        return self.pick(["this.b", f"bool({self.pick(['this.b', self.literal_string()])})", f"dyn({self.int(depth - 1)}) == {self.int(0)}"])

    def rule(self):
        depth = self.rng.randrange(1, 5)
        if self.rng.random() < 0.15:
            # A rule that gives a string: the violation's message, or none when it is empty.
            return f"{self.bool(depth)} ? '' : {self.pick([self.literal_string(), self.string(1)])}"
        return self.bool(depth)


def varint(value):
    value &= (1 << 64) - 1
    out = bytearray()
    while True:
        low = value & 0x7F
        value >>= 7
        if value:
            out.append(low | 0x80)
        else:
            out.append(low)
            return bytes(out)


def tag(number, wire):
    return varint(number << 3 | wire)


def delimited(number, payload):
    return tag(number, 2) + varint(len(payload)) + payload


def message(rng):
    """One random message, encoded. A field is left out about one time in three."""
    out = bytearray()

    def maybe():
        return rng.random() < 0.67

    if maybe():
        out += delimited(1, rng.choice(STRINGS).encode())
    if maybe():
        out += delimited(2, rng.choice(STRINGS).encode())
    if maybe():
        out += tag(3, 0) + varint(rng.choice(INTS))
    if maybe():
        out += tag(4, 0) + varint(rng.choice(LONGS))
    if maybe():
        out += tag(5, 0) + varint(rng.choice(UINTS))
    if maybe():
        out += tag(6, 0) + varint(rng.choice(ULONGS))
    if maybe():
        out += tag(7, 1) + struct.pack("<d", rng.choice([0.0, 1.5, -2.25, 100.0, 1e300, float("inf"), float("-inf"), float("nan")]))
    if maybe():
        out += tag(8, 0) + varint(rng.randrange(2))
    if maybe():
        out += delimited(9, rng.choice([b"", b"a", b"\x00\xff", "héllo".encode()]))
    for _ in range(rng.choice([0, 0, 1, 2, 3])):
        out += delimited(10, rng.choice(STRINGS).encode())
    if maybe():
        out += delimited(11, b"".join(varint(rng.choice(INTS)) for _ in range(rng.randrange(4))))
    for _ in range(rng.choice([0, 0, 1, 2, 3])):
        entry = delimited(1, rng.choice(STRINGS).encode()) + tag(2, 0) + varint(rng.choice(INTS))
        out += delimited(12, entry)
    if maybe():
        out += delimited(13, tag(1, 0) + varint(rng.choice([0, 1, 5, 90, 3600, -3])) + tag(2, 0) + varint(rng.choice([0, 0, 500000000])))
    if maybe():
        out += delimited(14, delimited(1, rng.choice(STRINGS).encode()) + tag(2, 0) + varint(rng.choice(INTS)))
    return bytes(out)


def main():
    seed, rules, messages, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    rng = random.Random(seed)
    generator = Generator(rng)
    lines = [
        'syntax = "proto3";',
        "",
        "package diff.v1;",
        "",
        'import "buf/validate/validate.proto";',
        'import "google/protobuf/duration.proto";',
        "",
        "message Leaf {",
        "  string name = 1;",
        "  int32 count = 2;",
        "}",
    ]
    for index in range(rules):
        expression = generator.rule().replace("\\", "\\\\").replace('"', '\\"')
        lines += ["", f"message M{index} {{", f'  option (buf.validate.message).cel = {{id: "r{index}", message: "m", expression: "{expression}"}};', FIELDS.rstrip("\n"), "}"]
    with open(f"{out}/proto/diff/v1/diff.proto", "w") as file:
        file.write("\n".join(lines) + "\n")
    with open(f"{out}/messages.txt", "w") as file:
        for _ in range(messages):
            file.write(message(rng).hex() + "\n")


main()
