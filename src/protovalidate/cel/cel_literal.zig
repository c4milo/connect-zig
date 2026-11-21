//! The value of a CEL literal's text: a number, or a string's or a bytes literal's octets with
//! each escape sequence read (CEL language definition, "Syntax" and "String and Bytes Values").
const std = @import("std");
const constants = @import("../constants.zig");

pub const Error = error{Literal};

/// An INT_LIT's magnitude: decimal, or hexadecimal after "0x".
pub fn magnitude(text: []const u8) Error!u64 {
    const hexadecimal = std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X");
    const digits = if (hexadecimal) text["0x".len..] else text;
    if (digits.len == 0) return error.Literal;
    return std.fmt.parseInt(u64, digits, if (hexadecimal) constants.hexadecimal_base else constants.decimal_base) catch error.Literal;
}

pub fn double(text: []const u8) Error!f64 {
    return std.fmt.parseFloat(f64, text) catch error.Literal;
}

/// The octets a string or bytes literal states, written into `out`, which holds at least the
/// literal's own length: an escape is never shorter than what it states. `text` has its prefix
/// and its quotes. In a string an escape of a number states a code point, and in a bytes
/// literal an octet.
pub fn unescape(text: []const u8, out: []u8) Error![]const u8 {
    const quote_at = std.mem.indexOfAny(u8, text, "\"'") orelse return error.Literal;
    const prefix = text[0..quote_at];
    const raw = std.mem.indexOfAny(u8, prefix, "rR") != null;
    const octets = std.mem.indexOfAny(u8, prefix, "bB") != null;
    const body = text[quote_at + 1 .. text.len - 1];
    if (raw) {
        @memcpy(out[0..body.len], body);
        return out[0..body.len];
    }
    var read: usize = 0;
    var written: usize = 0;
    for (0..body.len) |_| {
        if (read == body.len) break;
        if (body[read] != '\\') {
            out[written] = body[read];
            read += 1;
            written += 1;
            continue;
        }
        const escape = try read_escape(body[read..], octets);
        written += write_escape(escape, octets, out[written..]);
        read += escape.len;
    }
    return out[0..written];
}

const Escape = struct {
    /// The octets of the escape sequence, with its backslash.
    len: usize,
    /// The octet or the code point it states.
    value: u21,
    /// Whether the escape states a number, which a string reads as a code point.
    numbered: bool = false,
};

fn read_escape(rest: []const u8, octets: bool) Error!Escape {
    if (rest.len < constants.cel_escape_len_min) return error.Literal;
    const simple = "abfnrtv\\?\"'`";
    const values = "\x07\x08\x0c\n\r\t\x0b\\?\"'`";
    if (std.mem.indexOfScalar(u8, simple, rest[1])) |index| return .{ .len = constants.cel_escape_len_min, .value = values[index] };
    return switch (rest[1]) {
        'x', 'X' => numbered(rest, constants.cel_escape_len_min, constants.pct_encoded_digits, constants.hexadecimal_base),
        // "\u" and "\U" state a code point, which a bytes literal does not hold.
        'u' => if (octets) error.Literal else numbered(rest, constants.cel_escape_len_min, constants.cel_escape_u_digits, constants.hexadecimal_base),
        'U' => if (octets) error.Literal else numbered(rest, constants.cel_escape_len_min, constants.cel_escape_long_u_digits, constants.hexadecimal_base),
        '0'...'3' => numbered(rest, 1, constants.cel_escape_octal_digits, constants.octal_base),
        else => error.Literal,
    };
}

/// An escape of `digits` digits in `base`, which start `skip` octets into `rest`.
fn numbered(rest: []const u8, skip: usize, digits: usize, base: u8) Error!Escape {
    if (rest.len < skip + digits) return error.Literal;
    const value = std.fmt.parseInt(u21, rest[skip..][0..digits], base) catch return error.Literal;
    return .{ .len = skip + digits, .value = value, .numbered = true };
}

fn write_escape(escape: Escape, octets: bool, out: []u8) usize {
    if (octets or !escape.numbered) {
        out[0] = @truncate(escape.value);
        return 1;
    }
    // A code point no UTF-8 holds, such as a surrogate, reads as U+FFFD.
    return std.unicode.utf8Encode(escape.value, out) catch std.unicode.utf8Encode(std.unicode.replacement_character, out) catch unreachable;
}

const testing = std.testing;

fn expect_octets(expected: []const u8, text: []const u8) !void {
    var buffer: [constants.refusal_message_len_max]u8 = undefined;
    try testing.expectEqualStrings(expected, try unescape(text, &buffer));
}

test "a number's text gives its value, in decimal or after 0x in hexadecimal" {
    try testing.expectEqual(@as(u64, 42), try magnitude("42"));
    try testing.expectEqual(@as(u64, 0x1f), try magnitude("0x1F"));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), try magnitude("18446744073709551615"));
    try testing.expectError(error.Literal, magnitude("18446744073709551616"));
    try testing.expectError(error.Literal, magnitude("0x"));
    try testing.expectEqual(@as(f64, 1500), try double("1.5e3"));
}

test "a string's escapes read as the characters they state" {
    try expect_octets("plain", "'plain'");
    try expect_octets("a\"b", "\"a\\\"b\"");
    try expect_octets("\x07\x08\x0c\n\r\t\x0b\\?\"'`", "'\\a\\b\\f\\n\\r\\t\\v\\\\\\?\\\"\\'\\`'");
    // In a string a numbered escape is a code point: U+00E9 takes two octets of UTF-8.
    try expect_octets("\u{e9}", "'\\xe9'");
    try expect_octets("\u{e9}", "'\\351'");
    try expect_octets("\u{20ac}", "'\\u20ac'");
    try expect_octets("\u{1f600}", "'\\U0001f600'");
    try expect_octets("", "''");
}

test "a bytes literal's numbered escape is one octet, and a raw literal keeps its backslashes" {
    try expect_octets("\xe9\x00\xff", "b'\\xe9\\000\\377'");
    try expect_octets("\\d+\\.", "r'\\d+\\.'");
    try expect_octets("\\x41", "rb'\\x41'");
    var buffer: [constants.refusal_message_len_max]u8 = undefined;
    for ([_][]const u8{ "'\\q'", "'\\x4'", "'\\u12'", "b'\\u0041'", "'\\'", "'\\8'", "'\\xzz'" }) |text| {
        try testing.expectError(error.Literal, unescape(text, &buffer));
    }
}
