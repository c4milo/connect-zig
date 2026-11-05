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
const Kind = descriptor.Kind;

/// Reads one value of `kind` as `V`. The caller checked the wire type.
pub fn read(comptime kind: Kind, comptime V: type, reader: *wire.Reader) wire.Error!V {
    comptime assert(!kind.holds_message());
    return switch (kind) {
        // "Base 128 Varints": int32 is sign-extended to 64 bits on the wire, so its value is the
        // low 32 bits. uint32 keeps the low 32 bits as well.
        .int32 => @bitCast(@as(u32, @truncate(try reader.varint()))),
        .uint32 => @truncate(try reader.varint()),
        .int64 => @bitCast(try reader.varint()),
        .uint64 => try reader.varint(),
        // Encoding guide, "Signed Integers": a sint32 decodes from the low 32 bits.
        .sint32 => @intCast(wire.zigzag_decode(@as(u32, @truncate(try reader.varint())))),
        .sint64 => wire.zigzag_decode(try reader.varint()),
        .bool => (try reader.varint()) != 0,
        .@"enum" => @enumFromInt(@as(i32, @bitCast(@as(u32, @truncate(try reader.varint()))))),
        .fixed32 => try reader.fixed32(),
        .sfixed32 => @bitCast(try reader.fixed32()),
        .float => @bitCast(try reader.fixed32()),
        .fixed64 => try reader.fixed64(),
        .sfixed64 => @bitCast(try reader.fixed64()),
        .double => @bitCast(try reader.fixed64()),
        .bytes => try reader.length_delimited(),
        .string => try read_string(reader),
        .message, .group => unreachable,
    };
}

fn read_string(reader: *wire.Reader) wire.Error![]const u8 {
    const octets = try reader.length_delimited();
    // Language guide, "Scalar Value Types": a string must always contain UTF-8.
    if (!std.unicode.utf8ValidateSlice(octets)) return error.InvalidUtf8;
    return octets;
}

/// The integer a varint kind writes for `value`.
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
pub fn write(comptime kind: Kind, comptime V: type, value: V, writer: *wire.Writer) wire.Writer.WriteError!void {
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

test "defaults: +0.0 is default and -0.0 is not" {
    try testing.expect(is_default(f64, 0.0));
    try testing.expect(!is_default(f64, -0.0));
    try testing.expect(is_default([]const u8, ""));
    try testing.expect(!is_default(i32, -1));
}
