//! The grammar of a CEL expression (CEL language definition, "Syntax"), over a builder that
//! keeps what the grammar reads. The compiler runs it with the builder of `cel_parse.zig`, which
//! makes the tree a rule's check unfolds from. A test runs the same code at run time with the
//! builder of `cel_tree.zig`, so a fuzzer reads what the compiler reads.
//!
//! ```text
//! Expr           = ConditionalOr ["?" ConditionalOr ":" Expr]
//! ConditionalOr  = [ConditionalOr "||"] ConditionalAnd
//! ConditionalAnd = [ConditionalAnd "&&"] Relation
//! Relation       = [Relation Relop] Addition
//! Addition       = [Addition ("+" | "-")] Multiplication
//! Multiplication = [Multiplication ("*" | "/" | "%")] Unary
//! Unary          = Member | "!" {"!"} Member | "-" {"-"} Member
//! Member         = Primary | Member "." IDENT ["(" [ExprList] ")"] | Member "[" Expr "]"
//! Primary        = IDENT ["(" [ExprList] ")"] | "(" Expr ")" | "[" [ExprList] [","] "]"
//!                | "{" [MapInits] [","] "}" | LITERAL
//! MapInits       = Expr ":" Expr {"," Expr ":" Expr}
//! ```
//!
//! The module reads no message literal: an expression of a rule builds none.
const std = @import("std");
const constants = @import("../constants.zig");
const token_file = @import("cel_token.zig");
const literal = @import("cel_literal.zig");
const node_file = @import("cel_node.zig");
const BinaryOp = node_file.BinaryOp;
const UnaryOp = node_file.UnaryOp;
const Token = token_file.Token;
const Mark = token_file.Mark;

/// What is wrong with an expression's text. It holds no text of its own: `token` and `mark`
/// lie in the expression and in the grammar.
pub const Problem = struct {
    kind: Kind = .none,
    /// The token the problem lies at.
    token: []const u8 = "",
    /// What the grammar expected before `token`.
    mark: Mark = .none,

    pub const Kind = enum { none, ends_early, unexpected, expected, expected_name, reserved, not_int, negative_not_int, out_of_range, wrong_escape, too_deep };

    /// The pieces of a problem's text, which its reader joins.
    pub const pieces_len = 5;

    /// The problem as text, in pieces: the compiler joins them into a message, and a test
    /// writes them one after another.
    pub fn pieces(problem: Problem) [pieces_len][]const u8 {
        return switch (problem.kind) {
            .none => .{ "", "", "", "", "" },
            .ends_early => .{ "the expression ends early", "", "", "", "" },
            .unexpected => .{ "unexpected `", problem.token, "`", "", "" },
            .expected => .{ "expected `", problem.mark.text(), "` before `", problem.token, "`" },
            .expected_name => .{ "expected a name after `.`, before `", problem.token, "`", "", "" },
            .reserved => .{ "`", problem.token, "` is a reserved word", "", "" },
            .not_int => .{ "the number `", problem.token, "` is not an int", "", "" },
            .negative_not_int => .{ "the number `-", problem.token, "` is not an int", "", "" },
            .out_of_range => .{ "the number `", problem.token, "` is out of range", "", "" },
            .wrong_escape => .{ "the literal ", problem.token, " holds a wrong escape", "", "" },
            .too_deep => .{ "the expression nests too deep", "", "", "", "" },
        };
    }
};

pub const Error = error{Syntax};

/// A binary operator and its level in the grammar, the loosest level first.
const Operator = struct { op: BinaryOp, level: usize };

const or_level = 0;
const and_level = 1;
const relation_level = 2;
const addition_level = 3;
const multiplication_level = 4;

/// The binary operator that `token` is, or null. The tokens' reader names each operator and
/// the word "in", so no text is compared here.
fn operator_of(token: Token) ?Operator {
    if (token.word == .in) return .{ .op = .in, .level = relation_level };
    return switch (token.mark) {
        .@"or" => .{ .op = .@"or", .level = or_level },
        .@"and" => .{ .op = .@"and", .level = and_level },
        .less => .{ .op = .less, .level = relation_level },
        .less_or_equal => .{ .op = .less_or_equal, .level = relation_level },
        .greater => .{ .op = .greater, .level = relation_level },
        .greater_or_equal => .{ .op = .greater_or_equal, .level = relation_level },
        .equal => .{ .op = .equal, .level = relation_level },
        .not_equal => .{ .op = .not_equal, .level = relation_level },
        .plus => .{ .op = .add, .level = addition_level },
        .minus => .{ .op = .subtract, .level = addition_level },
        .star => .{ .op = .multiply, .level = multiplication_level },
        .slash => .{ .op = .divide, .level = multiplication_level },
        .percent => .{ .op = .modulo, .level = multiplication_level },
        else => null,
    };
}

/// The grammar's reader over a builder `B`, which states:
///
/// - `Value`, what it keeps of one part of an expression, and `Arguments`, the parts of a call
///   or of a list literal while they are read;
/// - one function for each kind of part, which gives the part's `Value`;
/// - `text_literal`, which gives null for a literal with a wrong escape.
pub fn Reader(comptime B: type) type {
    return struct {
        tokens: token_file.Tokens,
        /// The next token, which the reader has not passed yet. Each token is read once.
        ahead: Token,
        /// The binary operator that `ahead` is, or null.
        operator: ?Operator,
        builder: B,
        depth: usize = 0,
        problem: Problem = .{},
    };
}

/// A reader at the start of `text`.
pub fn start(comptime B: type, text: []const u8, builder: B) Reader(B) {
    var tokens: token_file.Tokens = .{ .text = text };
    const first = tokens.next();
    return .{ .tokens = tokens, .ahead = first, .operator = operator_of(first), .builder = builder };
}

/// The whole text as one expression, or `error.Syntax` with the reader's `problem` set.
pub fn whole(comptime B: type, p: *Reader(B)) Error!B.Value {
    const value = try expression(B, p);
    if (p.ahead.kind != .end) return fail(B, p, .{ .kind = .unexpected, .token = p.ahead.text });
    return value;
}

fn fail(comptime B: type, p: *Reader(B), problem: Problem) Error {
    p.problem = problem;
    return error.Syntax;
}

/// Passes the next token and gives it.
fn advance(comptime B: type, p: *Reader(B)) Token {
    const token = p.ahead;
    p.ahead = p.tokens.next();
    p.operator = operator_of(p.ahead);
    return token;
}

fn take(comptime B: type, p: *Reader(B), mark: Mark) bool {
    if (p.ahead.mark != mark) return false;
    _ = advance(B, p);
    return true;
}

fn expect(comptime B: type, p: *Reader(B), mark: Mark) Error!void {
    if (!take(B, p, mark)) return fail(B, p, .{ .kind = .expected, .mark = mark, .token = p.ahead.text });
}

fn expression(comptime B: type, p: *Reader(B)) Error!B.Value {
    if (p.depth == constants.cel_depth_max) return fail(B, p, .{ .kind = .too_deep });
    p.depth += 1;
    defer p.depth -= 1;
    const condition = try binary(B, p, 0);
    if (!take(B, p, .question)) return condition;
    const then = try binary(B, p, 0);
    try expect(B, p, .colon);
    const otherwise = try expression(B, p);
    return p.builder.conditional(condition, then, otherwise);
}

/// The binary operators of `level` and of each tighter level. Operators of one level group
/// from the left: "a - b - c" is "(a - b) - c".
fn binary(comptime B: type, p: *Reader(B), level: usize) Error!B.Value {
    var left = try unary(B, p);
    // Each turn passes an operator, so the text's length bounds the turns.
    for (0..p.tokens.text.len) |_| {
        const operator = p.operator orelse return left;
        if (operator.level < level) return left;
        _ = advance(B, p);
        const right = try binary(B, p, operator.level + 1);
        left = p.builder.binary(operator.op, left, right);
    }
    return left;
}

fn unary(comptime B: type, p: *Reader(B)) Error!B.Value {
    const first = p.ahead.mark;
    if (first != .bang and first != .minus) return member(B, p);
    // "Unary = ... | '!' {'!'} Member | '-' {'-'} Member": a run of one operator.
    var count: usize = 0;
    for (0..p.tokens.text.len) |_| {
        if (!take(B, p, first)) break;
        count += 1;
    }
    const negates = first == .minus;
    // "INT_LIT ::= -? DIGIT+" and "FLOAT_LIT ::= -? ...": a number's sign is part of its
    // literal, and "Unary" takes a run of "-" too, so "--5" has two readings. This reader
    // takes cel-go's: one "-" before a number is the number's sign, so the least int is
    // written and "-2.5.f()" calls `f` on -2.5. A run of two or more is a run of negations.
    const signs = negates and count == 1 and (p.ahead.kind == .int or p.ahead.kind == .double);
    if (signs) return negative(B, p);
    var value = try member(B, p);
    const op: UnaryOp = if (negates) .negate else .not;
    for (0..count) |_| value = p.builder.unary(op, value);
    return value;
}

/// A number after a "-", which is its sign, then what follows it.
fn negative(comptime B: type, p: *Reader(B)) Error!B.Value {
    return members(B, p, try negative_literal(B, p));
}

/// An int or a double literal after a "-", which is its sign.
fn negative_literal(comptime B: type, p: *Reader(B)) Error!B.Value {
    const token = advance(B, p);
    if (token.kind == .double) {
        const double = literal.double(token.text) catch return fail(B, p, .{ .kind = .out_of_range, .token = token.text });
        return p.builder.double(-double, token.text);
    }
    const value = literal.magnitude(token.text) catch return fail(B, p, .{ .kind = .not_int, .token = token.text });
    const least: u64 = @as(u64, std.math.maxInt(i64)) + 1;
    if (value > least) return fail(B, p, .{ .kind = .negative_not_int, .token = token.text });
    const signed: i64 = if (value == least) std.math.minInt(i64) else -@as(i64, @intCast(value));
    return p.builder.int(signed);
}

fn member(comptime B: type, p: *Reader(B)) Error!B.Value {
    return members(B, p, try primary(B, p));
}

/// The selections, the calls and the indexes after `first`.
fn members(comptime B: type, p: *Reader(B), first: B.Value) Error!B.Value {
    var value = first;
    // Each turn passes a token, so the text's length bounds the turns.
    for (0..p.tokens.text.len) |_| {
        if (take(B, p, .dot)) {
            value = try selection(B, p, value);
        } else if (take(B, p, .open_bracket)) {
            const at = try expression(B, p);
            try expect(B, p, .close_bracket);
            value = p.builder.index(value, at);
        } else return value;
    }
    return value;
}

/// What follows a ".": a field's name, or a function's name and its arguments.
fn selection(comptime B: type, p: *Reader(B), target: B.Value) Error!B.Value {
    const name = advance(B, p);
    // "SELECTOR ::= [_a-zA-Z][_a-zA-Z0-9]* - KEYWORD": a keyword names no field and no function.
    if (name.kind != .identifier or name.word.is_keyword()) return fail(B, p, .{ .kind = .expected_name, .token = name.text });
    if (!take(B, p, .open_paren)) return p.builder.select(target, name.text);
    return p.builder.call(name.text, target, try list(B, p, .close_paren, .no_last_comma));
}

/// Whether a comma may follow the last expression of a list: a list literal takes one
/// ("Primary = ... | '[' [ExprList] [','] ']'"), and a call's arguments take none.
const LastComma = enum { last_comma, no_last_comma };

/// A map literal's keys and values in turns, up to "}": "'{' [MapInits] [','] '}'", where
/// "MapInits = Expr ':' Expr {',' Expr ':' Expr}".
fn entries(comptime B: type, p: *Reader(B)) Error!B.Arguments {
    var parts = p.builder.arguments();
    if (take(B, p, .close_brace)) return parts;
    // Each turn passes an entry, so the text's length bounds the turns.
    for (0..p.tokens.text.len) |_| {
        p.builder.add(&parts, try expression(B, p));
        try expect(B, p, .colon);
        p.builder.add(&parts, try expression(B, p));
        if (take(B, p, .close_brace)) return parts;
        try expect(B, p, .comma);
        if (take(B, p, .close_brace)) return parts;
    }
    return parts;
}

/// The expressions up to `close`, with commas between them.
fn list(comptime B: type, p: *Reader(B), close: Mark, last: LastComma) Error!B.Arguments {
    var arguments = p.builder.arguments();
    if (take(B, p, close)) return arguments;
    // Each turn passes an expression, so the text's length bounds the turns.
    for (0..p.tokens.text.len) |_| {
        p.builder.add(&arguments, try expression(B, p));
        if (take(B, p, close)) return arguments;
        try expect(B, p, .comma);
        if (last == .last_comma and take(B, p, close)) return arguments;
    }
    return arguments;
}

fn primary(comptime B: type, p: *Reader(B)) Error!B.Value {
    const token = advance(B, p);
    if (token.mark == .open_paren) {
        const inner = try expression(B, p);
        try expect(B, p, .close_paren);
        return inner;
    }
    if (token.mark == .open_bracket) return p.builder.list(try list(B, p, .close_bracket, .last_comma));
    if (token.mark == .open_brace) return p.builder.map(try entries(B, p));
    // "INT_LIT ::= -? DIGIT+" and "FLOAT_LIT ::= -? ...": a number's sign is part of the
    // literal, so "!-5" reads. A "-" before any other part is the operator, which `unary` reads.
    if (token.mark == .minus and (p.ahead.kind == .int or p.ahead.kind == .double)) return negative_literal(B, p);
    return switch (token.kind) {
        .identifier => named(B, p, token),
        .int, .uint, .double => number(B, p, token),
        .string, .bytes => p.builder.text_literal(token.kind, token.text) orelse fail(B, p, .{ .kind = .wrong_escape, .token = token.text }),
        .end => fail(B, p, .{ .kind = .ends_early }),
        else => fail(B, p, .{ .kind = .unexpected, .token = token.text }),
    };
}

/// An identifier: a constant's word, a function's name before its arguments, or a name.
fn named(comptime B: type, p: *Reader(B), token: Token) Error!B.Value {
    switch (token.word) {
        .literal_true => return p.builder.boolean(true),
        .literal_false => return p.builder.boolean(false),
        .literal_null => return p.builder.nothing(),
        .in => return fail(B, p, .{ .kind = .unexpected, .token = token.text }),
        // "IDENT ::= SELECTOR - RESERVED".
        .reserved => return fail(B, p, .{ .kind = .reserved, .token = token.text }),
        .name => {},
    }
    if (!take(B, p, .open_paren)) return p.builder.name(token.text);
    return p.builder.call(token.text, null, try list(B, p, .close_paren, .no_last_comma));
}

fn number(comptime B: type, p: *Reader(B), token: Token) Error!B.Value {
    const problem: Problem = .{ .kind = .out_of_range, .token = token.text };
    switch (token.kind) {
        .double => return p.builder.double(literal.double(token.text) catch return fail(B, p, problem), token.text),
        .uint => return p.builder.uint(literal.magnitude(token.text[0 .. token.text.len - 1]) catch return fail(B, p, problem)),
        else => {
            const value = literal.magnitude(token.text) catch return fail(B, p, problem);
            if (value > std.math.maxInt(i64)) return fail(B, p, problem);
            return p.builder.int(@intCast(value));
        },
    }
}
