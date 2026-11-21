//! The tokens of a CEL expression (CEL language definition, "Syntax", the lexis). The compiler
//! reads an expression at comptime, and the functions here read no more than the text they are
//! given, so a test reads one at run time too.
//!
//! The reader runs in the compiler, where each call and each slice costs microseconds
//! (docs/performance.md). So it walks the text by its octets' places, makes one slice for each
//! token, and classes each octet by a table. It also says which operator a token is and which
//! kind of word, so the grammar compares no text.
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

pub const Mark = @import("cel_token_mark.zig").Mark;

/// What an identifier is: "KEYWORD ::= BOOL_LIT | NULL_LIT | 'in'", a word of "RESERVED",
/// or a name.
pub const Word = enum {
    name,
    literal_true,
    literal_false,
    literal_null,
    in,
    /// A word a host language may hold, which names no variable and no function but one
    /// called on a target, as `a.package()` is.
    reserved,

    /// Whether the word is a keyword, which names no field and no function at all.
    pub fn is_keyword(word: Word) bool {
        return word != .name and word != .reserved;
    }

    const Entry = struct { text: []const u8, word: Word };

    /// The keywords and the reserved words that start with `first`. A switch on one octet
    /// leaves at most three words to compare, and most names none.
    fn starting_with(first: u8) []const Entry {
        return switch (first) {
            'a' => &.{.{ .text = "as", .word = .reserved }},
            'b' => &.{.{ .text = "break", .word = .reserved }},
            'c' => &.{ .{ .text = "const", .word = .reserved }, .{ .text = "continue", .word = .reserved } },
            'e' => &.{.{ .text = "else", .word = .reserved }},
            'f' => &.{ .{ .text = "false", .word = .literal_false }, .{ .text = "for", .word = .reserved }, .{ .text = "function", .word = .reserved } },
            'i' => &.{ .{ .text = "in", .word = .in }, .{ .text = "if", .word = .reserved }, .{ .text = "import", .word = .reserved } },
            'l' => &.{ .{ .text = "let", .word = .reserved }, .{ .text = "loop", .word = .reserved } },
            'n' => &.{ .{ .text = "null", .word = .literal_null }, .{ .text = "namespace", .word = .reserved } },
            'p' => &.{.{ .text = "package", .word = .reserved }},
            'r' => &.{.{ .text = "return", .word = .reserved }},
            't' => &.{.{ .text = "true", .word = .literal_true }},
            'v' => &.{ .{ .text = "var", .word = .reserved }, .{ .text = "void", .word = .reserved } },
            'w' => &.{.{ .text = "while", .word = .reserved }},
            else => &.{},
        };
    }

    fn of(text: []const u8) Word {
        for (starting_with(text[0])) |entry| {
            if (entry.text.len == text.len and std.mem.eql(u8, entry.text, text)) return entry.word;
        }
        return .name;
    }
};

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    /// Which operator or bracket a punctuation token is.
    mark: Mark = .none,
    /// Which kind of word an identifier is.
    word: Word = .name,
};

/// What an octet may start or continue.
const Class = enum(u8) { other, space, word, digit, quote, mark };

const classes: [std.math.maxInt(u8) + 1]Class = classes: {
    var table = [_]Class{.other} ** (std.math.maxInt(u8) + 1);
    for (&table, 0..) |*class, octet| {
        class.* = switch (octet) {
            // "WHITESPACE ::= [\t\n\f\r ]+".
            ' ', '\t', '\r', '\n', '\x0c' => .space,
            'a'...'z', 'A'...'Z', '_' => .word,
            '0'...'9' => .digit,
            '"', '\'' => .quote,
            '&', '|', '=', '<', '>', '!', '(', ')', '[', ']', '{', '}', '.', ',', '?', ':', '+', '-', '*', '/', '%' => .mark,
            else => .other,
        };
    }
    break :classes table;
};

pub const Tokens = struct {
    text: []const u8,
    at: usize = 0,

    /// The next token, which the reader moves past.
    pub fn next(tokens: *Tokens) Token {
        const text = tokens.text;
        const start = space_end(text, tokens.at);
        if (start == text.len) {
            tokens.at = start;
            return .{ .kind = .end, .text = text[start..] };
        }
        const token = read(text, start);
        tokens.at = start + token.text.len;
        return token;
    }
};

/// Where the WHITESPACE and the COMMENTs from `from` end: a comment is "//" to the end of its
/// line.
fn space_end(text: []const u8, from: usize) usize {
    var at = from;
    for (0..text.len + 1) |_| {
        if (at == text.len) return at;
        const octet = text[at];
        if (classes[octet] == .space) {
            at += 1;
        } else if (octet == '/' and at + 1 != text.len and text[at + 1] == '/') {
            at = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        } else return at;
    }
    return at;
}

/// The token that starts at `start`, where an octet lies that is no space.
fn read(text: []const u8, start: usize) Token {
    const first = text[start];
    const second: u8 = if (start + 1 != text.len) text[start + 1] else 0;
    switch (classes[first]) {
        .quote => return read_string(text, start, start),
        .word => return read_word(text, start),
        .digit => return read_number(text, start),
        .mark => {
            // FLOAT_LIT may start at its ".": ".5".
            if (first == '.' and classes[second] == .digit) return read_number(text, start);
            const mark: Mark = .of(first, second);
            if (mark != .none) return .{ .kind = .punctuation, .text = text[start .. start + mark.text().len], .mark = mark };
        },
        .other, .space => {},
    }
    return .{ .kind = .invalid, .text = text[start .. start + 1] };
}

/// An identifier, or a string whose prefix starts as a word does.
fn read_word(text: []const u8, start: usize) Token {
    switch (text[start]) {
        // A string's prefix, or the first letter of a name.
        'r', 'R', 'b', 'B' => if (string_start(text, start)) |quote_at| return read_string(text, start, quote_at),
        else => {},
    }
    var end = start + 1;
    for (end..text.len) |index| {
        const class = classes[text[index]];
        if (class != .word and class != .digit) break;
        end = index + 1;
    }
    const word = text[start..end];
    return .{ .kind = .identifier, .text = word, .word = .of(word) };
}

/// Where a string literal's opening quote lies, after its prefix from `start`: "r" or "R" for
/// a raw string, "b" or "B" before it for bytes ("BYTES_LIT ::= [bB] STRING_LIT", "STRING_LIT
/// ::= [rR]? ..."). Null when no string starts at `start`.
fn string_start(text: []const u8, start: usize) ?usize {
    var at = start;
    if (at != text.len and (text[at] == 'b' or text[at] == 'B')) at += 1;
    if (at != text.len and (text[at] == 'r' or text[at] == 'R')) at += 1;
    if (at != text.len and classes[text[at]] == .quote) return at;
    return null;
}

/// The quotes that open and close a string of many lines.
pub const triple_len = 3;

/// Whether `rest` starts with three of the quote it starts with.
pub fn opens_triple(rest: []const u8) bool {
    return rest.len >= triple_len and rest[1] == rest[0] and rest[triple_len - 1] == rest[0];
}

/// A string literal from `start`, whose opening quote lies at `quote_at`: its prefix, its
/// quotes, and the text up to the same quotes. A literal with no closing quote is invalid, and
/// so is one in single quotes that holds a line end ("STRING_LIT": `~( " | \r | \n )*`).
fn read_string(text: []const u8, start: usize, quote_at: usize) Token {
    const raw = quote_at != start and (text[quote_at - 1] == 'r' or text[quote_at - 1] == 'R');
    const of_bytes = quote_at != start and (text[start] == 'b' or text[start] == 'B');
    const end = string_end(text, quote_at, raw) orelse return .{ .kind = .invalid, .text = text[start..] };
    return .{ .kind = if (of_bytes) .bytes else .string, .text = text[start..end] };
}

/// Where the string ends whose opening quote lies at `quote_at`: after its closing quotes. A
/// backslash takes the octet after it, but in a raw string. Null for a string that does not
/// close.
fn string_end(text: []const u8, quote_at: usize, raw: bool) ?usize {
    const triple = opens_triple(text[quote_at..]);
    const quotes: usize = if (triple) triple_len else 1;
    var index = quote_at + quotes;
    for (0..text.len) |_| {
        if (index >= text.len) return null;
        if (closes(text, index, text[quote_at], triple)) return index + quotes;
        if (breaks(text[index], triple)) return null;
        index += if (text[index] == '\\' and !raw) constants.cel_escape_len_min else 1;
    }
    return null;
}

/// Whether the string's closing quotes lie at `index`: its quote, three times for a string
/// of many lines.
fn closes(text: []const u8, index: usize, quote: u8, triple: bool) bool {
    if (text[index] != quote) return false;
    return !triple or opens_triple(text[index..]);
}

/// Whether `octet` ends a string with no closing quote: a line end, in a string of one line.
fn breaks(octet: u8, triple: bool) bool {
    return !triple and (octet == '\n' or octet == '\r');
}

/// INT_LIT, UINT_LIT or FLOAT_LIT from `start`, where a digit lies, or "." and a digit.
fn read_number(text: []const u8, start: usize) Token {
    // "INT_LIT ::= -? DIGIT+ | -? 0x HEXDIGIT+": the prefix is written in lower case.
    if (text[start] == '0' and start + 1 != text.len and text[start + 1] == 'x') {
        const digits = start + "0x".len;
        return with_suffix(text, start, digits + run_len(text[digits..], std.ascii.isHex), .int);
    }
    var end = digits_end(text, start);
    var kind: Kind = .int;
    if (end + 1 < text.len and text[end] == '.' and classes[text[end + 1]] == .digit) {
        end = digits_end(text, end + 1);
        kind = .double;
    }
    const exponent = exponent_end(text, end);
    if (exponent != end) kind = .double;
    return with_suffix(text, start, exponent, kind);
}

/// Where the digits from `from` end.
fn digits_end(text: []const u8, from: usize) usize {
    for (from..text.len) |index| {
        if (classes[text[index]] != .digit) return index;
    }
    return text.len;
}

/// Where "EXPONENT ::= [eE] [+-]? DIGIT+" ends when one starts at `from`, or `from`.
fn exponent_end(text: []const u8, from: usize) usize {
    if (from == text.len or (text[from] != 'e' and text[from] != 'E')) return from;
    var at = from + 1;
    if (at != text.len and (text[at] == '+' or text[at] == '-')) at += 1;
    const end = digits_end(text, at);
    return if (end == at) from else end;
}

/// An integer with "u" or "U" after it is a UINT_LIT.
fn with_suffix(text: []const u8, start: usize, end: usize, kind: Kind) Token {
    if (kind == .int and end != text.len and (text[end] == 'u' or text[end] == 'U')) return .{ .kind = .uint, .text = text[start .. end + 1] };
    return .{ .kind = kind, .text = text[start..end] };
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

test "a punctuation token names its mark, and a mark's text is the token's" {
    const marks = "&& || <= >= == != ( ) [ ] { } . , ? : + - * / % ! < >";
    var tokens: Tokens = .{ .text = marks };
    var seen: usize = 0;
    for (std.enums.values(Mark)) |mark| {
        if (mark == .none) continue;
        const token = tokens.next();
        try testing.expectEqual(Kind.punctuation, token.kind);
        try testing.expectEqual(mark, token.mark);
        try testing.expectEqualStrings(mark.text(), token.text);
        seen += 1;
    }
    try testing.expectEqual(Kind.end, tokens.next().kind);
    try testing.expectEqual(std.enums.values(Mark).len - 1, seen);
    // A lone "&", "|" or "=" is no operator.
    try expect_tokens("a & b | c = d", "identifier:a invalid:& identifier:b invalid:| identifier:c invalid:= identifier:d");
}

fn expect_word(text: []const u8, word: Word) !void {
    var tokens: Tokens = .{ .text = text };
    const token = tokens.next();
    try testing.expectEqual(Kind.identifier, token.kind);
    try testing.expectEqualStrings(text, token.text);
    try testing.expectEqual(word, token.word);
    try testing.expectEqual(Mark.none, token.mark);
}

test "an identifier is a keyword, a reserved word or a name" {
    try expect_word("true", .literal_true);
    try expect_word("false", .literal_false);
    try expect_word("null", .literal_null);
    try expect_word("in", .in);
    for ([_][]const u8{ "as", "break", "const", "continue", "else", "for", "function", "if", "import", "let", "loop", "package", "namespace", "return", "var", "void", "while" }) |word| try expect_word(word, .reserved);
    // A word's start, a word with more after it, and a word in another case are names.
    for ([_][]const u8{ "tru", "trues", "True", "i", "inn", "nul", "fo", "form", "this", "x", "_in", "voids", "e", "z9" }) |name| try expect_word(name, .name);
    try testing.expect(Word.literal_true.is_keyword() and Word.literal_false.is_keyword() and Word.literal_null.is_keyword() and Word.in.is_keyword());
    try testing.expect(!Word.name.is_keyword() and !Word.reserved.is_keyword());
}
