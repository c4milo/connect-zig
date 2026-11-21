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

/// The octets of an operator of two characters, such as "<=".
const pair_len = 2;

/// The length of the operator or the bracket that `rest` starts with, or 0 when it starts
/// none. An operator of two characters is read before its first one alone: "<=" before "<".
/// The reader runs in the compiler, where a switch costs less than a search of a list.
fn mark_len(rest: []const u8) usize {
    const second: u8 = if (rest.len > 1) rest[1] else 0;
    return switch (rest[0]) {
        '&' => if (second == '&') pair_len else 0,
        '|' => if (second == '|') pair_len else 0,
        '=' => if (second == '=') pair_len else 0,
        '<', '>', '!' => if (second == '=') pair_len else 1,
        '(', ')', '[', ']', '{', '}', '.', ',', '?', ':', '+', '-', '*', '/', '%' => 1,
        else => 0,
    };
}

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
            if (tokens.at == tokens.text.len) return;
            switch (tokens.text[tokens.at]) {
                ' ', '\t', '\r', '\n', '\x0c' => tokens.at += 1,
                '/' => {
                    const rest = tokens.text[tokens.at..];
                    if (rest.len == 1 or rest[1] != '/') return;
                    tokens.at += std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                },
                else => return,
            }
        }
    }
};

fn read(rest: []const u8) Token {
    const first = rest[0];
    switch (first) {
        '"', '\'' => return read_string(rest, 0),
        // A string's prefix, or the first letter of a name.
        'r', 'R', 'b', 'B' => if (string_start(rest)) |start| return read_string(rest, start),
        else => {},
    }
    if (std.ascii.isAlphabetic(first) or first == '_') return .{ .kind = .identifier, .text = rest[0..word_len(rest)] };
    if (std.ascii.isDigit(first)) return read_number(rest);
    // FLOAT_LIT may start at its ".": ".5".
    if (first == '.' and rest.len > 1 and std.ascii.isDigit(rest[1])) return read_number(rest);
    const len = mark_len(rest);
    if (len != 0) return .{ .kind = .punctuation, .text = rest[0..len] };
    return .{ .kind = .invalid, .text = rest[0..1] };
}

fn word_len(rest: []const u8) usize {
    for (rest, 0..) |octet, index| {
        if (!std.ascii.isAlphanumeric(octet) and octet != '_') return index;
    }
    return rest.len;
}

/// Where a string literal's opening quote lies, after its prefix: "r" or "R" for a raw string,
/// "b" or "B" before it for bytes ("BYTES_LIT ::= [bB] STRING_LIT", "STRING_LIT ::= [rR]? ...").
/// Null when `rest` starts no string.
fn string_start(rest: []const u8) ?usize {
    var index: usize = 0;
    if (index < rest.len and (rest[index] == 'b' or rest[index] == 'B')) index += 1;
    if (index < rest.len and (rest[index] == 'r' or rest[index] == 'R')) index += 1;
    if (index < rest.len and (rest[index] == '"' or rest[index] == '\'')) return index;
    return null;
}

/// The quotes that open and close a string of many lines.
pub const triple_len = 3;

/// Whether `rest` starts with three of the quote it starts with.
pub fn opens_triple(rest: []const u8) bool {
    return rest.len >= triple_len and rest[1] == rest[0] and rest[triple_len - 1] == rest[0];
}

/// A string literal: its prefix, its quotes, and the text up to the same quotes. A backslash
/// takes the octet after it, but in a raw string. A literal with no closing quote is invalid,
/// and so is one in single quotes that holds a line end ("STRING_LIT": `~( " | \r | \n )*`).
fn read_string(rest: []const u8, start: usize) Token {
    const prefix = rest[0..start];
    const raw = std.mem.indexOfAny(u8, prefix, "rR") != null;
    const kind: Kind = if (std.mem.indexOfAny(u8, prefix, "bB") != null) .bytes else .string;
    const end = string_end(rest, start, raw) orelse return .{ .kind = .invalid, .text = rest };
    return .{ .kind = kind, .text = rest[0..end] };
}

/// Where the string ends whose opening quote lies at `start`: after its closing quotes. Null
/// for a string that does not close.
fn string_end(rest: []const u8, start: usize, raw: bool) ?usize {
    const quote = rest[start];
    const triple = opens_triple(rest[start..]);
    const quotes: usize = if (triple) triple_len else 1;
    var index = start + quotes;
    for (0..rest.len) |_| {
        if (index >= rest.len) return null;
        const octet = rest[index];
        if (closes(rest[index..], quote, triple)) return index + quotes;
        if (!triple and (octet == '\n' or octet == '\r')) return null;
        index += if (octet == '\\' and !raw) constants.cel_escape_len_min else 1;
    }
    return null;
}

/// Whether `rest` starts with the quotes that close a string opened by `quote`.
fn closes(rest: []const u8, quote: u8, triple: bool) bool {
    return rest[0] == quote and (!triple or opens_triple(rest));
}

/// INT_LIT, UINT_LIT or FLOAT_LIT.
fn read_number(rest: []const u8) Token {
    // "INT_LIT ::= -? DIGIT+ | -? 0x HEXDIGIT+": the prefix is written in lower case.
    if (std.mem.startsWith(u8, rest, "0x")) {
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
    // "INT_LIT": the prefix of a hexadecimal number is "0x", in lower case.
    try expect_tokens("0X1F", "int:0 identifier:X1F");
    try expect_tokens("0x", "int:0x");
}

test "a string keeps its quotes, and a backslash takes the next octet but in a raw string" {
    try expect_tokens("'a' \"b\"", "string:'a' string:\"b\"");
    try expect_tokens("'it\\'s'", "string:'it\\'s'");
    try expect_tokens("r'a\\' b'x'", "string:r'a\\' bytes:b'x'");
    // "BYTES_LIT ::= [bB] STRING_LIT": the "b" comes before the "r".
    try expect_tokens("br'x' Br\"y\" B'z'", "bytes:br'x' bytes:Br\"y\" bytes:B'z'");
    try expect_tokens("rb'x' Rb'y'", "identifier:rb string:'x' identifier:Rb string:'y'");
    try expect_tokens("'a\"b'", "string:'a\"b'");
    try expect_tokens("'open", "invalid:'open");
    try expect_tokens("'open\\'", "invalid:'open\\'");
    // A name that starts with a prefix's letter is a name.
    try expect_tokens("rb + b", "identifier:rb punctuation:+ identifier:b");
    try expect_tokens("b", "identifier:b");
    try expect_tokens("br", "identifier:br");
}

test "a string in three quotes holds line ends and single quotes, and one in single quotes holds no line end" {
    try expect_tokens("'''a'b\nc'''", "string:'''a'b\nc'''");
    try expect_tokens("\"\"\"a\"\"b\"\"\" x", "string:\"\"\"a\"\"b\"\"\" identifier:x");
    try expect_tokens("''''''", "string:''''''");
    try expect_tokens("br'''\\'''", "bytes:br'''\\'''");
    // An escaped quote closes nothing.
    try expect_tokens("'''a\\'''b'''", "string:'''a\\'''b'''");
    try expect_tokens("'''open''", "invalid:'''open''");
    // "STRING_LIT": a string in single quotes ends before a line end.
    try expect_tokens("'a\nb'", "invalid:'a\nb'");
    try expect_tokens("\"a\rb\"", "invalid:\"a\rb\"");
    // Two quotes and no third are an empty string.
    try expect_tokens("'' x", "string:'' identifier:x");
}
