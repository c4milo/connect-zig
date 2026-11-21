//! The tokens of a CEL expression (CEL language definition, "Syntax", the lexis). The compiler
//! reads an expression at comptime, and the functions here read no more than the text they are
//! given, so a test reads one at run time too.
const std = @import("std");
const constants = @import("../constants.zig");

pub const Kind = enum {
    /// The end of the text.
    end,
    identifier,
    /// INT_LIT, without a sign: digits, or "0x" and hexadecimal digits.
    int,
    /// UINT_LIT: an INT_LIT and "u" or "U".
    uint,
    /// FLOAT_LIT: digits with a fraction, an exponent, or both.
    double,
    /// STRING_LIT, with its quotes and its "r" prefix, if any.
    string,
    /// BYTES_LIT: a STRING_LIT after "b" or "B".
    bytes,
    /// An operator or a bracket.
    punctuation,
    /// Text that starts no token.
    invalid,
};

pub const Token = struct {
    kind: Kind,
    text: []const u8,

    pub fn is(token: Token, mark: []const u8) bool {
        return token.kind == .punctuation and std.mem.eql(u8, token.text, mark);
    }

    pub fn is_word(token: Token, word: []const u8) bool {
        return token.kind == .identifier and std.mem.eql(u8, token.text, word);
    }
};

/// Each operator and bracket, the longest first, so "<=" is read before "<".
const marks = [_][]const u8{ "&&", "||", "<=", ">=", "==", "!=", "(", ")", "[", "]", "{", "}", ".", ",", "?", ":", "+", "-", "*", "/", "%", "!", "<", ">" };

pub const Tokens = struct {
    text: []const u8,
    at: usize = 0,

    /// The next token, which the reader moves past.
    pub fn next(tokens: *Tokens) Token {
        tokens.skip_space();
        const rest = tokens.text[tokens.at..];
        if (rest.len == 0) return .{ .kind = .end, .text = rest };
        const token = read(rest);
        tokens.at += token.text.len;
        return token;
    }

    /// The next token, which the reader stays before.
    pub fn peek(tokens: *const Tokens) Token {
        var copy = tokens.*;
        return copy.next();
    }

    /// WHITESPACE and COMMENT: "//" to the end of its line.
    fn skip_space(tokens: *Tokens) void {
        for (0..tokens.text.len + 1) |_| {
            const rest = tokens.text[tokens.at..];
            if (std.mem.startsWith(u8, rest, "//")) {
                tokens.at += std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            } else if (rest.len != 0 and std.mem.indexOfScalar(u8, " \t\r\n\x0c", rest[0]) != null) {
                tokens.at += 1;
            } else return;
        }
    }
};

fn read(rest: []const u8) Token {
    const first = rest[0];
    if (string_start(rest)) |start| return read_string(rest, start);
    if (std.ascii.isAlphabetic(first) or first == '_') return .{ .kind = .identifier, .text = rest[0..word_len(rest)] };
    if (std.ascii.isDigit(first)) return read_number(rest);
    // FLOAT_LIT may start at its ".": ".5".
    if (first == '.' and rest.len > 1 and std.ascii.isDigit(rest[1])) return read_number(rest);
    for (marks) |each| {
        if (std.mem.startsWith(u8, rest, each)) return .{ .kind = .punctuation, .text = rest[0..each.len] };
    }
    return .{ .kind = .invalid, .text = rest[0..1] };
}

fn word_len(rest: []const u8) usize {
    for (rest, 0..) |octet, index| {
        if (!std.ascii.isAlphanumeric(octet) and octet != '_') return index;
    }
    return rest.len;
}

/// Where a string literal's opening quote lies, after its prefix: "r" for a raw string, "b" for
/// bytes, or both, in either order and case. Null when `rest` starts no string.
fn string_start(rest: []const u8) ?usize {
    for (0..constants.cel_string_prefix_len_max + 1) |index| {
        if (index == rest.len) return null;
        if (rest[index] == '"' or rest[index] == '\'') return index;
        if (std.mem.indexOfScalar(u8, "rRbB", rest[index]) == null) return null;
    }
    return null;
}

/// A string literal: its prefix, its quote, and the text up to the same quote. A backslash
/// takes the octet after it, but in a raw string. A literal with no closing quote is invalid.
fn read_string(rest: []const u8, start: usize) Token {
    const prefix = rest[0..start];
    const raw = std.mem.indexOfAny(u8, prefix, "rR") != null;
    const kind: Kind = if (std.mem.indexOfAny(u8, prefix, "bB") != null) .bytes else .string;
    const quote = rest[start];
    var index = start + 1;
    for (0..rest.len) |_| {
        if (index >= rest.len) break;
        if (rest[index] == quote) return .{ .kind = kind, .text = rest[0 .. index + 1] };
        index += if (rest[index] == '\\' and !raw) constants.cel_escape_len_min else 1;
    }
    return .{ .kind = .invalid, .text = rest };
}

/// INT_LIT, UINT_LIT or FLOAT_LIT.
fn read_number(rest: []const u8) Token {
    if (std.mem.startsWith(u8, rest, "0x") or std.mem.startsWith(u8, rest, "0X")) {
        const prefix_len = "0x".len;
        const len = prefix_len + run_len(rest[prefix_len..], std.ascii.isHex);
        return with_suffix(rest, len, .int);
    }
    var len = run_len(rest, std.ascii.isDigit);
    var kind: Kind = .int;
    if (len < rest.len and rest[len] == '.' and len + 1 < rest.len and std.ascii.isDigit(rest[len + 1])) {
        len += 1 + run_len(rest[len + 1 ..], std.ascii.isDigit);
        kind = .double;
    }
    const exponent = exponent_len(rest[len..]);
    if (exponent != 0) kind = .double;
    return with_suffix(rest, len + exponent, kind);
}

/// EXPONENT: "e" or "E", an optional sign, and digits.
fn exponent_len(rest: []const u8) usize {
    if (rest.len == 0 or (rest[0] != 'e' and rest[0] != 'E')) return 0;
    const sign: usize = if (rest.len > 1 and (rest[1] == '+' or rest[1] == '-')) 1 else 0;
    const digits = run_len(rest[1 + sign ..], std.ascii.isDigit);
    if (digits == 0) return 0;
    return 1 + sign + digits;
}

/// An integer with "u" or "U" after it is a UINT_LIT.
fn with_suffix(rest: []const u8, len: usize, kind: Kind) Token {
    if (kind == .int and len < rest.len and (rest[len] == 'u' or rest[len] == 'U')) return .{ .kind = .uint, .text = rest[0 .. len + 1] };
    return .{ .kind = kind, .text = rest[0..len] };
}

fn run_len(rest: []const u8, comptime in_run: fn (u8) bool) usize {
    for (rest, 0..) |octet, index| {
        if (!in_run(octet)) return index;
    }
    return rest.len;
}

const testing = std.testing;

/// The kinds and the texts of an expression's tokens, joined: "identifier:this punctuation:.".
fn expect_tokens(text: []const u8, expected: []const u8) !void {
    var tokens: Tokens = .{ .text = text };
    var buffer: [constants.refusal_message_len_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (0..text.len + 1) |index| {
        const token = tokens.next();
        if (token.kind == .end) break;
        try writer.print("{s}{s}:{s}", .{ if (index == 0) "" else " ", @tagName(token.kind), token.text });
    }
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "an expression reads as identifiers, literals and punctuation" {
    try expect_tokens("this.a <= 10", "identifier:this punctuation:. identifier:a punctuation:<= int:10");
    try expect_tokens("!x&&y||z", "punctuation:! identifier:x punctuation:&& identifier:y punctuation:|| identifier:z");
    try expect_tokens("a<b>c==d!=e>=f", "identifier:a punctuation:< identifier:b punctuation:> identifier:c punctuation:== identifier:d punctuation:!= identifier:e punctuation:>= identifier:f");
    try expect_tokens("f(x, [1])  // the rest", "identifier:f punctuation:( identifier:x punctuation:, punctuation:[ int:1 punctuation:] punctuation:)");
    try expect_tokens("_a1 ? b : c", "identifier:_a1 punctuation:? identifier:b punctuation:: identifier:c");
    try expect_tokens("a\t+\n-b*c/d%e", "identifier:a punctuation:+ punctuation:- identifier:b punctuation:* identifier:c punctuation:/ identifier:d punctuation:% identifier:e");
    try expect_tokens("#", "invalid:#");
    try expect_tokens("", "");
}

test "a number is an int, a uint with its suffix, or a double with a fraction or an exponent" {
    try expect_tokens("0 42 0x1F 7u 0xFFU", "int:0 int:42 int:0x1F uint:7u uint:0xFFU");
    try expect_tokens("1.5 2e3 2E-3 .5 1.5e+2", "double:1.5 double:2e3 double:2E-3 double:.5 double:1.5e+2");
    // A "." with no digit after it is a selection, and an "e" with no digit is a name.
    try expect_tokens("1.size", "int:1 punctuation:. identifier:size");
    try expect_tokens("2e", "int:2 identifier:e");
    try expect_tokens("1.5u", "double:1.5 identifier:u");
}

test "a string keeps its quotes, and a backslash takes the next octet but in a raw string" {
    try expect_tokens("'a' \"b\"", "string:'a' string:\"b\"");
    try expect_tokens("'it\\'s'", "string:'it\\'s'");
    try expect_tokens("r'a\\' b'x'", "string:r'a\\' bytes:b'x'");
    try expect_tokens("rb'x' Br\"y\"", "bytes:rb'x' bytes:Br\"y\"");
    try expect_tokens("'a\"b'", "string:'a\"b'");
    try expect_tokens("'open", "invalid:'open");
    try expect_tokens("'open\\'", "invalid:'open\\'");
    // A name that starts with a prefix's letter is a name.
    try expect_tokens("rb + b", "identifier:rb punctuation:+ identifier:b");
}
