//! The protobuf wire format: varints, zigzag, fixed-width numbers, tags and length-delimited
//! records, read through a bounds-checked `Reader` and written through a bounds-checked `Writer`
//! (https://protobuf.dev/programming-guides/encoding/). Every multi-byte fixed number is
//! little-endian ("Non-varint Numbers"), read and written byte by byte.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const group_bits = constants.protocol.varint_group_bits;
const continuation = constants.protocol.varint_continuation;
const payload_mask = constants.protocol.varint_payload_mask;

/// The six wire types of "Message Structure". 6 and 7 are not wire types.
pub const WireType = enum(u3) {
    varint = 0,
    i64 = 1,
    len = 2,
    start_group = 3,
    end_group = 4,
    i32 = 5,
    _,
};

/// What reading an encoded message can fail with. Each is a refusal of the input.
pub const Error = error{
    /// The input ended inside a field.
    Truncated,
    /// A varint ran past 10 bytes ("Base 128 Varints").
    VarintTooLong,
    /// The tag named wire type 6 or 7 ("Message Structure").
    InvalidWireType,
    /// The tag named field number 0, which no field has ("Field Numbers").
    InvalidFieldNumber,
    /// A length prefix named more bytes than the input holds.
    LengthTooLarge,
    /// An end-group tag did not match the open group, or arrived with none open.
    GroupMismatch,
    /// Messages or groups nested deeper than `constants.limits.depth_max`.
    DepthExceeded,
    /// A `string` field held bytes that are not UTF-8 (proto3 language guide, "Scalar Value Types").
    InvalidUtf8,
    /// A known field arrived with a wire type its kind cannot take.
    WireTypeMismatch,
    /// A singular message field arrived again and would merge into a message that already holds
    /// a `Repeated` view or a `Lazy` field from the first occurrence. The view names one span of
    /// bytes, so it cannot hold both occurrences' elements (docs/decisions.md entry 6).
    MergeUnsupported,
};

/// A field's tag: its number and its wire type ("Message Structure").
pub const Tag = struct {
    number: u32,
    wire_type: WireType,

    pub fn encode(tag: Tag) u64 {
        assert(tag.number != 0 and tag.number <= constants.protocol.field_number_max);
        return (@as(u64, tag.number) << constants.protocol.wire_type_bits) | @intFromEnum(tag.wire_type);
    }
};

/// Maps a signed number to an unsigned one so that small magnitudes stay short ("Signed Integers").
pub fn zigzag_encode(value: i64) u64 {
    return @bitCast((value << 1) ^ (value >> (@bitSizeOf(i64) - 1)));
}

pub fn zigzag_decode(value: u64) i64 {
    const shifted: i64 = @bitCast(value >> 1);
    const sign: i64 = -@as(i64, @intCast(value & 1));
    return shifted ^ sign;
}

/// The bytes a varint of `value` takes.
pub fn varint_len(value: u64) usize {
    const bits: usize = @bitSizeOf(u64) - @clz(value | 1);
    const len = std.math.divCeil(usize, bits, group_bits) catch unreachable;
    assert(len >= 1 and len <= constants.protocol.varint_len_max);
    return len;
}

/// Reads an encoded message's bytes. Every read checks the bound first and returns
/// `error.Truncated` when the input ends early.
pub const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn at_end(reader: *const Reader) bool {
        assert(reader.position <= reader.bytes.len);
        return reader.position == reader.bytes.len;
    }

    pub fn varint(reader: *Reader) Error!u64 {
        var value: u64 = 0;
        for (0..constants.protocol.varint_len_max) |index| {
            if (reader.position == reader.bytes.len) return error.Truncated;
            const byte = reader.bytes[reader.position];
            reader.position += 1;
            // The tenth byte carries bit 63 alone; higher bits fall off the 64-bit value, as
            // "Base 128 Varints" decodes into a 64-bit integer.
            const shift: u6 = @intCast(index * group_bits);
            value |= @as(u64, byte & payload_mask) << shift;
            if (byte & continuation == 0) return value;
        }
        // "Base 128 Varints": a varint holds at most 10 bytes.
        return error.VarintTooLong;
    }

    pub fn fixed32(reader: *Reader) Error!u32 {
        const octets = try reader.take(constants.protocol.fixed32_len);
        return std.mem.readInt(u32, octets[0..constants.protocol.fixed32_len], .little);
    }

    pub fn fixed64(reader: *Reader) Error!u64 {
        const octets = try reader.take(constants.protocol.fixed64_len);
        return std.mem.readInt(u64, octets[0..constants.protocol.fixed64_len], .little);
    }

    /// A length-delimited record's payload: a varint length, then that many bytes.
    pub fn length_delimited(reader: *Reader) Error![]const u8 {
        const len = try reader.varint();
        // "Length-Delimited Records": the length must fit in what remains.
        if (len > reader.bytes.len - reader.position) return error.LengthTooLarge;
        return reader.take(@intCast(len));
    }

    pub fn tag(reader: *Reader) Error!Tag {
        const value = try reader.varint();
        const wire_type: WireType = @enumFromInt(@as(u3, @truncate(value)));
        // "Message Structure": wire types 6 and 7 are not defined.
        if (@intFromEnum(wire_type) > @intFromEnum(WireType.i32)) return error.InvalidWireType;
        const number = value >> constants.protocol.wire_type_bits;
        // "Field Numbers": 0 is not a valid field number, and numbers stop at 2^29 - 1.
        if (number == 0 or number > constants.protocol.field_number_max) return error.InvalidFieldNumber;
        return .{ .number = @intCast(number), .wire_type = wire_type };
    }

    pub fn take(reader: *Reader, len: usize) Error![]const u8 {
        if (len > reader.bytes.len - reader.position) return error.Truncated;
        const start = reader.position;
        reader.position += len;
        return reader.bytes[start..reader.position];
    }

    /// Skips the value of a field whose tag `skipped` was just read. A group is skipped to its
    /// matching end tag, following nested groups at most `depth_left` deep.
    pub fn skip(reader: *Reader, skipped: Tag, depth_left: u32) Error!void {
        switch (skipped.wire_type) {
            .varint => _ = try reader.varint(),
            .i64 => _ = try reader.take(constants.protocol.fixed64_len),
            .i32 => _ = try reader.take(constants.protocol.fixed32_len),
            .len => _ = try reader.length_delimited(),
            .start_group => try reader.skip_group(skipped.number, depth_left),
            // "Groups": an end tag with no group open is malformed.
            .end_group => return error.GroupMismatch,
            _ => return error.InvalidWireType,
        }
    }

    /// The fields of a group whose start tag was read, up to its end tag, which it reads too
    /// ("Groups"). The end tag's own octets are where it starts, whatever their encoding.
    pub fn group_payload(reader: *Reader, number: u32, depth_left: u32) Error![]const u8 {
        if (depth_left == 0) return error.DepthExceeded;
        const start = reader.position;
        // Each field takes at least one byte, so the input's length bounds the fields.
        for (0..reader.bytes.len - reader.position + 1) |_| {
            const before = reader.position;
            const inner = try reader.tag();
            if (inner.wire_type == .end_group) {
                if (inner.number != number) return error.GroupMismatch;
                return reader.bytes[start..before];
            }
            try reader.skip(inner, depth_left - 1);
        }
        return error.Truncated;
    }

    fn skip_group(reader: *Reader, number: u32, depth_left: u32) Error!void {
        if (depth_left == 0) return error.DepthExceeded;
        // Each field takes at least one byte, so the input's length bounds the fields.
        for (0..reader.bytes.len - reader.position + 1) |_| {
            const inner = try reader.tag();
            if (inner.wire_type == .end_group) {
                // "Groups": the end tag carries the group's own field number.
                if (inner.number != number) return error.GroupMismatch;
                return;
            }
            try reader.skip(inner, depth_left - 1);
        }
        return error.Truncated;
    }
};

/// Writes an encoded message into storage the caller owns. Every write checks the room first.
pub const Writer = struct {
    buffer: []u8,
    len: usize = 0,

    pub const WriteError = error{NoSpaceLeft};

    pub fn written(writer: *const Writer) []u8 {
        return writer.buffer[0..writer.len];
    }

    pub fn bytes(writer: *Writer, octets: []const u8) WriteError!void {
        if (octets.len > writer.buffer.len - writer.len) return error.NoSpaceLeft;
        @memcpy(writer.buffer[writer.len..][0..octets.len], octets);
        writer.len += octets.len;
    }

    pub fn byte(writer: *Writer, value: u8) WriteError!void {
        if (writer.len == writer.buffer.len) return error.NoSpaceLeft;
        writer.buffer[writer.len] = value;
        writer.len += 1;
    }

    pub fn varint(writer: *Writer, value: u64) WriteError!void {
        const len = varint_len(value);
        if (len > writer.buffer.len - writer.len) return error.NoSpaceLeft;
        write_groups(writer.buffer[writer.len..][0..len], value);
        writer.len += len;
    }

    /// A placeholder of `constants.limits.padded_length_len` octets for a length written once it
    /// is known, which the writer then shrinks to fit. It holds a padded zero, a valid varint.
    pub fn padded_varint(writer: *Writer) WriteError!usize {
        const at = writer.len;
        try writer.bytes(&padded_zero);
        return at;
    }

    pub fn fixed32(writer: *Writer, value: u32) WriteError!void {
        const room = try writer.take(constants.protocol.fixed32_len);
        std.mem.writeInt(u32, room, value, .little);
    }

    pub fn fixed64(writer: *Writer, value: u64) WriteError!void {
        const room = try writer.take(constants.protocol.fixed64_len);
        std.mem.writeInt(u64, room, value, .little);
    }

    /// The next `len` bytes of the buffer, which the caller fills, or an error when they do not fit.
    fn take(writer: *Writer, comptime len: usize) WriteError!*[len]u8 {
        if (len > writer.buffer.len - writer.len) return error.NoSpaceLeft;
        const room = writer.buffer[writer.len..][0..len];
        writer.len += len;
        return room;
    }

    pub fn tag(writer: *Writer, number: u32, wire_type: WireType) WriteError!void {
        try writer.varint((Tag{ .number = number, .wire_type = wire_type }).encode());
    }
};

/// A padded varint of 0: every byte but the last carries the continuation bit alone.
const padded_zero: [constants.limits.padded_length_len]u8 = .{continuation} ** (constants.limits.padded_length_len - 1) ++ .{0};

comptime {
    assert(padded_zero.len == constants.limits.padded_length_len);
}

const testing = std.testing;

/// Writes `value` as 7-bit groups into all of `octets`, low group first, with the continuation
/// bit on every octet but the last ("Base 128 Varints"). `octets` holds every group of `value`.
fn write_groups(octets: []u8, value: u64) void {
    var rest = value;
    for (octets, 0..) |*octet, index| {
        const more: u8 = if (index + 1 < octets.len) continuation else 0;
        octet.* = @as(u8, @truncate(rest & payload_mask)) | more;
        rest >>= group_bits;
    }
    assert(rest == 0);
}

test "varints round-trip at each length boundary" {
    const values = [_]u64{ 0, 1, 127, 128, 16383, 16384, std.math.maxInt(u32), std.math.maxInt(u64) };
    const lens = [_]usize{ 1, 1, 1, 2, 2, 3, 5, 10 };
    for (values, lens) |value, len| {
        var buffer: [10]u8 = undefined;
        var writer: Writer = .{ .buffer = &buffer };
        try writer.varint(value);
        try testing.expectEqual(len, writer.len);
        var reader: Reader = .{ .bytes = writer.written() };
        try testing.expectEqual(value, try reader.varint());
        try testing.expect(reader.at_end());
    }
}

test "a varint of 11 bytes is refused, and a short one is truncated" {
    var reader: Reader = .{ .bytes = &([_]u8{0xff} ** 10 ++ [_]u8{0x01}) };
    try testing.expectError(error.VarintTooLong, reader.varint());
    var short: Reader = .{ .bytes = &.{ 0x80, 0x80 } };
    try testing.expectError(error.Truncated, short.varint());
}

test "the spec's example: 150 is 96 01, and a padded varint reads the same value" {
    var reader: Reader = .{ .bytes = &.{ 0x96, 0x01 } };
    try testing.expectEqual(@as(u64, 150), try reader.varint());
    // "Base 128 Varints": a parser accepts a varint padded with continuation groups.
    var padded: Reader = .{ .bytes = &.{ 0x96, 0x81, 0x80, 0x80, 0x00 } };
    try testing.expectEqual(@as(u64, 150), try padded.varint());
}

test "zigzag maps -1 to 1 and 1 to 2, and round-trips the extremes" {
    try testing.expectEqual(@as(u64, 1), zigzag_encode(-1));
    try testing.expectEqual(@as(u64, 2), zigzag_encode(1));
    for ([_]i64{ 0, -1, 1, std.math.minInt(i64), std.math.maxInt(i64) }) |value| {
        try testing.expectEqual(value, zigzag_decode(zigzag_encode(value)));
    }
}

test "tags refuse field number 0 and wire types 6 and 7" {
    var zero: Reader = .{ .bytes = &.{0x00} };
    try testing.expectError(error.InvalidFieldNumber, zero.tag());
    var six: Reader = .{ .bytes = &.{0x0e} };
    try testing.expectError(error.InvalidWireType, six.tag());
    var good: Reader = .{ .bytes = &.{0x08} };
    try testing.expectEqual(Tag{ .number = 1, .wire_type = .varint }, try good.tag());
}

test "a group is skipped to its end tag, and a mismatched or too deep group is refused" {
    // Field 1 group { field 2 varint 5 } end group 1, then field 3 varint 1.
    var reader: Reader = .{ .bytes = &.{ 0x0b, 0x10, 0x05, 0x0c, 0x18, 0x01 } };
    try reader.skip(try reader.tag(), constants.limits.depth_max);
    try testing.expectEqual(Tag{ .number = 3, .wire_type = .varint }, try reader.tag());
    var mismatched: Reader = .{ .bytes = &.{ 0x0b, 0x14 } };
    try testing.expectError(error.GroupMismatch, mismatched.skip(try mismatched.tag(), 4));
    var nested: Reader = .{ .bytes = &.{ 0x0b, 0x0b, 0x0c, 0x0c } };
    try testing.expectError(error.DepthExceeded, nested.skip(try nested.tag(), 1));
}

test "a length prefix past the input is refused, and writes past the buffer fail" {
    var reader: Reader = .{ .bytes = &.{ 0x05, 0x01 } };
    try testing.expectError(error.LengthTooLarge, reader.length_delimited());
    var buffer: [1]u8 = undefined;
    var writer: Writer = .{ .buffer = &buffer };
    try testing.expectError(error.NoSpaceLeft, writer.fixed32(1));
}
