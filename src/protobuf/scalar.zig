//! One value of a scalar kind, read from and written to the wire, and its length. The Zig type
//! of each kind follows the language guide's table ("Scalar Value Types"): int32, sint32 and
//! sfixed32 are `i32`; uint32 and fixed32 are `u32`; the 64-bit kinds likewise; float is `f32`,
//! double `f64`, bool `bool`, string and bytes `[]const u8`, and an enum its generated
//! non-exhaustive `enum(i32)`.
const std = @import("std");
const assert = std.debug.assert;
const wire = @import("wire.zig");
const descriptor = @import("descriptor.zig");
const constants = @import("constants.zig");
const json = @import("json");
const codec = @import("codec");
const Kind = descriptor.Kind;

/// Reads one value of `kind` as `V`. The caller checked the wire type.
pub fn read(comptime kind: Kind, comptime V: type, reader: *wire.Reader) wire.Error!V {
    comptime assert(!kind.holds_message());
    return switch (kind) {
        .int32, .uint32, .int64, .uint64, .sint32, .sint64, .bool, .@"enum" => from_varint(kind, V, try reader.varint()),
        .fixed32 => try reader.fixed32(),
        .sfixed32 => @bitCast(try reader.fixed32()),
        .float => @bitCast(try reader.fixed32()),
        .fixed64 => try reader.fixed64(),
        .sfixed64 => @bitCast(try reader.fixed64()),
        .double => @bitCast(try reader.fixed64()),
        .bytes => try reader.length_delimited(),
        .string => try read_string(reader),
        // Editions, "utf8_validation": NONE leaves the octets unchecked.
        .unvalidated_string => try reader.length_delimited(),
        .message, .group => unreachable,
    };
}

fn read_string(reader: *wire.Reader) wire.Error![]const u8 {
    const octets = try reader.length_delimited();
    // Language guide, "Scalar Value Types": a string must always contain UTF-8.
    if (!is_utf8(octets)) return error.InvalidUtf8;
    return octets;
}

/// Whether `octets` is UTF-8 (RFC 3629 §4): stdx's vector check for a long string. A short one,
/// where the vector path costs more than it saves, is checked for ASCII a word at a time, and
/// only text that is not ASCII goes to the standard library's check.
pub fn is_utf8(octets: []const u8) bool {
    if (octets.len < constants.limits.utf8_vector_len_min) {
        if (is_ascii_short(octets)) return true;
        return std.unicode.utf8ValidateSlice(octets);
    }
    return json.is_utf8(octets, codec.Features.target());
}

/// The bit no ASCII octet sets: an octet below 0x80 is a character alone (RFC 3629 §3).
const ascii_high_bit: u8 = 0x80;
/// That bit in each octet of a word.
const ascii_high_bits: u64 = std.mem.readInt(u64, &@as([@sizeOf(u64)]u8, @splat(ascii_high_bit)), .little);

/// Whether a string shorter than the vector cutoff is ASCII, which is UTF-8 (RFC 3629 §3). It ORs
/// the string's words, the last one overlapping the one before it, or its octets when it is
/// shorter than a word, and tests the high bit of each octet once.
fn is_ascii_short(octets: []const u8) bool {
    assert(octets.len < constants.limits.utf8_vector_len_min);
    const word_len = @sizeOf(u64);
    if (octets.len < word_len) {
        var high: u8 = 0;
        for (octets) |octet| high |= octet;
        return high & ascii_high_bit == 0;
    }
    var high: u64 = std.mem.readInt(u64, octets[octets.len - word_len ..][0..word_len], .little);
    for (0..octets.len / word_len) |index| high |= std.mem.readInt(u64, octets[index * word_len ..][0..word_len], .little);
    return high & ascii_high_bits == 0;
}

/// The integer a varint kind writes for `value`.
/// The value a varint of `kind` holds: the inverse of `varint_of`.
pub inline fn from_varint(comptime kind: Kind, comptime V: type, varint: u64) V {
    return switch (kind) {
        // "Base 128 Varints": int32 is sign-extended to 64 bits on the wire, so its value is the
        // low 32 bits. uint32 keeps the low 32 bits as well.
        .int32 => @bitCast(@as(u32, @truncate(varint))),
        .uint32 => @truncate(varint),
        .int64 => @bitCast(varint),
        .uint64 => varint,
        // Encoding guide, "Signed Integers": a sint32 decodes from the low 32 bits.
        .sint32 => @intCast(wire.zigzag_decode(@as(u32, @truncate(varint)))),
        .sint64 => wire.zigzag_decode(varint),
        .bool => varint != 0,
        .@"enum" => @enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(varint))))),
        else => unreachable,
    };
}

fn varint_of(comptime kind: Kind, comptime V: type, value: V) u64 {
    return switch (kind) {
        .int32 => @bitCast(@as(i64, value)),
        .int64 => @bitCast(value),
        .uint32, .uint64 => value,
        // Zigzag of an i32 widened to i64 equals its 32-bit zigzag, so one function serves both.
        .sint32, .sint64 => wire.zigzag_encode(value),
        .bool => @intFromBool(value),
        .@"enum" => @bitCast(@as(i64, @intFromEnum(value))),
        else => unreachable,
    };
}

/// Writes one value of `kind`, without its tag.
pub inline fn write(comptime kind: Kind, comptime V: type, value: V, writer: *wire.Writer) wire.Writer.WriteError!void {
    comptime assert(!kind.holds_message());
    switch (comptime kind.wire_type()) {
        .varint => try writer.varint(varint_of(kind, V, value)),
        .i32 => try writer.fixed32(@bitCast(value)),
        .i64 => try writer.fixed64(@bitCast(value)),
        .len => {
            try writer.varint(value.len);
            try writer.bytes(value);
        },
        else => unreachable,
    }
}

/// Writes one value as `write` does, a number's varint with `Writer.varint_wide`: binary
/// encode's form. A string's length keeps `varint`, since it nearly always takes one octet.
pub inline fn write_wide(comptime kind: Kind, comptime V: type, value: V, writer: *wire.Writer) wire.Writer.WriteError!void {
    comptime assert(!kind.holds_message());
    if (comptime kind.wire_type() == .varint) return writer.varint_wide(varint_of(kind, V, value));
    return write(kind, V, value, writer);
}

/// The bytes `write` takes for `value`.
pub fn len(comptime kind: Kind, comptime V: type, value: V) usize {
    return switch (comptime kind.wire_type()) {
        .varint => wire.varint_len(varint_of(kind, V, value)),
        .i32 => constants.protocol.fixed32_len,
        .i64 => constants.protocol.fixed64_len,
        .len => wire.varint_len(value.len) + value.len,
        else => unreachable,
    };
}

/// Whether an implicit-presence field holds its default and is left off the wire (proto3
/// language guide, "Default Values"). A float is default only at +0.0, so -0.0 is written.
pub fn is_default(comptime V: type, value: V) bool {
    return switch (@typeInfo(V)) {
        .int => value == 0,
        .bool => !value,
        .float => @as(std.meta.Int(.unsigned, @bitSizeOf(V)), @bitCast(value)) == 0,
        .@"enum" => @intFromEnum(value) == 0,
        .pointer => value.len == 0,
        else => @compileError("no default for " ++ @typeName(V)),
    };
}

const testing = std.testing;

test "a negative int32 takes ten bytes and reads back" {
    var buffer: [16]u8 = undefined;
    var writer: wire.Writer = .{ .buffer = &buffer };
    try write(.int32, i32, -1, &writer);
    try testing.expectEqual(@as(usize, 10), writer.len);
    try testing.expectEqual(@as(usize, 10), len(.int32, i32, -1));
    var reader: wire.Reader = .{ .bytes = writer.written() };
    try testing.expectEqual(@as(i32, -1), try read(.int32, i32, &reader));
}

test "sint32 zigzags, and a string that is not UTF-8 is refused" {
    var buffer: [16]u8 = undefined;
    var writer: wire.Writer = .{ .buffer = &buffer };
    try write(.sint32, i32, -2, &writer);
    try testing.expectEqualSlices(u8, &.{0x03}, writer.written());
    var reader: wire.Reader = .{ .bytes = writer.written() };
    try testing.expectEqual(@as(i32, -2), try read(.sint32, i32, &reader));
    // A sint32 decodes from the varint's low 32 bits, whatever the bits above them hold.
    var wide_writer: wire.Writer = .{ .buffer = &buffer };
    // Bit 32 shifts into bit 31 if zigzag ran before the truncation.
    const high_bits: u64 = 1 << 32;
    try wide_writer.varint(high_bits | 0x03);
    var wide: wire.Reader = .{ .bytes = wide_writer.written() };
    try testing.expectEqual(@as(i32, -2), try read(.sint32, i32, &wide));
    var bad: wire.Reader = .{ .bytes = &.{ 0x01, 0xff } };
    try testing.expectError(error.InvalidUtf8, read(.string, []const u8, &bad));
}

test "a string is checked as UTF-8 on both paths, short and long" {
    const long_len = constants.limits.utf8_vector_len_min * 4;
    var text: [long_len]u8 = @splat('a');
    // "ñ" in the middle of a long string, and in a short one.
    text[long_len / 2] = 0xc3;
    text[long_len / 2 + 1] = 0xb1;
    try testing.expect(is_utf8(&text));
    try testing.expect(is_utf8(text[long_len / 2 - 1 ..][0..4]));
    // A lone continuation octet fails both.
    text[long_len / 2] = 0xb1;
    try testing.expect(!is_utf8(&text));
    try testing.expect(!is_utf8(text[long_len / 2 - 1 ..][0..4]));
    // An overlong form, which UTF-8 forbids (RFC 3629 §3), fails the long path too.
    text[long_len - 2] = 0xc0;
    text[long_len - 1] = 0x80;
    try testing.expect(!is_utf8(text[long_len - constants.limits.utf8_vector_len_min ..]));
}

test "defaults: +0.0 is default and -0.0 is not" {
    try testing.expect(is_default(f64, 0.0));
    try testing.expect(!is_default(f64, -0.0));
    try testing.expect(is_default([]const u8, ""));
    try testing.expect(!is_default(i32, -1));
}

test "a short string is ASCII exactly when no octet sets the high bit, wherever that octet is" {
    var text: [constants.limits.utf8_vector_len_min - 1]u8 = @splat(0x7f);
    for (0..text.len + 1) |text_len| {
        try testing.expect(is_ascii_short(text[0..text_len]));
        for (0..text_len) |place| {
            text[place] = 0x80;
            try testing.expect(!is_ascii_short(text[0..text_len]));
            text[place] = 0xff;
            try testing.expect(!is_ascii_short(text[0..text_len]));
            text[place] = 0x7f;
        }
    }
}
