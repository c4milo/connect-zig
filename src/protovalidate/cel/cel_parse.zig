//! The parser of a CEL expression (CEL language definition, "Syntax"). It runs while the
//! compiler reads a message's table, and gives the expression's tree or what is wrong with its
//! text. A problem is a value, so `rules_error` reports it as it reports a rule that does not
//! fit its field.
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
const Node = node_file.Node;
const BinaryOp = node_file.BinaryOp;
const Token = token_file.Token;

pub const Parsed = union(enum) { node: Node, problem: []const u8 };

const Error = error{Syntax};

/// The tree of `text`, or what is wrong with it.
pub fn parse(comptime text: []const u8) Parsed {
    comptime {
        @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
        var parser: Parser = .{ .tokens = .{ .text = text } };
        const node = parser.expression() catch return .{ .problem = parser.problem };
        const rest = parser.tokens.next();
        if (rest.kind != .end) return .{ .problem = "unexpected `" ++ rest.text ++ "`" };
        return .{ .node = node };
    }
}

/// The operators of each level of the grammar, the loosest first.
const levels = [_][]const BinaryOp{
    &.{.@"or"},
    &.{.@"and"},
    &.{ .less_or_equal, .greater_or_equal, .equal, .not_equal, .less, .greater, .in },
    &.{ .add, .subtract },
    &.{ .multiply, .divide, .modulo },
};

const Parser = struct {
    tokens: token_file.Tokens,
    depth: usize = 0,
    problem: []const u8 = "",

    fn fail(comptime p: *Parser, comptime problem: []const u8) Error {
        p.problem = problem;
        return error.Syntax;
    }

    fn expect(comptime p: *Parser, comptime mark: []const u8) Error!void {
        const token = p.tokens.next();
        if (!token.is(mark)) return p.fail("expected `" ++ mark ++ "` before `" ++ token.text ++ "`");
    }

    fn take(comptime p: *Parser, comptime mark: []const u8) bool {
        if (!p.tokens.peek().is(mark)) return false;
        _ = p.tokens.next();
        return true;
    }

    fn expression(comptime p: *Parser) Error!Node {
        if (p.depth == constants.cel_depth_max) return p.fail("the expression nests too deep");
        p.depth += 1;
        defer p.depth -= 1;
        const condition = try p.binary(0);
        if (!p.take("?")) return condition;
        const then = try p.binary(0);
        try p.expect(":");
        const otherwise = try p.expression();
        return .{ .conditional = .{ .condition = &condition, .then = &then, .otherwise = &otherwise } };
    }

    /// One level of binary operators, which group from the left: "a - b - c" is "(a - b) - c".
    fn binary(comptime p: *Parser, comptime level: usize) Error!Node {
        if (level == levels.len) return p.unary();
        var left = try p.binary(level + 1);
        for (0..p.tokens.text.len) |_| {
            const op = operator_of(level, p.tokens.peek()) orelse return left;
            _ = p.tokens.next();
            const right = try p.binary(level + 1);
            const before = left;
            left = .{ .binary = .{ .op = op, .left = &before, .right = &right } };
        }
        return left;
    }

    fn unary(comptime p: *Parser) Error!Node {
        const first = p.tokens.peek();
        if (!first.is("!") and !first.is("-")) return p.member();
        // "Unary = ... | '!' {'!'} Member | '-' {'-'} Member": a run of one operator.
        var count: usize = 0;
        for (0..p.tokens.text.len) |_| {
            if (!p.take(first.text)) break;
            count += 1;
        }
        const negates = first.is("-");
        // A "-" before an integer literal is the literal's sign, so the least int is written.
        const folded = negates and p.tokens.peek().kind == .int;
        var node = if (folded) try p.negative() else try p.member();
        for (0..count - @intFromBool(folded)) |_| {
            const before = node;
            node = .{ .unary = .{ .op = if (negates) .negate else .not, .of = &before } };
        }
        return node;
    }

    /// An integer literal after a "-", then what follows it.
    fn negative(comptime p: *Parser) Error!Node {
        const token = p.tokens.next();
        const value = literal.magnitude(token.text) catch return p.fail("the number `" ++ token.text ++ "` is not an int");
        const least: u64 = @as(u64, std.math.maxInt(i64)) + 1;
        if (value > least) return p.fail("the number `-" ++ token.text ++ "` is not an int");
        const signed: i64 = if (value == least) std.math.minInt(i64) else -@as(i64, @intCast(value));
        return p.members(.{ .int = signed });
    }

    fn member(comptime p: *Parser) Error!Node {
        return p.members(try p.primary());
    }

    /// The selections, the calls and the indexes after `first`.
    fn members(comptime p: *Parser, comptime first: Node) Error!Node {
        var node = first;
        for (0..p.tokens.text.len) |_| {
            const before = node;
            if (p.take(".")) {
                node = try p.selection(&before);
            } else if (p.take("[")) {
                const at = try p.expression();
                try p.expect("]");
                node = .{ .index = .{ .of = &before, .at = &at } };
            } else return node;
        }
        return node;
    }

    /// What follows a ".": a field's name, or a function's name and its arguments.
    fn selection(comptime p: *Parser, comptime target: *const Node) Error!Node {
        const name = p.tokens.next();
        if (name.kind != .identifier) return p.fail("expected a name after `.`, before `" ++ name.text ++ "`");
        if (!p.take("(")) return .{ .select = .{ .of = target, .field = name.text } };
        return .{ .call = .{ .name = name.text, .target = target, .arguments = try p.list(")") } };
    }

    /// The expressions up to `close`, with commas between them.
    fn list(comptime p: *Parser, comptime close: []const u8) Error![]const Node {
        var nodes: []const Node = &.{};
        if (p.take(close)) return nodes;
        for (0..p.tokens.text.len) |_| {
            nodes = nodes ++ [_]Node{try p.expression()};
            if (p.take(close)) return nodes;
            try p.expect(",");
        }
        return nodes;
    }

    fn primary(comptime p: *Parser) Error!Node {
        const token = p.tokens.next();
        if (token.is("(")) {
            const inner = try p.expression();
            try p.expect(")");
            return inner;
        }
        if (token.is("[")) return .{ .list = try p.list("]") };
        return switch (token.kind) {
            .identifier => p.named(token.text),
            .int, .uint, .double => p.number(token),
            .string, .bytes => p.text_literal(token),
            .end => p.fail("the expression ends early"),
            else => p.fail("unexpected `" ++ token.text ++ "`"),
        };
    }

    /// An identifier: a constant's word, a function's name before its arguments, or a name.
    fn named(comptime p: *Parser, comptime name: []const u8) Error!Node {
        if (std.mem.eql(u8, name, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, name, "false")) return .{ .boolean = false };
        if (std.mem.eql(u8, name, "null")) return .null;
        if (std.mem.eql(u8, name, "in")) return p.fail("unexpected `in`");
        if (!p.take("(")) return .{ .name = name };
        return .{ .call = .{ .name = name, .arguments = try p.list(")") } };
    }

    fn number(comptime p: *Parser, comptime token: Token) Error!Node {
        const problem = "the number `" ++ token.text ++ "` is out of range";
        switch (token.kind) {
            .double => return .{ .double = literal.double(token.text) catch return p.fail(problem) },
            .uint => return .{ .uint = literal.magnitude(token.text[0 .. token.text.len - 1]) catch return p.fail(problem) },
            else => {
                const value = literal.magnitude(token.text) catch return p.fail(problem);
                if (value > std.math.maxInt(i64)) return p.fail(problem);
                return .{ .int = @intCast(value) };
            },
        }
    }

    fn text_literal(comptime p: *Parser, comptime token: Token) Error!Node {
        var buffer = [_]u8{0} ** token.text.len;
        const octets = literal.unescape(token.text, &buffer) catch return p.fail("the literal " ++ token.text ++ " holds a wrong escape");
        const kept = octets[0..octets.len].*;
        if (token.kind == .bytes) return .{ .bytes = &kept };
        return .{ .string = &kept };
    }
};

fn operator_of(comptime level: usize, comptime token: Token) ?BinaryOp {
    for (levels[level]) |op| {
        if (op == .in) {
            if (token.is_word("in")) return op;
        } else if (token.is(op.text())) return op;
    }
    return null;
}

const testing = std.testing;

/// The tree of `text` as `render` writes it, or its problem after "problem: ".
fn shown(comptime text: []const u8) []const u8 {
    comptime {
        return switch (parse(text)) {
            .node => |node| node_file.render(&node),
            .problem => |problem| "problem: " ++ problem,
        };
    }
}

test "operators group by their level, and from the left within one" {
    try testing.expectEqualStrings("((a || (b && c)) || d)", comptime shown("a || b && c || d"));
    try testing.expectEqualStrings("((a < (b + (c * d))) && (e in f))", comptime shown("a < b + c * d && e in f"));
    try testing.expectEqualStrings("((a - b) - c)", comptime shown("a - b - c"));
    try testing.expectEqualStrings("(((a / b) % c) * d)", comptime shown("a / b % c * d"));
    try testing.expectEqualStrings("((a + b) * c)", comptime shown("(a + b) * c"));
    try testing.expectEqualStrings("((a == b) != c)", comptime shown("a == b != c"));
    try testing.expectEqualStrings("((a <= b) >= c)", comptime shown("a <= b >= c"));
    try testing.expectEqualStrings("(a > b)", comptime shown("a > b"));
}

test "a conditional takes the loosest level, and its last part is a whole expression" {
    try testing.expectEqualStrings("((a || b) ? c : (d ? e : f))", comptime shown("a || b ? c : d ? e : f"));
    try testing.expectEqualStrings("((this > 24) ? '' : 'a must be greater than 24')", comptime shown("this > 24 ? '' : 'a must be greater than 24'"));
}

test "a unary operator binds tighter than a binary one, and repeats" {
    try testing.expectEqualStrings("((!a) && (!(!b)))", comptime shown("!a && !!b"));
    try testing.expectEqualStrings("((-a) - (-(-b)))", comptime shown("-a - --b"));
    try testing.expectEqualStrings("(-a.b)", comptime shown("-a.b"));
    // A "-" before an integer is its sign, which the least int needs.
    try testing.expectEqualStrings("-9223372036854775808", comptime shown("-9223372036854775808"));
    try testing.expectEqualStrings("(--9223372036854775807)", comptime shown("--9223372036854775807"));
    try testing.expectEqualStrings("(a - 1)", comptime shown("a - 1"));
    try testing.expectEqualStrings("(a - -1)", comptime shown("a - -1"));
}

test "a member is a selection, a call with its arguments, or an index" {
    try testing.expectEqualStrings("this.a.b", comptime shown("this.a.b"));
    try testing.expectEqualStrings("this.all(k, (this[k] == 1))", comptime shown("this.all(k, this[k] == 1)"));
    try testing.expectEqualStrings("has(this.version)", comptime shown("has(this.version)"));
    try testing.expectEqualStrings("this.val.isIp()", comptime shown("this.val.isIp()"));
    try testing.expectEqualStrings("(this in [1, 2u, 3.5])", comptime shown("this in [1, 2u, 3.5]"));
    try testing.expectEqualStrings("[]", comptime shown("[]"));
    try testing.expectEqualStrings("f(a, b)[0].c", comptime shown("f(a, b)[0].c"));
    try testing.expectEqualStrings("(uint(this.size()) >= 5u)", comptime shown("uint(this.size()) >= 5u"));
}

test "a literal is a number, a string, bytes, a boolean or null" {
    try testing.expectEqualStrings("[1, 31, 2u, 1.5, true, false, null]", comptime shown("[1, 0x1f, 2u, 1.5, true, false, null]"));
    try testing.expectEqualStrings("['it's', b'\xff', '\\d']", comptime shown("['it\\'s', b'\\xff', r'\\d']"));
    try testing.expectEqualStrings("(duration('10s') >= this)", comptime shown("duration('10s') >= this"));
}

test "a wrong expression gives its problem" {
    try testing.expectEqualStrings("problem: the expression ends early", comptime shown("a &&"));
    try testing.expectEqualStrings("problem: the expression ends early", comptime shown(""));
    try testing.expectEqualStrings("problem: unexpected `)`", comptime shown("a )"));
    try testing.expectEqualStrings("problem: unexpected `b`", comptime shown("a b"));
    try testing.expectEqualStrings("problem: expected `)` before ``", comptime shown("(a"));
    try testing.expectEqualStrings("problem: expected `:` before ``", comptime shown("a ? b"));
    try testing.expectEqualStrings("problem: expected `]` before `)`", comptime shown("a[1)"));
    try testing.expectEqualStrings("problem: expected `,` before `b`", comptime shown("f(a b)"));
    try testing.expectEqualStrings("problem: expected a name after `.`, before `1`", comptime shown("a. 1"));
    try testing.expectEqualStrings("problem: unexpected `{`", comptime shown("{}"));
    try testing.expectEqualStrings("problem: unexpected `in`", comptime shown("in"));
    try testing.expectEqualStrings("problem: unexpected `#`", comptime shown("#"));
    try testing.expectEqualStrings("problem: the number `9223372036854775808` is out of range", comptime shown("9223372036854775808"));
    try testing.expectEqualStrings("problem: the number `-9223372036854775809` is not an int", comptime shown("-9223372036854775809"));
    try testing.expectEqualStrings("problem: the literal '\\q' holds a wrong escape", comptime shown("'\\q'"));
    try testing.expectEqualStrings("problem: the expression nests too deep", comptime shown("(" ** constants.cel_depth_max ++ "a" ++ ")" ** constants.cel_depth_max));
    // One level fewer is read.
    try testing.expect(comptime parse("(" ** (constants.cel_depth_max - 1) ++ "a" ++ ")" ** (constants.cel_depth_max - 1)) == .node);
}
