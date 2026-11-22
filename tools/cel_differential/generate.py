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
# RE2 patterns that Go's regexp and stdx's regex both read, and that match texts of STRINGS in
# different ways: anchors, classes, ASCII's case folding, repetition, alternation and `.` over
# a character of two octets.
PATTERNS = ["^a", "b$", "^[a-z]+$", "(?i)^A", "\\d+", "^\\w+@\\w+\\.com$", "x|1", "^(ab)*$", "[^a-z]", "^.{2,5}$", "é", "^$", "\\.", "^[0-9a-f:.]+$", "^-?[0-9]+$"]
INTS = [0, 1, -1, 2, 3, 7, 10, 100, -100, 2**31 - 1, -(2**31)]
LONGS = INTS + [2**62, -(2**62), 2**63 - 1, -(2**63)]
UINTS = [0, 1, 2, 5, 100, 2**32 - 1]
ULONGS = UINTS + [2**63, 2**64 - 1]
DOUBLES = ["0.0", "1.5", "2.0", "-2.25", "100.0", "1e300"]
DURATIONS = ["0s", "1s", "5s", "90s", "1h", "-3s", "1.5s"]
# Timestamps in UTC: cel-go writes a timestamp read with an offset in that offset, where this
# library writes UTC (docs/specs/README.md), so `string` of one would differ on purpose.
TIMESTAMPS = ["2023-12-25T12:30:45.678Z", "2000-02-29T23:59:59Z", "1970-01-01T00:00:00Z", "0001-01-01T00:00:00Z", "9999-12-31T23:59:59.999999999Z", "2024-03-01T08:00:00Z"]
# Zones cel-go and this library both read: UTC and fixed offsets, no names.
ZONES = ["UTC", "+05:30", "-08:00", "-00:30", "+14:00", "-12:45", "5:00", "+23:59"]
TIMESTAMP_PARTS = ["getFullYear", "getMonth", "getDate", "getDayOfMonth", "getDayOfYear", "getDayOfWeek", "getHours", "getMinutes", "getSeconds", "getMilliseconds"]
DURATION_PARTS = ["getHours", "getMinutes", "getSeconds", "getMilliseconds"]
# The texts of STRINGS that are identifiers, so a map's key may be selected as a field: `m.ab`.
KEYS = ["a", "b", "ab", "x1", "k"]


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
        return self.literal(self.pick(STRINGS))

    def literal(self, text):
        return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"

    def string(self, depth):
        leaves = ["this.s", "this.t", "this.leaf.name", self.literal_string(), self.literal_string()] + self.variables["string"]
        if depth <= 0 or self.rng.random() < 0.6:
            return self.pick(leaves)
        kind = self.rng.randrange(6)
        if kind == 0:
            return f"this.rs[{self.int(0)}]"
        if kind == 1:
            return f"({self.bool(depth - 1)} ? {self.string(depth - 1)} : {self.string(depth - 1)})"
        if kind == 2:
            return f"string({self.string(depth - 1)})"
        if kind == 3:
            return f"({self.string(depth - 1)} + {self.string(depth - 1)})"
        if kind == 4:
            value = self.pick([self.int(depth - 1), self.uint(depth - 1), self.double(depth - 1), self.bool(depth - 1), self.timestamp(depth - 1), self.duration(depth - 1)])
            return f"string({value})"
        return self.pick(leaves)

    def int(self, depth):
        leaves = ["this.i", "this.j", "this.leaf.count", str(self.pick(INTS)), str(self.pick(INTS))] + self.variables["int"]
        if depth <= 0 or self.rng.random() < 0.4:
            return self.pick(leaves)
        kind = self.rng.randrange(14)
        if kind < 4:
            return f"({self.int(depth - 1)} {self.pick(['+', '-', '*', '/', '%'])} {self.int(depth - 1)})"
        if kind == 4:
            return f"-{self.pick(['this.i', 'this.j', '(' + self.int(depth - 1) + ')'])}"
        if kind == 5:
            return f"{self.string(depth - 1)}.size()"
        if kind == 6:
            return self.pick(["this.rs.size()", "this.ri.size()", "this.msi.size()", "this.y.size()", "(this.rs + this.rs).size()", "(this.ri + [1, 2]).size()", "(this.y + b'ab').size()"])
        if kind == 7:
            return f"int({self.pick([self.uint(depth - 1), self.double(depth - 1), self.string(0)])})"
        if kind == 8:
            return f"this.ri[{self.int(0)}]"
        if kind == 9:
            if self.rng.random() < 0.4:
                return f"this.msi.{self.pick(KEYS)}"
            return f"this.msi[{self.string(0)}]"
        if kind == 10:
            return f"({self.bool(depth - 1)} ? {self.int(depth - 1)} : {self.int(depth - 1)})"
        if kind == 11:
            return self.derived_int(depth)
        if kind == 12:
            if self.rng.random() < 0.3:
                return f"{self.duration(depth - 1)}.{self.pick(DURATION_PARTS)}()"
            zone = self.pick(["", self.literal(self.pick(ZONES))])
            return f"{self.timestamp(depth - 1)}.{self.pick(TIMESTAMP_PARTS)}({zone})"
        return self.pick(leaves)

    def derived(self, depth):
        """A list that `filter` or `map` gives, the type of its elements, and whether its order
        is the source's: a list made from a map follows the map, which has no order."""
        name = self.variable()
        collection, kind = self.pick([("this.rs", "string"), ("this.ri", "int"), ("this.msi", "string"), ("[3, 1, 2]", "int")])
        self.variables[kind].append(name)
        shape = self.rng.randrange(3)
        if shape == 0:
            text, element = f"{collection}.filter({name}, {self.bool(depth - 1)})", kind
        elif shape == 1:
            text, element = f"{collection}.map({name}, {self.int(depth - 1)})", "int"
        else:
            text, element = f"{collection}.map({name}, {self.bool(depth - 1)}, {self.int(depth - 1)})", "int"
        self.variables[kind].pop()
        return text, element, collection != "this.msi"

    def derived_int(self, depth):
        """The size of a list that `filter` or `map` gives, or an int at an index of one."""
        text, element, ordered = self.derived(depth)
        if element == "int" and ordered and self.rng.random() < 0.5:
            return f"{text}[{self.pick([0, 1])}]"
        return f"{text}.size()"

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

    def duration(self, depth=0):
        leaves = ["this.dur", f"duration('{self.pick(DURATIONS)}')"]
        if depth <= 0 or self.rng.random() < 0.6:
            return self.pick(leaves)
        kind = self.rng.randrange(3)
        if kind == 0:
            return f"({self.duration(depth - 1)} {self.pick(['+', '-'])} {self.duration(depth - 1)})"
        if kind == 1:
            return f"({self.timestamp(depth - 1)} - {self.timestamp(depth - 1)})"
        return f"duration({self.pick([self.string(0), self.literal(self.pick(DURATIONS))])})"

    def timestamp(self, depth=0):
        """A timestamp: a literal in UTC, a sum with a duration, or a text read as it runs."""
        literal = f"timestamp('{self.pick(TIMESTAMPS)}')"
        if depth <= 0 or self.rng.random() < 0.5:
            return literal
        kind = self.rng.randrange(3)
        if kind == 0:
            return f"({self.timestamp(depth - 1)} {self.pick(['+', '-'])} {self.duration(depth - 1)})"
        if kind == 1:
            return f"({self.duration(depth - 1)} + {self.timestamp(depth - 1)})"
        return f"timestamp({self.pick([self.literal(self.pick(TIMESTAMPS)), self.string(0)])})"

    def variable(self):
        self.counter += 1
        return f"x{self.counter}"

    def macro(self, depth):
        name = self.variable()
        macro = self.pick(["all", "exists", "exists_one"])
        source = self.rng.randrange(5)
        if source == 4:
            collection, kind, _ = self.derived(depth - 1)
        elif source == 0:
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
            if self.rng.random() < 0.5:
                return f"{self.timestamp(depth)} {order} {self.timestamp(depth)}"
            return f"{self.duration(depth)} {order} {self.duration(depth)}"
        if kind == 5:
            return f"this.y {self.pick(['==', '!='])} {self.pick(['this.y', 'bytes(this.s)', 'b' + self.literal_string(), 'bytes(this.s) + bytes(this.t)'])}"
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
            # `matches` takes a literal pattern, which this library reads as it compiles.
            if self.rng.random() < 0.3:
                return f"{self.string(depth - 1)}.matches({self.literal(self.pick(PATTERNS))})"
            return f"{self.string(depth - 1)}.{self.pick(['startsWith', 'endsWith', 'contains'])}({self.string(depth - 1)})"
        if kind == 10:
            if self.rng.random() < 0.25:
                collection, kind, _ = self.derived(depth - 1)
                return f"{self.string(0) if kind == 'string' else self.int(0)} in {collection}"
            return self.pick([f"{self.string(depth - 1)} in this.rs", f"{self.int(depth - 1)} in this.ri", f"{self.string(depth - 1)} in this.msi", f"{self.int(depth - 1)} in [1, 2, 3]"])
        if kind == 11:
            return self.macro(depth)
        if kind == 12:
            return f"has({self.pick(['this.leaf', 'this.leaf.name', 'this.s', 'this.i', 'this.dur', 'this.b', 'this.msi.' + self.pick(KEYS)])})"
        if kind == 13:
            function = self.pick(["isEmail()", "isHostname()", "isIp()", "isIp(4)", "isIp(6)", "isUri()", "isUriRef()", "isIpPrefix()", "isHostAndPort(true)"])
            return f"{self.string(depth - 1)}.{function}"
        if kind == 14:
            return f"{self.double(depth - 1)}.{self.pick(['isNan()', 'isInf()', 'isInf(1)', 'isInf(-1)'])}"
        return self.pick(["this.b", f"bool({self.pick(['this.b', self.literal_string()])})", f"dyn({self.int(depth - 1)}) == {self.int(0)}"])

    def formatted(self, depth):
        """`format` of one to three values, each under a conversion that takes its type (CEL
        strings extension, "Conversion")."""
        parts, values = [], []
        for _ in range(self.rng.randrange(1, 4)):
            kind = self.rng.randrange(7)
            if kind == 0:
                parts.append(self.pick(["%s", "%x", "%X"]))
                values.append(self.string(depth))
            elif kind == 1:
                parts.append(self.pick(["%s", "%d", "%x", "%X"]))
                values.append(self.int(depth))
            elif kind == 2:
                parts.append(self.pick(["%s", "%d", "%x"]))
                values.append(self.uint(depth))
            elif kind == 3:
                parts.append("%s")
                values.append(self.double(depth))
            elif kind == 4:
                parts.append("%s")
                values.append(self.bool(depth))
            elif kind == 5:
                # `%s` of bytes that are not UTF-8 differs on purpose: cel-go copies the octets,
                # and this library writes U+FFFD as the strings extension states
                # (docs/specs/README.md). So `this.y`, which may hold such octets, takes `%x`.
                if self.rng.random() < 0.5:
                    parts.append("%x")
                    values.append("this.y")
                else:
                    parts.append(self.pick(["%s", "%x"]))
                    values.append("b" + self.literal_string())
            else:
                parts.append("%s")
                values.append(self.pick(["this.rs", "this.ri", "[1, 2]"]))
        text = self.pick(["", "v=", "<"]) + " ".join(parts) + self.pick(["", ">", "!"])
        return f"{self.literal(text)}.format([{', '.join(values)}])"

    def rule(self):
        depth = self.rng.randrange(1, 5)
        if self.rng.random() < 0.15:
            # A rule that gives a string: the violation's message, or none when it is empty.
            return f"{self.bool(depth)} ? '' : {self.pick([self.literal_string(), self.string(1), self.formatted(1)])}"
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
