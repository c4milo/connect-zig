//! The parser of a CEL expression at comptime (CEL language definition, "Syntax"). It runs the
//! grammar of `cel_grammar.zig` while the compiler reads a message's table, and gives the
//! expression's tree or what is wrong with its text. A problem is a value, so `rules_error`
//! reports it as it reports a rule that does not fit its field.
const std = @import("std");
const constants = @import("../constants.zig");
const token_file = @import("cel_token.zig");
const literal = @import("cel_literal.zig");
const node_file = @import("cel_node.zig");
const grammar = @import("cel_grammar.zig");
const Node = node_file.Node;
const BinaryOp = node_file.BinaryOp;
const UnaryOp = node_file.UnaryOp;

pub const Parsed = union(enum) { node: Node, problem: []const u8 };

/// The tree of `text`, or what is wrong with it.
pub fn parse(comptime text: []const u8) Parsed {
    return Kept(text).parsed;
}

/// The tree of `text`, which has no problem, at one address for each text: each reader of the
/// tree then asks the compiler the same question, which it answers once.
pub fn tree_of(comptime text: []const u8) *const Node {
    return &Kept(text).parsed.node;
}

/// One text's parse, which the compiler keeps for each use of the text.
fn Kept(comptime text: []const u8) type {
    return struct {
        const parsed: Parsed = read(text);
    };
}

fn read(comptime text: []const u8) Parsed {
    comptime {
        @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
        var reader = grammar.start(Builder, text, .{});
        const node = grammar.whole(Builder, &reader) catch return .{ .problem = problem_text(reader.problem) };
        return .{ .node = node };
    }
}

fn problem_text(comptime problem: grammar.Problem) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (problem.pieces()) |piece| text = text ++ piece;
        return text;
    }
}

/// Builds the tree in the compiler's memory: each part is a constant, and a part points to the
/// parts it holds.
const Builder = struct {
    pub const Value = Node;
    pub const Arguments = []const Node;

    pub fn int(_: Builder, value: i64) Node {
        return .{ .int = value };
    }

    pub fn uint(_: Builder, value: u64) Node {
        return .{ .uint = value };
    }

    pub fn double(_: Builder, value: f64, _: []const u8) Node {
        return .{ .double = value };
    }

    pub fn boolean(_: Builder, value: bool) Node {
        return .{ .boolean = value };
    }

    pub fn nothing(_: Builder) Node {
        return .null;
    }

    pub fn name(_: Builder, text: []const u8) Node {
        return .{ .name = text };
    }

    /// A string's or a bytes literal's octets, or null for a wrong escape.
    pub fn text_literal(_: Builder, comptime kind: token_file.Kind, comptime text: []const u8) ?Node {
        var buffer = [_]u8{0} ** text.len;
        const octets = literal.unescape(text, &buffer) catch return null;
        const kept = octets[0..octets.len].*;
        if (kind == .bytes) return .{ .bytes = &kept };
        return .{ .string = &kept };
    }

    pub fn select(_: Builder, comptime of: Node, field: []const u8) Node {
        return .{ .select = .{ .of = &of, .field = field } };
    }

    pub fn index(_: Builder, comptime of: Node, comptime at: Node) Node {
        return .{ .index = .{ .of = &of, .at = &at } };
    }

    pub fn unary(_: Builder, op: UnaryOp, comptime of: Node) Node {
        return .{ .unary = .{ .op = op, .of = &of } };
    }

    pub fn binary(_: Builder, op: BinaryOp, comptime left: Node, comptime right: Node) Node {
        return .{ .binary = .{ .op = op, .left = &left, .right = &right } };
    }

    pub fn conditional(_: Builder, comptime condition: Node, comptime then: Node, comptime otherwise: Node) Node {
        return .{ .conditional = .{ .condition = &condition, .then = &then, .otherwise = &otherwise } };
    }

    pub fn arguments(_: Builder) Arguments {
        return &.{};
    }

    pub fn add(_: Builder, comptime list_so_far: *Arguments, comptime value: Node) void {
        list_so_far.* = list_so_far.* ++ [_]Node{value};
    }

    pub fn call(_: Builder, call_name: []const u8, comptime target: ?Node, comptime call_arguments: Arguments) Node {
        if (target) |of| return .{ .call = .{ .name = call_name, .target = &of, .arguments = call_arguments } };
        return .{ .call = .{ .name = call_name, .arguments = call_arguments } };
    }

    pub fn list(_: Builder, comptime elements: Arguments) Node {
        return .{ .list = elements };
    }
};

const testing = std.testing;

/// The tree of `text` as `render` writes it, or its problem after "problem: ".
fn shown(comptime text: []const u8) []const u8 {
    comptime {
        // The text of a double takes the compiler more branches than it allows by default.
        @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
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
    try testing.expectEqualStrings("(-(-9223372036854775807))", comptime shown("--9223372036854775807"));
    // A negation of an int in brackets is no literal's sign.
    try testing.expectEqualStrings("(-(5))", comptime shown("-(5)"));
    try testing.expectEqualStrings("(-5u)", comptime shown("-5u"));
    try testing.expectEqualStrings("(a - 1)", comptime shown("a - 1"));
    try testing.expectEqualStrings("(a - -1)", comptime shown("a - -1"));
    // A number's sign is part of its literal, so a "!" takes a negative number, and no other
    // part that starts with "-".
    try testing.expectEqualStrings("(!-5)", comptime shown("!-5"));
    try testing.expectEqualStrings("(!(!(-1.5e0)))", comptime shown("!!-1.5"));
    try testing.expectEqualStrings("(!-5.a)", comptime shown("!-5.a"));
    try testing.expectEqualStrings("problem: unexpected `-`", comptime shown("!-a"));
    try testing.expectEqualStrings("problem: unexpected `-`", comptime shown("!-5u"));
    try testing.expectEqualStrings("problem: unexpected `!`", comptime shown("-!a"));
}

test "a member is a selection, a call with its arguments, or an index" {
    try testing.expectEqualStrings("this.a.b", comptime shown("this.a.b"));
    try testing.expectEqualStrings("this.all(k, (this[k] == 1))", comptime shown("this.all(k, this[k] == 1)"));
    try testing.expectEqualStrings("has(this.version)", comptime shown("has(this.version)"));
    try testing.expectEqualStrings("this.val.isIp()", comptime shown("this.val.isIp()"));
    try testing.expectEqualStrings("(this in [1, 2u, 3.5e0])", comptime shown("this in [1, 2u, 3.5]"));
    try testing.expectEqualStrings("[]", comptime shown("[]"));
    // "Primary = ... | '[' [ExprList] [','] ']'": a list literal takes a comma after its last
    // element, and a call's arguments take none.
    try testing.expectEqualStrings("[1, 2]", comptime shown("[1, 2,]"));
    try testing.expectEqualStrings("problem: unexpected `,`", comptime shown("[,]"));
    try testing.expectEqualStrings("problem: unexpected `,`", comptime shown("[1,,]"));
    try testing.expectEqualStrings("problem: unexpected `)`", comptime shown("f(1,)"));
    // A reserved word names a function called on a target and a field, and no other thing.
    try testing.expectEqualStrings("a.package()", comptime shown("a.package()"));
    try testing.expectEqualStrings("a.for", comptime shown("a.for"));
    try testing.expectEqualStrings("f(a, b)[0].c", comptime shown("f(a, b)[0].c"));
    try testing.expectEqualStrings("(uint(this.size()) >= 5u)", comptime shown("uint(this.size()) >= 5u"));
}

test "a literal is a number, a string, bytes, a boolean or null" {
    try testing.expectEqualStrings("[1, 31, 2u, 1.5e0, true, false, null]", comptime shown("[1, 0x1f, 2u, 1.5, true, false, null]"));
    // A string and a bytes literal are written with the escapes that read back as their octets.
    try testing.expectEqualStrings("['it\\'s', b'\\xff', '\\\\d']", comptime shown("['it\\'s', b'\\xff', r'\\d']"));
    try testing.expectEqualStrings("'a\\nb'", comptime shown("'''a\nb'''"));
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
    // "IDENT ::= SELECTOR - RESERVED" and "SELECTOR ::= ... - KEYWORD".
    try testing.expectEqualStrings("problem: `as` is a reserved word", comptime shown("as"));
    try testing.expectEqualStrings("problem: `while` is a reserved word", comptime shown("1 + while(x)"));
    try testing.expectEqualStrings("problem: expected a name after `.`, before `true`", comptime shown("a.true"));
    try testing.expectEqualStrings("problem: expected a name after `.`, before `in`", comptime shown("a.in(b)"));
    try testing.expectEqualStrings("problem: the number `1e999` is out of range", comptime shown("1e999"));
    try testing.expectEqualStrings("problem: unexpected `X1F`", comptime shown("0X1F"));
    try testing.expectEqualStrings("problem: unexpected `#`", comptime shown("#"));
    try testing.expectEqualStrings("problem: the number `9223372036854775808` is out of range", comptime shown("9223372036854775808"));
    try testing.expectEqualStrings("problem: the number `-9223372036854775809` is not an int", comptime shown("-9223372036854775809"));
    try testing.expectEqualStrings("problem: the literal '\\q' holds a wrong escape", comptime shown("'\\q'"));
    try testing.expectEqualStrings("problem: the expression nests too deep", comptime shown("(" ** constants.cel_depth_max ++ "a" ++ ")" ** constants.cel_depth_max));
    // One level fewer is read.
    try testing.expect(comptime parse("(" ** (constants.cel_depth_max - 1) ++ "a" ++ ")" ** (constants.cel_depth_max - 1)) == .node);
}
