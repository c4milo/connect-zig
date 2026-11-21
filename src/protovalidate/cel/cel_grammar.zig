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
//! Primary        = IDENT ["(" [ExprList] ")"] | "(" Expr ")" | "[" [ExprList] "]" | LITERAL
//! ```
//!
//! The module reads no map and no message literal: an expression of a rule builds neither.
const std = @import("std");
const constants = @import("../constants.zig");
const token_file = @import("cel_token.zig");
const literal = @import("cel_literal.zig");
const node_file = @import("cel_node.zig");
const BinaryOp = node_file.BinaryOp;
const UnaryOp = node_file.UnaryOp;
const Token = token_file.Token;

/// What is wrong with an expression's text. It holds no text of its own: `token` and `mark`
/// lie in the expression and in the grammar.
pub const Problem = struct {
    kind: Kind = .none,
    /// The token the problem lies at.
    token: []const u8 = "",
    /// What the grammar expected before `token`.
    mark: []const u8 = "",

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
            .expected => .{ "expected `", problem.mark, "` before `", problem.token, "`" },
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
/// The octets of an operator of two characters, such as "<=".
const pair_len = 2;

/// The binary operator that `token` is, or null. The tokens' reader gives each operator whole,
/// so its first character and its length name it.
fn operator_of(token: Token) ?Operator {
    if (token.kind == .identifier) return if (token.is_word("in")) .{ .op = .in, .level = relation_level } else null;
    if (token.kind != .punctuation) return null;
    const pair = token.text.len == pair_len;
    return switch (token.text[0]) {
        '|' => .{ .op = .@"or", .level = or_level },
        '&' => .{ .op = .@"and", .level = and_level },
        '<' => .{ .op = if (pair) .less_or_equal else .less, .level = relation_level },
        '>' => .{ .op = if (pair) .greater_or_equal else .greater, .level = relation_level },
        '=' => .{ .op = .equal, .level = relation_level },
        '!' => if (pair) .{ .op = .not_equal, .level = relation_level } else null,
        '+' => .{ .op = .add, .level = addition_level },
        '-' => .{ .op = .subtract, .level = addition_level },
        '*' => .{ .op = .multiply, .level = multiplication_level },
        '/' => .{ .op = .divide, .level = multiplication_level },
        '%' => .{ .op = .modulo, .level = multiplication_level },
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

fn take(comptime B: type, p: *Reader(B), mark: []const u8) bool {
    if (!p.ahead.is(mark)) return false;
    _ = advance(B, p);
    return true;
}

fn expect(comptime B: type, p: *Reader(B), mark: []const u8) Error!void {
    if (!take(B, p, mark)) return fail(B, p, .{ .kind = .expected, .mark = mark, .token = p.ahead.text });
}

fn expression(comptime B: type, p: *Reader(B)) Error!B.Value {
    if (p.depth == constants.cel_depth_max) return fail(B, p, .{ .kind = .too_deep });
    p.depth += 1;
    defer p.depth -= 1;
    const condition = try binary(B, p, 0);
    if (!take(B, p, "?")) return condition;
    const then = try binary(B, p, 0);
    try expect(B, p, ":");
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
    const first = p.ahead;
    if (!first.is("!") and !first.is("-")) return member(B, p);
    // "Unary = ... | '!' {'!'} Member | '-' {'-'} Member": a run of one operator.
    var count: usize = 0;
    for (0..p.tokens.text.len) |_| {
        if (!take(B, p, first.text)) break;
        count += 1;
    }
    const negates = first.is("-");
    // A "-" before an integer literal is the literal's sign, so the least int is written.
    const folded = negates and p.ahead.kind == .int;
    var value = if (folded) try negative(B, p) else try member(B, p);
    const op: UnaryOp = if (negates) .negate else .not;
    for (0..count - @intFromBool(folded)) |_| value = p.builder.unary(op, value);
    return value;
}

/// An integer literal after a "-", then what follows it.
fn negative(comptime B: type, p: *Reader(B)) Error!B.Value {
    return members(B, p, try negative_literal(B, p));
}

/// An integer literal after a "-", which is its sign.
fn negative_literal(comptime B: type, p: *Reader(B)) Error!B.Value {
    const token = advance(B, p);
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
        if (take(B, p, ".")) {
            value = try selection(B, p, value);
        } else if (take(B, p, "[")) {
            const at = try expression(B, p);
            try expect(B, p, "]");
            value = p.builder.index(value, at);
        } else return value;
    }
    return value;
}

/// What follows a ".": a field's name, or a function's name and its arguments.
fn selection(comptime B: type, p: *Reader(B), target: B.Value) Error!B.Value {
    const name = advance(B, p);
    // "SELECTOR ::= [_a-zA-Z][_a-zA-Z0-9]* - KEYWORD": a keyword names no field and no function.
    if (name.kind != .identifier or is_keyword(name.text)) return fail(B, p, .{ .kind = .expected_name, .token = name.text });
    if (!take(B, p, "(")) return p.builder.select(target, name.text);
    return p.builder.call(name.text, target, try list(B, p, ")", .no_last_comma));
}

/// Whether a comma may follow the last expression of a list: a list literal takes one
/// ("Primary = ... | '[' [ExprList] [','] ']'"), and a call's arguments take none.
const LastComma = enum { last_comma, no_last_comma };

/// The expressions up to `close`, with commas between them.
fn list(comptime B: type, p: *Reader(B), close: []const u8, last: LastComma) Error!B.Arguments {
    var arguments = p.builder.arguments();
    if (take(B, p, close)) return arguments;
    // Each turn passes an expression, so the text's length bounds the turns.
    for (0..p.tokens.text.len) |_| {
        p.builder.add(&arguments, try expression(B, p));
        if (take(B, p, close)) return arguments;
        try expect(B, p, ",");
        if (last == .last_comma and take(B, p, close)) return arguments;
    }
    return arguments;
}

/// "KEYWORD ::= BOOL_LIT | NULL_LIT | 'in'".
fn is_keyword(word: []const u8) bool {
    return in_words(&.{ "true", "false", "null", "in" }, word);
}

/// "RESERVED": the words a host language may hold, which name no variable and no function
/// but one called on a target, as `a.package()` is.
fn is_reserved(word: []const u8) bool {
    return in_words(&.{ "as", "break", "const", "continue", "else", "for", "function", "if", "import", "let", "loop", "package", "namespace", "return", "var", "void", "while" }, word);
}

fn in_words(words: []const []const u8, word: []const u8) bool {
    for (words) |each| {
        if (std.mem.eql(u8, each, word)) return true;
    }
    return false;
}

fn primary(comptime B: type, p: *Reader(B)) Error!B.Value {
    const token = advance(B, p);
    if (token.is("(")) {
        const inner = try expression(B, p);
        try expect(B, p, ")");
        return inner;
    }
    if (token.is("[")) return p.builder.list(try list(B, p, "]", .last_comma));
    // "INT_LIT ::= -? DIGIT+" and "FLOAT_LIT ::= -? ...": a number's sign is part of the
    // literal, so "!-5" reads. A "-" before any other part is the operator, which `unary` reads.
    if (token.is("-") and p.ahead.kind == .int) return negative_literal(B, p);
    if (token.is("-") and p.ahead.kind == .double) return p.builder.unary(.negate, try number(B, p, advance(B, p)));
    return switch (token.kind) {
        .identifier => named(B, p, token.text),
        .int, .uint, .double => number(B, p, token),
        .string, .bytes => p.builder.text_literal(token.kind, token.text) orelse fail(B, p, .{ .kind = .wrong_escape, .token = token.text }),
        .end => fail(B, p, .{ .kind = .ends_early }),
        else => fail(B, p, .{ .kind = .unexpected, .token = token.text }),
    };
}

/// An identifier: a constant's word, a function's name before its arguments, or a name.
fn named(comptime B: type, p: *Reader(B), name: []const u8) Error!B.Value {
    if (std.mem.eql(u8, name, "true")) return p.builder.boolean(true);
    if (std.mem.eql(u8, name, "false")) return p.builder.boolean(false);
    if (std.mem.eql(u8, name, "null")) return p.builder.nothing();
    if (std.mem.eql(u8, name, "in")) return fail(B, p, .{ .kind = .unexpected, .token = name });
    // "IDENT ::= SELECTOR - RESERVED".
    if (is_reserved(name)) return fail(B, p, .{ .kind = .reserved, .token = name });
    if (!take(B, p, "(")) return p.builder.name(name);
    return p.builder.call(name, null, try list(B, p, ")", .no_last_comma));
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
