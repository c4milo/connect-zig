//! The operators and the brackets of a CEL expression (CEL language definition, "Syntax", the
//! lexis). The tokens' reader of `cel_token.zig` names each one once, so the grammar compares
//! no text.
const std = @import("std");

/// An operator or a bracket.
pub const Mark = enum {
    none,
    @"and",
    @"or",
    less_or_equal,
    greater_or_equal,
    equal,
    not_equal,
    open_paren,
    close_paren,
    open_bracket,
    close_bracket,
    open_brace,
    close_brace,
    dot,
    comma,
    question,
    colon,
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    less,
    greater,

    /// The mark as an expression writes it.
    pub fn text(mark: Mark) []const u8 {
        return switch (mark) {
            .none => "",
            .@"and" => "&&",
            .@"or" => "||",
            .less_or_equal => "<=",
            .greater_or_equal => ">=",
            .equal => "==",
            .not_equal => "!=",
            .open_paren => "(",
            .close_paren => ")",
            .open_bracket => "[",
            .close_bracket => "]",
            .open_brace => "{",
            .close_brace => "}",
            .dot => ".",
            .comma => ",",
            .question => "?",
            .colon => ":",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .bang => "!",
            .less => "<",
            .greater => ">",
        };
    }

    /// The mark that starts with `first`, with `second` after it, or `.none`. A mark of two
    /// characters is read before its first one alone: "<=" before "<".
    pub fn of(first: u8, second: u8) Mark {
        const paired = pair(first, second);
        return if (paired != .none) paired else singles[first];
    }

    /// The mark of two characters that `first` and `second` are, or `.none`.
    fn pair(first: u8, second: u8) Mark {
        if (second == '=') return switch (first) {
            '=' => .equal,
            '<' => .less_or_equal,
            '>' => .greater_or_equal,
            '!' => .not_equal,
            else => .none,
        };
        if (first != second) return .none;
        return switch (first) {
            '&' => .@"and",
            '|' => .@"or",
            else => .none,
        };
    }

    /// The mark of one character that each octet is, or `.none`: a table, which the
    /// compiler reads in one step.
    const singles: [std.math.maxInt(u8) + 1]Mark = singles: {
        var table = [_]Mark{.none} ** (std.math.maxInt(u8) + 1);
        for (&table, 0..) |*mark, octet| mark.* = single(octet);
        break :singles table;
    };

    fn single(first: u8) Mark {
        return switch (first) {
            '(' => .open_paren,
            ')' => .close_paren,
            '[' => .open_bracket,
            ']' => .close_bracket,
            '{' => .open_brace,
            '}' => .close_brace,
            '.' => .dot,
            ',' => .comma,
            '?' => .question,
            ':' => .colon,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '!' => .bang,
            '<' => .less,
            '>' => .greater,
            else => .none,
        };
    }
};
