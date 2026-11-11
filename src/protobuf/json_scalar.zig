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
const codec = @import("codec");
const base64 = @import("base64");
const wire = @import("wire.zig");
const descriptor = @import("descriptor.zig");
const constants = @import("constants.zig");
const json_float = @import("json_float.zig");
const Kind = descriptor.Kind;

/// What writing JSON fails with.
pub const EncodeError = json.EncodeError || wire.Error || error{
    NoSpaceLeft,
    InvalidTimestamp,
    InvalidDuration,
    InvalidFieldMask,
    /// A Value with no kind set, or a number JSON cannot hold: NaN or an infinity.
    InvalidValue,
    /// An Any whose type URL names a type the program did not declare (decision 21).
    UnknownAnyType,
};

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
    /// An Any whose "@type" names a type the program did not declare (decision 21).
    UnknownAnyType,
};

/// The longest text a 64-bit integer takes in decimal, with its sign.
const integer_text_len_max = 20;
/// The longest text `{d}` or `{e}` writes for a double.
const float_text_len_max = 32;

comptime {
    assert(float_text_len_max >= json_float.text_len_max);
}
const decimal_base = 10;
/// Below this magnitude and at or above `float_exponent_above`, a float is written with an
/// exponent, as the proto3 JSON writers of the reference implementations do.
const float_exponent_below = 1e-6;
const float_exponent_above = 1e21;

pub fn write(comptime kind: Kind, comptime V: type, value: V, text: *json.TextWriter) EncodeError!void {
    comptime assert(!kind.holds_message());
    switch (kind) {
        .int32, .sint32, .sfixed32 => try text.signed(value),
        .uint32, .fixed32 => try text.unsigned(value),
        .int64, .sint64, .sfixed64, .uint64, .fixed64 => try write_integer_string(value, text),
        .bool => try text.boolean(value),
        .float, .double => try write_float(V, value, text),
        // stdx's writer refuses a string that is not UTF-8, which a parser left unchecked where
        // utf8_validation is NONE: JSON text is UTF-8 (RFC 8259 §8.1), and Go's protojson refuses
        // it too.
        .string, .unvalidated_string => try text.string(value),
        // "JSON Mapping", bytes: standard base64 with padding, which stdx's encoder writes
        // straight into the text.
        .bytes => try text.base64(value),
        .@"enum" => try write_enum(V, value, text),
        .message, .group => unreachable,
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
    try text.number(float_text(V, value, &buffer));
}

/// The shortest text of a finite float: plain between the exponent bounds, where a value equal
/// to a short decimal takes `json_float`'s fast path, and with an exponent outside them.
fn float_text(comptime V: type, value: V, buffer: *[float_text_len_max]u8) []const u8 {
    const magnitude = @abs(value);
    const plain = magnitude == 0 or (magnitude >= float_exponent_below and magnitude < float_exponent_above);
    if (!plain) return std.fmt.bufPrint(buffer, "{e}", .{value}) catch unreachable;
    if (json_float.exact_text(V, value, buffer)) |digits| return digits;
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch unreachable;
}

/// Writes a map key as the JSON member name the mapping gives it: its decimal text, or "true".
pub fn write_key(comptime kind: Kind, comptime V: type, key: V, text: *json.TextWriter) EncodeError!void {
    var buffer: [integer_text_len_max]u8 = undefined;
    const name = switch (kind) {
        .string, .unvalidated_string => key,
        .bool => if (key) "true" else "false",
        else => std.fmt.bufPrint(&buffer, "{d}", .{key}) catch unreachable,
    };
    try text.name(name);
}

/// Reads an integer from a number or a string token. A number with an exponent or a fraction is
/// accepted when its value is integral ("JSON Mapping": "1e2" is accepted for an int32). Either
/// token must hold a JSON number (RFC 8259 §6), as Go's protojson reads it.
pub fn parse_integer(comptime V: type, octets: []const u8) DecodeError!V {
    if (parse_decimal(V, octets)) |value| return value;
    return parse_integer_general(V, octets);
}

/// The fast path of `parse_integer`: an optional "-" and 1 to `json_integer_digits_len_max`
/// decimal digits whose value `V` holds, the form JSON writers give an integer. Any other text
/// gives null, and `parse_integer_general` reads it, refusals included, so the two agree.
inline fn parse_decimal(comptime V: type, octets: []const u8) ?V {
    comptime assert(@bitSizeOf(V) <= @bitSizeOf(u64));
    const negative = octets.len != 0 and octets[0] == '-';
    const digits = octets[@intFromBool(negative)..];
    if (digits.len == 0 or digits.len > constants.limits.json_integer_digits_len_max) return null;
    // RFC 8259 §6: a leading zero is no number's, and the general path refuses it.
    if (digits[0] == '0' and digits.len > 1) return null;
    var magnitude: u64 = 0;
    for (digits) |character| {
        const digit = character -% '0';
        if (digit >= decimal_base) return null;
        magnitude = magnitude * decimal_base + digit;
    }
    if (!negative) return std.math.cast(V, magnitude);
    if (comptime @typeInfo(V).int.signedness == .unsigned) return null;
    // The magnitude of minInt(V) is maxInt(V) + 1, the most a negative value takes.
    if (magnitude > @as(u64, std.math.maxInt(V)) + 1) return null;
    const value: i64 = @bitCast(0 -% magnitude);
    return @intCast(value);
}

/// Reads any integer text the fast path leaves, as the proto3 JSON mapping and Go's protojson
/// read it: a JSON number, in a string or not, whose value is an integer once its fraction and
/// exponent apply. The digits are read exactly, with no float between. It stays out of line: a
/// JSON writer gives the fast path's form, and inlined, this path cost the varints JSON decode
/// 3% more instructions (`tools/perf_check.sh`, 2026-11-09).
noinline fn parse_integer_general(comptime V: type, octets: []const u8) DecodeError!V {
    // A number longer than any buffer could make the exponent's saturation inexact.
    if (octets.len > constants.limits.json_number_len_max) return error.InvalidNumber;
    // proto3 JSON mapping, "JSON Mapping": an integer field takes a number, or a string that
    // holds one, with exponent notation allowed. RFC 8259 §6 gives a number's form, which
    // refuses "+1", "1_000", "0x10" and "007", as Go does.
    const parts = number_parts(octets) orelse return error.InvalidNumber;
    const magnitude = try magnitude_of(parts);
    return signed_value(V, parts.negative, magnitude) orelse error.NumberOutOfRange;
}

/// A JSON number's parts (RFC 8259 §6): its sign, the digits before and after its point, and
/// its exponent, saturated at `json_exponent_magnitude_max` either way.
const NumberParts = struct {
    negative: bool,
    integer: []const u8,
    fraction: []const u8,
    exponent: i64,
};

/// Splits `octets` into a JSON number's parts, or gives null when they are none (RFC 8259 §6:
/// number = [ minus ] int [ frac ] [ exp ]).
fn number_parts(octets: []const u8) ?NumberParts {
    const negative = octets.len != 0 and octets[0] == '-';
    const integer_start: usize = @intFromBool(negative);
    const integer_end = digits_end(octets, integer_start);
    const integer = octets[integer_start..integer_end];
    // RFC 8259 §6: int = zero / ( digit1-9 *DIGIT ), so "Leading zeros are not allowed."
    if (integer.len == 0 or (integer.len > 1 and integer[0] == '0')) return null;
    var parts: NumberParts = .{ .negative = negative, .integer = integer, .fraction = "", .exponent = 0 };
    var index = integer_end;
    if (index < octets.len and octets[index] == '.') {
        const fraction_end = digits_end(octets, index + 1);
        parts.fraction = octets[index + 1 .. fraction_end];
        // RFC 8259 §6: frac = decimal-point 1*DIGIT.
        if (parts.fraction.len == 0) return null;
        index = fraction_end;
    }
    if (index == octets.len) return parts;
    // RFC 8259 §6: exp = e [ minus / plus ] 1*DIGIT, and e is "e" or "E".
    if (octets[index] != 'e' and octets[index] != 'E') return null;
    parts.exponent = exponent_of(octets[index + 1 ..]) orelse return null;
    return parts;
}

/// The index of the first octet from `start` on that is no decimal digit, or the length.
fn digits_end(octets: []const u8, start: usize) usize {
    for (octets[start..], start..) |octet, index| {
        if (!std.ascii.isDigit(octet)) return index;
    }
    return octets.len;
}

/// The exponent after "e": a sign and one digit at least (RFC 8259 §6), saturated at
/// `json_exponent_magnitude_max`, past which every value it gives is out of range or not an
/// integer alike.
fn exponent_of(text: []const u8) ?i64 {
    const signed = text.len != 0 and (text[0] == '-' or text[0] == '+');
    const digits = text[@intFromBool(signed)..];
    if (digits.len == 0) return null;
    var magnitude: i64 = 0;
    for (digits) |octet| {
        if (!std.ascii.isDigit(octet)) return null;
        magnitude = @min(magnitude * decimal_base + (octet - '0'), constants.limits.json_exponent_magnitude_max);
    }
    return if (text[0] == '-') -magnitude else magnitude;
}

/// The value of a number's digits once its exponent moves the point, exactly. A digit the point
/// leaves after it must be 0, or the number is no integer; a value past a u64 is out of range.
fn magnitude_of(parts: NumberParts) DecodeError!u64 {
    const digits_len: i64 = @intCast(parts.integer.len + parts.fraction.len);
    // The digits left of the point once the exponent moved it.
    const kept_len = @as(i64, @intCast(parts.integer.len)) + parts.exponent;
    var magnitude: u64 = 0;
    var overflow = false;
    var position: i64 = 0;
    for ([_][]const u8{ parts.integer, parts.fraction }) |digits| {
        for (digits) |octet| {
            const digit = octet - '0';
            if (position >= kept_len and digit != 0) return error.InvalidNumber;
            if (position < kept_len) overflow = overflow or !append_digit(&magnitude, digit);
            position += 1;
        }
    }
    if (overflow) return error.NumberOutOfRange;
    return scaled(magnitude, kept_len - digits_len);
}

/// `magnitude` with `zeros` zeros after its digits, or out of range past a u64.
fn scaled(magnitude: u64, zeros: i64) DecodeError!u64 {
    if (magnitude == 0 or zeros <= 0) return magnitude;
    var result = magnitude;
    // maxInt(u64) has 20 digits, so a 20th zero after a digit passes it and the loop ends.
    for (0..@intCast(zeros)) |_| {
        if (!append_digit(&result, 0)) return error.NumberOutOfRange;
    }
    return result;
}

/// Appends one decimal digit to `magnitude`, and says whether the value still fits a u64.
fn append_digit(magnitude: *u64, digit: u8) bool {
    const shifted = @mulWithOverflow(magnitude.*, decimal_base);
    const sum = @addWithOverflow(shifted[0], digit);
    magnitude.* = sum[0];
    return shifted[1] == 0 and sum[1] == 0;
}

/// The value of `V` that a sign and a magnitude give, or null out of its range.
fn signed_value(comptime V: type, negative: bool, magnitude: u64) ?V {
    if (!negative or magnitude == 0) return std.math.cast(V, magnitude);
    if (comptime @typeInfo(V).int.signedness == .unsigned) return null;
    // The magnitude of minInt(V) is maxInt(V) + 1, the most a negative value takes.
    if (magnitude > @as(u64, std.math.maxInt(V)) + 1) return null;
    const value: i64 = @bitCast(0 -% magnitude);
    return @intCast(value);
}

pub fn parse_float(comptime V: type, octets: []const u8, from_string: bool) DecodeError!V {
    if (from_string) {
        if (std.mem.eql(u8, octets, "NaN")) return std.math.nan(V);
        if (std.mem.eql(u8, octets, "Infinity")) return std.math.inf(V);
        if (std.mem.eql(u8, octets, "-Infinity")) return -std.math.inf(V);
    }
    if (json_float.parse_exact(V, octets)) |value| return value;
    // Parsing straight into `V` rounds the text once. Through f64 it would round twice, and a
    // text such as float's maximum, 3.4028235e38, lies above floatMax(f32) as an f64.
    const value = std.fmt.parseFloat(V, octets) catch return error.InvalidNumber;
    // "JSON Mapping": a value out of the type's range is refused, not rounded to infinity.
    if (std.math.isInf(value)) return error.NumberOutOfRange;
    return value;
}

/// The octets base64 text decodes to, written into `writer` after their length, in standard or
/// URL-safe base64, with or without padding ("JSON Mapping", bytes).
pub fn write_base64_field(octets: []const u8, writer: *wire.Writer) DecodeError!void {
    // The length and the pad characters give the octets' count, so the length goes first.
    const len = base64.Decoder.decoded_len(octets) catch return error.InvalidBase64;
    try writer.varint(len);
    if (len > writer.buffer.len - writer.len) return error.NoSpaceLeft;
    // "JSON Mapping", bytes: a parser accepts either alphabet, but one alone in a text (RFC 4648
    // §5), with or without padding. The decoder takes the free room after the length, whose slack
    // its vector step uses, and writes `len` octets.
    var decoder: base64.Decoder = undefined;
    decoder.init(.{ .accept = .either, .padding = .optional }, codec.Features.target());
    const decoded_len = decoder.decode_all(octets, writer.buffer[writer.len..]) catch return error.InvalidBase64;
    assert(decoded_len == len);
    writer.len += len;
}

const testing = std.testing;

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

test "bytes are padded standard base64" {
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
    // The digits are read exactly, as Go reads them: no f64 rounds them to 2^63 or 2^64.
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try parse_integer(i64, "9.223372036854775807e18"));
    try testing.expectError(error.InvalidNumber, parse_integer(i64, "9223372036854775807.5"));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), try parse_integer(u64, "1.8446744073709551615e19"));
    try testing.expectError(error.NumberOutOfRange, parse_integer(u64, "1.8446744073709551616e19"));
    try testing.expectEqual(@as(i64, 9007199254740993), try parse_integer(i64, "9007199254740993e0"));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try parse_integer(i64, "-9.223372036854775808e18"));
    try testing.expectError(error.NumberOutOfRange, parse_float(f32, "1e39", false));
    // float's maximum as Go and Java write it rounds to floatMax(f32), so it is in range.
    try testing.expectEqual(std.math.floatMax(f32), try parse_float(f32, "3.4028235e38", false));
    // Just above the midpoint of 1 and the next float: one rounding goes up. Through f64 the
    // text first rounds to the midpoint itself, which then rounds to even, down to 1.
    try testing.expectEqual(@as(f32, 1.00000011920928955078125), try parse_float(f32, "1.0000000596046447753906251", false));
    try testing.expect(std.math.isNan(try parse_float(f64, "NaN", true)));
}

test "an integer text that is no JSON number is refused, as Go's protojson refuses it" {
    // RFC 8259 §6: no "+" before a number, no separator, no base but ten, no leading zero, a
    // digit on each side of a point, and one in an exponent. Go 1.24's protojson, with
    // google.golang.org/protobuf v1.36.12, refused each in a string and as a number.
    const refused = [_][]const u8{ "+1", "1_000", "0x10", "007", "00", "-00", "01.0", "00.5", "1.", ".5", "1e", "1e+", "-", "", " 1", "1a", "0b1", "Infinity", "NaN" };
    for (refused) |text| try testing.expectError(error.InvalidNumber, parse_integer(i32, text));
    // Go accepted each of these, and gives the same value.
    try testing.expectEqual(@as(i32, 0), try parse_integer(i32, "-0"));
    try testing.expectEqual(@as(u64, 0), try parse_integer(u64, "-0.0"));
    try testing.expectEqual(@as(i32, 1), try parse_integer(i32, "1.0"));
    try testing.expectEqual(@as(i32, 1), try parse_integer(i32, "10e-1"));
    try testing.expectEqual(@as(i32, 1), try parse_integer(i32, "100e-2"));
    try testing.expectEqual(@as(i32, 100), try parse_integer(i32, "1E+2"));
    try testing.expectEqual(@as(i32, 100), try parse_integer(i32, "1.00e2"));
    try testing.expectEqual(@as(i32, 0), try parse_integer(i32, "0e5"));
    try testing.expectError(error.InvalidNumber, parse_integer(i32, "1e-2"));
    try testing.expectError(error.InvalidNumber, parse_integer(i32, "-0.5"));
    try testing.expectError(error.NumberOutOfRange, parse_integer(u64, "-1e2"));
    // An exponent past any buffer saturates, and the value stays exact: 0, or out of range.
    try testing.expectEqual(@as(i32, 0), try parse_integer(i32, "0e99999999999"));
    try testing.expectError(error.NumberOutOfRange, parse_integer(i32, "1e99999999999"));
    try testing.expectError(error.InvalidNumber, parse_integer(i32, "1e-99999999999"));
    try testing.expectError(error.NumberOutOfRange, parse_integer(i32, "1e99999999999999999999999"));
    try testing.expectError(error.InvalidNumber, parse_integer(i32, "1e-99999999999999999999999"));
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
    // A text that mixes the alphabets is neither.
    var mixed: wire.Writer = .{ .buffer = &buffer };
    try testing.expectError(error.InvalidBase64, write_base64_field("+_8=", &mixed));
}

test "bytes of each length write the base64 that std.base64 writes, and read back" {
    var octets: [200]u8 = undefined;
    for (&octets, 0..) |*octet, index| octet.* = @truncate(index * 7);
    // Short and long lengths, with each remainder of 3 among them.
    for ([_]usize{ 0, 1, 44, 45, 46, 90, 91, 200 }) |len| {
        var buffer: [300]u8 = undefined;
        const text = try written(.bytes, []const u8, octets[0..len], &buffer);
        var reference: [300]u8 = undefined;
        const want = std.base64.standard.Encoder.encode(&reference, octets[0..len]);
        try testing.expectEqualStrings(want, text[1 .. text.len - 1]);
        var room: [300]u8 = undefined;
        var writer: wire.Writer = .{ .buffer = &room };
        try write_base64_field(want, &writer);
        try testing.expectEqualSlices(u8, octets[0..len], writer.written()[writer.written().len - len ..]);
    }
}
