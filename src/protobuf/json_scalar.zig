//! One scalar value in proto3 JSON, written through stdx's `json.TextWriter` and read from the
//! tokens of its `json.TextReader` (proto3 JSON mapping, "JSON Mapping" table).
//!
//! - int32, uint32 and their fixed and zigzag kinds are JSON numbers; the 64-bit kinds are
//!   strings, and a parser accepts either form for each.
//! - float and double are numbers, or the strings "NaN", "Infinity" and "-Infinity".
//! - bytes are standard base64 with padding; a parser accepts the URL-safe alphabet and no padding.
//! - an enum is its value's name, or its number when it has no name.
const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const wire = @import("wire.zig");
const descriptor = @import("descriptor.zig");
const Kind = descriptor.Kind;

/// What writing JSON fails with.
pub const EncodeError = json.EncodeError || wire.Error || error{ NoSpaceLeft, Unsupported, InvalidTimestamp, InvalidDuration, InvalidFieldMask };

/// What reading JSON refuses a text with, or fails with for want of room.
pub const DecodeError = json.DecodeError || error{ Truncated, NoSpaceLeft } || wire.Error || error{
    /// A token the mapping does not allow where it stands.
    UnexpectedToken,
    /// A member that names no field. The mapping lets a parser refuse it by default.
    UnknownField,
    InvalidNumber,
    NumberOutOfRange,
    /// A name the enum does not have.
    InvalidEnum,
    InvalidBase64,
    InvalidTimestamp,
    InvalidDuration,
    InvalidFieldMask,
    /// A JSON form this version does not read: Any, Struct, Value and ListValue (design §5).
    Unsupported,
};

/// The longest text a 64-bit integer takes in decimal, with its sign.
const integer_text_len_max = 20;
/// The longest text `{d}` or `{e}` writes for a double.
const float_text_len_max = 32;
/// The base64 octets one piece of a bytes field writes: 4 for each 3 input octets, and under one
/// cache line, so the staging buffer costs a few stores a call.
const base64_piece_len = 60;
/// Base64 writes 4 characters for each 3 octets (RFC 4648 §4).
const base64_chars = 4;
const base64_octets = 3;
const decimal_base = 10;
/// Below this magnitude and at or above `float_exponent_above`, a float is written with an
/// exponent, as the proto3 JSON writers of the reference implementations do.
const float_exponent_below = 1e-6;
const float_exponent_above = 1e21;

pub fn write(comptime kind: Kind, comptime V: type, value: V, text: *json.TextWriter) EncodeError!void {
    comptime assert(kind != .message);
    switch (kind) {
        .int32, .sint32, .sfixed32 => try text.signed(value),
        .uint32, .fixed32 => try text.unsigned(value),
        .int64, .sint64, .sfixed64, .uint64, .fixed64 => try write_integer_string(value, text),
        .bool => try text.boolean(value),
        .float, .double => try write_float(V, value, text),
        .string => try text.string(value),
        .bytes => try write_base64(value, text),
        .@"enum" => try write_enum(V, value, text),
        .message => unreachable,
    }
}

fn write_integer_string(value: anytype, text: *json.TextWriter) EncodeError!void {
    var buffer: [integer_text_len_max]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try text.string(digits);
}

fn write_enum(comptime V: type, value: V, text: *json.TextWriter) EncodeError!void {
    // The JSON mapping writes NullValue's one value as the literal null.
    if (comptime std.mem.eql(u8, V.protobuf.full_name, "google.protobuf.NullValue")) return text.null_literal();
    const name = V.protobuf.name_of(@intFromEnum(value)) orelse return text.signed(@intFromEnum(value));
    try text.string(name);
}

pub fn write_float(comptime V: type, value: V, text: *json.TextWriter) EncodeError!void {
    if (std.math.isNan(value)) return text.string("NaN");
    if (std.math.isInf(value)) return text.string(if (value > 0) "Infinity" else "-Infinity");
    var buffer: [float_text_len_max]u8 = undefined;
    const magnitude = @abs(value);
    const plain = magnitude == 0 or (magnitude >= float_exponent_below and magnitude < float_exponent_above);
    const digits = if (plain)
        std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable
    else
        std.fmt.bufPrint(&buffer, "{e}", .{value}) catch unreachable;
    try text.number(digits);
}

/// Writes `octets` as one string of standard base64 with padding, in pieces.
pub fn write_base64(octets: []const u8, text: *json.TextWriter) EncodeError!void {
    const encoder = std.base64.standard.Encoder;
    const chunk_len = base64_piece_len / base64_chars * base64_octets;
    var buffer: [base64_piece_len]u8 = undefined;
    var start: usize = 0;
    for (0..octets.len / chunk_len + 1) |_| {
        const end = @min(start + chunk_len, octets.len);
        const piece = encoder.encode(&buffer, octets[start..end]);
        const last = end == octets.len;
        try text.write(.{ .string = if (last) .last else .more }, piece);
        if (last) return;
        start = end;
    }
    unreachable;
}

/// Writes a map key as the JSON member name the mapping gives it: its decimal text, or "true".
pub fn write_key(comptime kind: Kind, comptime V: type, key: V, text: *json.TextWriter) EncodeError!void {
    var buffer: [integer_text_len_max]u8 = undefined;
    const name = switch (kind) {
        .string => key,
        .bool => if (key) "true" else "false",
        else => std.fmt.bufPrint(&buffer, "{d}", .{key}) catch unreachable,
    };
    try text.name(name);
}

/// Reads an integer from a number or a string token. A number with an exponent or a fraction is
/// accepted when its value is integral ("JSON Mapping": "1e2" is accepted for an int32).
pub fn parse_integer(comptime V: type, octets: []const u8) DecodeError!V {
    if (std.fmt.parseInt(V, octets, decimal_base)) |value| return value else |failure| switch (failure) {
        error.Overflow => return error.NumberOutOfRange,
        error.InvalidCharacter => {},
    }
    const float = std.fmt.parseFloat(f64, octets) catch return error.InvalidNumber;
    if (@trunc(float) != float) return error.InvalidNumber;
    const low: f64 = @floatFromInt(std.math.minInt(V));
    // maxInt of a 64-bit type rounds up to a power of two as an f64, so the bound is that power,
    // exclusive: 2^63 itself must be refused, or the conversion below overflows.
    const bits_below: i32 = @bitSizeOf(V) - @as(i32, @intFromBool(@typeInfo(V).int.signedness == .signed));
    const high_exclusive = std.math.ldexp(@as(f64, 1), bits_below);
    if (float < low or float >= high_exclusive) return error.NumberOutOfRange;
    return @intFromFloat(float);
}

pub fn parse_float(comptime V: type, octets: []const u8, from_string: bool) DecodeError!V {
    if (from_string) {
        if (std.mem.eql(u8, octets, "NaN")) return std.math.nan(V);
        if (std.mem.eql(u8, octets, "Infinity")) return std.math.inf(V);
        if (std.mem.eql(u8, octets, "-Infinity")) return -std.math.inf(V);
    }
    const value = std.fmt.parseFloat(f64, octets) catch return error.InvalidNumber;
    // "JSON Mapping": a value out of the type's range is refused, not rounded to infinity.
    if (std.math.isInf(value)) return error.NumberOutOfRange;
    if (V == f32 and @abs(value) > std.math.floatMax(f32)) return error.NumberOutOfRange;
    return @floatCast(value);
}

/// The octets base64 text decodes to, written into `writer` after their length, in standard or
/// URL-safe base64, with or without padding ("JSON Mapping", bytes).
pub fn write_base64_field(octets: []const u8, writer: *wire.Writer) DecodeError!void {
    const url_safe = std.mem.indexOfAny(u8, octets, "-_") != null;
    const padded = octets.len % base64_chars == 0 and octets.len != 0 and octets[octets.len - 1] == '=';
    const decoder = if (url_safe)
        (if (padded) std.base64.url_safe.Decoder else std.base64.url_safe_no_pad.Decoder)
    else
        (if (padded) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder);
    const len = decoder.calcSizeForSlice(octets) catch return error.InvalidBase64;
    try writer.varint(len);
    if (len > writer.buffer.len - writer.len) return error.NoSpaceLeft;
    decoder.decode(writer.buffer[writer.len..][0..len], octets) catch return error.InvalidBase64;
    writer.len += len;
}

const testing = std.testing;
const codec = @import("codec");

fn written(comptime kind: Kind, comptime V: type, value: V, buffer: []u8) ![]const u8 {
    var text = json.TextWriter.init(buffer, .text, codec.Features.target());
    try write(kind, V, value, &text);
    return text.written();
}

test "64-bit integers are strings, floats use exponents only at the extremes" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("\"-9\"", try written(.int64, i64, -9, &buffer));
    try testing.expectEqualStrings("7", try written(.uint32, u32, 7, &buffer));
    try testing.expectEqualStrings("0.1", try written(.double, f64, 0.1, &buffer));
    try testing.expectEqualStrings("1e300", try written(.double, f64, 1e300, &buffer));
    try testing.expectEqualStrings("\"-Infinity\"", try written(.float, f32, -std.math.inf(f32), &buffer));
}

test "bytes are padded standard base64, written across pieces" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("\"AP8=\"", try written(.bytes, []const u8, &.{ 0, 255 }, &buffer));
    const long = [_]u8{'a'} ** 100;
    const text = try written(.bytes, []const u8, &long, &buffer);
    try testing.expectEqual(@as(usize, 2 + 136), text.len);
}

test "integers parse from exponents when integral, and refuse fractions and overflow" {
    try testing.expectEqual(@as(i32, 100), try parse_integer(i32, "1e2"));
    try testing.expectError(error.InvalidNumber, parse_integer(i32, "1.5"));
    try testing.expectError(error.NumberOutOfRange, parse_integer(i32, "2147483648"));
    // Each text is integral and rounds to 2^63 or 2^64 as an f64: one past the type's range.
    try testing.expectError(error.NumberOutOfRange, parse_integer(i64, "9.223372036854775807e18"));
    try testing.expectError(error.NumberOutOfRange, parse_integer(i64, "9223372036854775807.5"));
    try testing.expectError(error.NumberOutOfRange, parse_integer(u64, "1.8446744073709551615e19"));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try parse_integer(i64, "-9.223372036854775808e18"));
    try testing.expectError(error.NumberOutOfRange, parse_float(f32, "1e39", false));
    try testing.expect(std.math.isNan(try parse_float(f64, "NaN", true)));
}

test "base64 decodes in either alphabet, padded or not" {
    var buffer: [16]u8 = undefined;
    for ([_][]const u8{ "AP8=", "AP8", "_w==", "_w" }, [_][]const u8{ &.{ 0, 255 }, &.{ 0, 255 }, &.{255}, &.{255} }) |input, want| {
        var writer: wire.Writer = .{ .buffer = &buffer };
        try write_base64_field(input, &writer);
        try testing.expectEqualSlices(u8, want, writer.written()[1..]);
    }
    var writer: wire.Writer = .{ .buffer = &buffer };
    try testing.expectError(error.InvalidBase64, write_base64_field("A!", &writer));
}
