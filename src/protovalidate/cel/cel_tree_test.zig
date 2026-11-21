//! Tests of the grammar at run time, over the tree of `cel_tree.zig`:
//!
//! - The tree a test reads of an expression is the tree the compiler reads of it.
//! - A parse depends on the expression's text alone: what its storage held before does not
//!   change it.
//! - A tree's text is an expression that reads back as the same tree.
//! - A fuzz property holds the last two, and the tokens' reader, on any input. `zig build
//!   test` runs it over its corpus, and `zig build test-protovalidate -Drelease --fuzz=<runs>`
//!   under Zig's fuzzer.
//! - The vectors of the Lean model, `cel_vectors.txt`, name the tree of each expression, which
//!   this grammar must give (spec/README.md).
const std = @import("std");
const testing = std.testing;
const constants = @import("../constants.zig");
const token_file = @import("cel_token.zig");
const node_file = @import("cel_node.zig");
const parser = @import("cel_parse.zig");
const tree_file = @import("cel_tree.zig");
const Doubles = tree_file.Doubles;

/// The most octets one fuzz input holds.
const input_len_max = 96;
/// The most octets a tree's text takes for each octet of its expression: an octet of a bytes
/// literal is written as four, and an operator gains two brackets and two spaces.
const written_per_octet = 8;
const written_len_max = input_len_max * written_per_octet;
/// What the storage of a parse holds before it, in turn: a parse reads none of it. The
/// patterns are no octets, each second bit, and each other second bit.
const fill_second_bits = 0xaa;
const fill_other_bits = 0x55;
const fills = [_]u8{ 0, fill_second_bits, fill_other_bits };

/// Storage for the tree of a text of at most `written_len_max` octets.
const Storage = struct {
    items: [written_len_max]tree_file.Item,
    links: [written_len_max]tree_file.Index,
    pending: [written_len_max]tree_file.Index,
    octets: [written_len_max]u8,

    fn tree(storage: *Storage) tree_file.Tree {
        return .{ .items = &storage.items, .links = &storage.links, .pending = &storage.pending, .octets = &storage.octets };
    }
};

/// The text of the tree of `text`, or its problem after "problem: ", in storage that holds
/// `fill` in each octet before the parse.
fn shown(text: []const u8, fill: u8, doubles: Doubles, out: []u8) ![]const u8 {
    var storage: Storage = undefined;
    @memset(std.mem.asBytes(&storage), fill);
    var tree = storage.tree();
    var writer: std.Io.Writer = .fixed(out);
    switch (tree_file.parse(&tree, text)) {
        .root => |root| try tree_file.write(&tree, root, doubles, &writer),
        .problem => |problem| {
            try writer.writeAll("problem: ");
            for (problem.pieces()) |piece| try writer.writeAll(piece);
        },
    }
    return writer.buffered();
}

/// What the compiler reads of `text`, as `shown` writes it.
fn compiled(comptime text: []const u8) []const u8 {
    comptime {
        // The text of a double takes the compiler more branches than it allows by default.
        @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
        return switch (parser.parse(text)) {
            .node => |node| node_file.render(&node),
            .problem => |problem| "problem: " ++ problem,
        };
    }
}

/// Expressions of each kind of part, and texts with each kind of problem.
const corpus = [_][]const u8{
    "this",
    "this.a.b",
    "a || b && c || d",
    "a < b + c * d && e in f",
    "a - b - c",
    "a / b % c * d",
    "(a + b) * c",
    "a == b != c",
    "a <= b >= c",
    "a || b ? c : d ? e : f",
    "this > 24 ? '' : 'a must be greater than 24'",
    "!a && !!b",
    "-a - --b",
    "-a.b",
    "-9223372036854775808",
    "--9223372036854775807",
    "-(5)",
    "-5u",
    "-1.5",
    "a - -1",
    "this.all(k, this[k] == 1)",
    "has(this.version)",
    "this.val.isIp()",
    "this in [1, 2u, 3.5]",
    "[]",
    "[1, 2,]",
    "f(a, b)[0].c",
    "uint(this.size()) >= 5u",
    "[1, 0x1f, 2u, 1.5, .5, 2e3, 1E-3, true, false, null]",
    "['it\\'s', b'\\xff\\000', r'\\d', br'\\x', \"q'q\", '\\u00e9\\U0001f600']",
    "'''many\nlines''' + \"\"\"more\"\"\"",
    // A surrogate is no character, and reads as U+FFFD.
    "'\\ud800' == '\\x41\\101\\u0041'",
    "duration('10s') >= this",
    "this.matches('^[a-z]+$') // a comment",
    "a.package() && a.for",
    "!this.startsWith('x') ? 'must start with x: `%s`'.format([this]) : ''",
    "this.f1.size() + this.f199.size() < 1000",
    "",
    "a &&",
    "a )",
    "a b",
    "(a",
    "a ? b",
    "a[1)",
    "f(a b)",
    "f(1,)",
    "[,]",
    "a. 1",
    "a.true",
    "{}",
    "in",
    "as",
    "#",
    "'a\nb'",
    "rb'x'",
    "0X1F",
    "1e999",
    "9223372036854775808",
    "-9223372036854775809",
    "'\\q'",
    "b'\\u0041'",
    "((((((((((((((((((((((((((((((((a))))))))))))))))))))))))))))))))",
};

test "the tree a test reads at run time is the tree the compiler reads" {
    inline for (corpus) |text| {
        var out: [written_len_max]u8 = undefined;
        try testing.expectEqualStrings(comptime compiled(text), try shown(text, fills[0], .values, &out));
    }
}

test "a double is written as its value, or as its text in the expression" {
    var out: [written_len_max]u8 = undefined;
    try testing.expectEqualStrings("[1.5e0, 5e-1, 2e3]", try shown("[1.50, .5, 2000.0]", fills[0], .values, &out));
    try testing.expectEqualStrings("[1.50, .5, 2000.0]", try shown("[1.50, .5, 2000.0]", fills[0], .texts, &out));
}

/// Each token is the text the reader just passed, and the reader ends at the text's end.
fn check_tokens(text: []const u8) !void {
    var tokens: token_file.Tokens = .{ .text = text };
    var before: usize = 0;
    for (0..text.len + 1) |_| {
        const token = tokens.next();
        if (token.kind == .end) {
            try testing.expectEqual(text.len, tokens.at);
            return;
        }
        try testing.expect(token.text.len != 0);
        try testing.expect(tokens.at > before and tokens.at <= text.len);
        try testing.expectEqual(@intFromPtr(text.ptr) + tokens.at - token.text.len, @intFromPtr(token.text.ptr));
        before = tokens.at;
    }
    return error.TokensDidNotEnd;
}

/// A parse of `text` gives one result whatever its storage held, and the text of its tree
/// reads back as the same tree.
fn check_parse(text: []const u8, doubles: Doubles) !void {
    var outs: [fills.len][written_len_max]u8 = undefined;
    const first = try shown(text, fills[0], doubles, &outs[0]);
    for (fills[1..], outs[1..]) |fill, *out| try testing.expectEqualStrings(first, try shown(text, fill, doubles, out));
    if (std.mem.startsWith(u8, first, "problem: ")) return;
    const again = try shown(first, fills[1], doubles, &outs[1]);
    // The text holds each part in brackets, which nest deeper than the expression did.
    if (std.mem.eql(u8, again, "problem: the expression nests too deep")) return;
    try testing.expectEqualStrings(first, again);
}

fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
    var input: [input_len_max]u8 = @splat(0);
    const len = smith.slice(&input);
    const text = input[0..len];
    try check_tokens(text);
    try check_parse(text, .values);
    try check_parse(text, .texts);
}

test "fuzz: a parse depends on its text alone, and a tree's text reads back as the tree" {
    try testing.fuzz({}, fuzz_one, .{ .corpus = &corpus });
}

test "each expression of the corpus holds the fuzz property" {
    for (corpus) |text| {
        try check_tokens(text);
        try check_parse(text, .values);
        try check_parse(text, .texts);
    }
}

/// The octets that a column of the vector file states: "%" and two hexadecimal digits are one
/// octet, and any other octet is itself.
fn column(text: []const u8, out: []u8) ![]const u8 {
    var len: usize = 0;
    var at: usize = 0;
    for (0..text.len) |_| {
        if (at == text.len) break;
        if (text[at] == '%') {
            out[len] = try std.fmt.parseInt(u8, text[at + 1 ..][0..constants.pct_encoded_digits], constants.hexadecimal_base);
            at += 1 + constants.pct_encoded_digits;
        } else {
            out[len] = text[at];
            at += 1;
        }
        len += 1;
    }
    return out[0..len];
}

/// One line of the vector file: an expression, a tab, and its tree's text or "!".
fn check_vector(line: []const u8) !void {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.NoTab;
    var expression_room: [written_len_max]u8 = undefined;
    var expected_room: [written_len_max]u8 = undefined;
    var out: [written_len_max]u8 = undefined;
    const expression = try column(line[0..tab], &expression_room);
    const expected = try column(line[tab + 1 ..], &expected_room);
    const read = try shown(expression, fills[0], .texts, &out);
    if (std.mem.eql(u8, expected, "!")) {
        try testing.expect(std.mem.startsWith(u8, read, "problem: "));
    } else try testing.expectEqualStrings(expected, read);
}

test "the grammar reads each expression of the Lean model's vectors as the model does" {
    const vectors = @embedFile("cel_vectors.txt");
    var rest: []const u8 = vectors;
    var checked: usize = 0;
    for (0..vectors.len) |number| {
        if (rest.len == 0) break;
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..end];
        rest = rest[@min(end + 1, rest.len)..];
        // The file's first line says what the file holds. An expression may start with "#".
        if (number == 0) continue;
        check_vector(line) catch |failure| {
            std.debug.print("cel_vectors.txt line {d}: {s}\n", .{ number + 1, line });
            return failure;
        };
        checked += 1;
    }
    try testing.expectEqual(@as(usize, vectors_len), checked);
}
/// The vectors the file holds: a file cut short fails.
const vectors_len = 6647;
