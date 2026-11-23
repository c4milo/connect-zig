"""The random messages of tools/cel_differential/generate.py, in protobuf's binary encoding."""

import struct

from generate_values import INTS, LONGS, STRINGS, UINTS, ULONGS


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
        out += tag(7, 1) + struct.pack(
            "<d", rng.choice([0.0, 1.5, -2.25, 100.0, 1e300, float("inf"), float("-inf"), float("nan")])
        )
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
        out += delimited(
            13,
            tag(1, 0) + varint(rng.choice([0, 1, 5, 90, 3600, -3])) + tag(2, 0) + varint(rng.choice([0, 0, 500000000])),
        )
    if maybe():
        out += delimited(14, delimited(1, rng.choice(STRINGS).encode()) + tag(2, 0) + varint(rng.choice(INTS)))
    return bytes(out)
