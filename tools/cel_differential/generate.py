#!/usr/bin/env python3
"""Writes a schema of random CEL rules and a file of random messages for the differential check.

Usage: generate.py <seed> <rules> <messages> <out directory>

The schema, <out>/proto/diff/v1/diff.proto, holds one message type for each rule, M0, M1 and so
on. Each type has the same fields and one `(buf.validate.message).cel` rule, so one encoded
message is a message of each type. <out>/messages.txt holds one message a line, as hexadecimal
digits of its protobuf encoding. A seed gives the same files each time.
"""

import random
import sys

from generate_messages import message
from generate_values import (
    DOUBLES,
    DURATION_PARTS,
    DURATIONS,
    FIELDS,
    INTS,
    KEYS,
    PATTERNS,
    STRINGS,
    TIMESTAMP_PARTS,
    TIMESTAMPS,
    TYPE_NAMES,
    UINTS,
    ZONES,
)


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
        leaves = ["this.s", "this.t", "this.leaf.name", self.literal_string(), self.literal_string()] + self.variables[
            "string"
        ]
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
            value = self.pick(
                [
                    self.int(depth - 1),
                    self.uint(depth - 1),
                    self.double(depth - 1),
                    self.bool(depth - 1),
                    self.timestamp(depth - 1),
                    self.duration(depth - 1),
                ]
            )
            return f"string({value})"
        return self.pick(leaves)

    def int(self, depth):
        leaves = ["this.i", "this.j", "this.leaf.count", str(self.pick(INTS)), str(self.pick(INTS))] + self.variables[
            "int"
        ]
        if depth <= 0 or self.rng.random() < 0.4:
            return self.pick(leaves)
        kind = self.rng.randrange(14)
        if kind < 6:
            return self.int_arithmetic(kind, depth)
        if kind < 13:
            return self.int_of_value(kind, depth)
        return self.pick(leaves)

    def int_arithmetic(self, kind, depth):
        """An int of the kinds 0 to 5 of `int`: an operator on two ints, a negation, or a size."""
        if kind < 4:
            return f"({self.int(depth - 1)} {self.pick(['+', '-', '*', '/', '%'])} {self.int(depth - 1)})"
        if kind == 4:
            return f"-{self.pick(['this.i', 'this.j', '(' + self.int(depth - 1) + ')'])}"
        return f"{self.string(depth - 1)}.size()"

    def int_of_value(self, kind, depth):
        """An int of the kinds 6 to 12 of `int`: a size, a conversion, an element, a choice, a
        derived int, or a part of a time."""
        if kind == 6:
            return self.pick(
                [
                    "this.rs.size()",
                    "this.ri.size()",
                    "this.msi.size()",
                    "this.y.size()",
                    "(this.rs + this.rs).size()",
                    "(this.ri + [1, 2]).size()",
                    "(this.y + b'ab').size()",
                ]
            )
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
        return self.time_part(depth)

    def time_part(self, depth):
        """An int part of a duration or of a timestamp, in a zone or in UTC."""
        if self.rng.random() < 0.3:
            return f"{self.duration(depth - 1)}.{self.pick(DURATION_PARTS)}()"
        zone = self.pick(["", self.literal(self.pick(ZONES))])
        return f"{self.timestamp(depth - 1)}.{self.pick(TIMESTAMP_PARTS)}({zone})"

    def derived(self, depth):
        """A list that `filter` or `map` gives, the type of its elements, and whether its order
        is the source's: a list made from a map follows the map, which has no order."""
        name = self.variable()
        collection, kind = self.pick(
            [("this.rs", "string"), ("this.ri", "int"), ("this.msi", "string"), ("[3, 1, 2]", "int")]
        )
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
            collection, kind = (
                "[" + ", ".join(str(self.pick(INTS)) for _ in range(self.rng.randrange(1, 4))) + "]",
                "int",
            )
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
        if kind < 9:
            return self.bool_logic(kind, depth)
        if kind == 9:
            return self.bool_text(depth)
        if kind == 10:
            return self.membership(depth)
        return self.bool_of_value(kind, depth)

    def bool_logic(self, kind, depth):
        """A bool of the kinds 0 to 8 of `bool`: a comparison, two bools joined, a negation, or a
        choice."""
        if kind < 5:
            return self.comparison(depth - 1)
        if kind < 7:
            return f"({self.bool(depth - 1)} {self.pick(['&&', '||'])} {self.bool(depth - 1)})"
        if kind == 7:
            return f"!({self.bool(depth - 1)})"
        return f"({self.bool(depth - 1)} ? {self.bool(depth - 1)} : {self.bool(depth - 1)})"

    def bool_text(self, depth):
        """A test of a string: a match of a pattern, or a start, an end, or a part."""
        # `matches` takes a literal pattern, which this library reads as it compiles.
        if self.rng.random() < 0.3:
            return f"{self.string(depth - 1)}.matches({self.literal(self.pick(PATTERNS))})"
        return f"{self.string(depth - 1)}.{self.pick(['startsWith', 'endsWith', 'contains'])}({self.string(depth - 1)})"

    def membership(self, depth):
        """A test of a value's membership in a derived collection, a list, or a map."""
        if self.rng.random() < 0.25:
            collection, kind, _ = self.derived(depth - 1)
            return f"{self.string(0) if kind == 'string' else self.int(0)} in {collection}"
        return self.pick(
            [
                f"{self.string(depth - 1)} in this.rs",
                f"{self.int(depth - 1)} in this.ri",
                f"{self.string(depth - 1)} in this.msi",
                f"{self.int(depth - 1)} in [1, 2, 3]",
            ]
        )

    def bool_of_value(self, kind, depth):
        """A bool of the kinds 11 to 15 of `bool`: a macro, a presence, a test of a string or of a
        double, or a type check or a conversion."""
        if kind == 11:
            return self.macro(depth)
        if kind == 12:
            return f"has({self.pick(['this.leaf', 'this.leaf.name', 'this.s', 'this.i', 'this.dur', 'this.b', 'this.msi.' + self.pick(KEYS)])})"
        if kind == 13:
            function = self.pick(
                [
                    "isEmail()",
                    "isHostname()",
                    "isIp()",
                    "isIp(4)",
                    "isIp(6)",
                    "isUri()",
                    "isUriRef()",
                    "isIpPrefix()",
                    "isHostAndPort(true)",
                ]
            )
            return f"{self.string(depth - 1)}.{function}"
        if kind == 14:
            return f"{self.double(depth - 1)}.{self.pick(['isNan()', 'isInf()', 'isInf(1)', 'isInf(-1)'])}"
        if self.rng.random() < 0.3:
            return self.type_check(depth - 1)
        return self.pick(
            [
                "this.b",
                f"bool({self.pick(['this.b', self.literal_string()])})",
                f"dyn({self.int(depth - 1)}) == {self.int(0)}",
            ]
        )

    def type_check(self, depth):
        """`type` of a value beside a type's name, or beside the type of another value."""
        values = [
            self.int(depth),
            self.uint(depth),
            self.double(depth),
            self.string(depth),
            "this.y",
            "this.rs",
            "this.msi",
            "this.leaf",
            "this.dur",
            self.timestamp(depth),
            "null",
            self.bool(0),
            "this",
        ]
        if self.rng.random() < 0.2:
            return f"type({self.pick(values)}) {self.pick(['==', '!='])} type({self.pick(values)})"
        name = self.pick(TYPE_NAMES)
        return f"type({self.pick(values)}) {self.pick(['==', '!='])} {name}"

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
        lines += [
            "",
            f"message M{index} {{",
            f'  option (buf.validate.message).cel = {{id: "r{index}", message: "m", expression: "{expression}"}};',
            FIELDS.rstrip("\n"),
            "}",
        ]
    with open(f"{out}/proto/diff/v1/diff.proto", "w") as file:
        file.write("\n".join(lines) + "\n")
    with open(f"{out}/messages.txt", "w") as file:
        file.writelines(message(rng).hex() + "\n" for _ in range(messages))


if __name__ == "__main__":
    main()
