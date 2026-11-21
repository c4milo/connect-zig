//! A CEL expression's tree in storage that its caller passes, which the grammar of
//! `cel_grammar.zig` builds at run time. The compiler does not use it: the compiler's tree
//! lies in its own memory (`cel_parse.zig`). A test reads an expression with this builder, so
//! a fuzzer and the vectors of the Lean model check the grammar's own code and not a copy.
//!
//! A part names the parts it holds by their place in `items`. Each part takes one token of
//! the text at least, so storage of the text's length holds any tree the text gives.
const std = @import("std");
const assert = std.debug.assert;
const token_file = @import("cel_token.zig");
const literal = @import("cel_literal.zig");
const node_file = @import("cel_node.zig");
const grammar = @import("cel_grammar.zig");
const BinaryOp = node_file.BinaryOp;
const UnaryOp = node_file.UnaryOp;

/// The place of a part in a tree's `items`.
pub const Index = u32;

/// The parts of a call or of a list literal: `len` places in a tree's `links`, from `start`.
pub const Span = struct { start: usize, len: usize };

pub const Item = union(enum) {
    int: i64,
    uint: u64,
    double: Double,
    boolean: bool,
    /// A string literal's octets, in the tree's `octets`.
    string: []const u8,
    bytes: []const u8,
    null,
    /// An identifier, in the expression's text.
    name: []const u8,
    select: struct { of: Index, field: []const u8 },
    index: struct { of: Index, at: Index },
    unary: struct { op: UnaryOp, of: Index },
    binary: struct { op: BinaryOp, left: Index, right: Index },
    conditional: struct { condition: Index, then: Index, otherwise: Index },
    call: struct { name: []const u8, target: ?Index, arguments: Span },
    list: Span,

    /// A double literal's value, and its text in the expression.
    pub const Double = struct { value: f64, text: []const u8 };
};

pub const Tree = struct {
    items: []Item,
    /// The parts of each call and of each list literal, one after another.
    links: []Index,
    /// The parts read of the calls and the list literals that are still open.
    pending: []Index,
    /// The octets of each string and of each bytes literal.
    octets: []u8,
    item_count: usize = 0,
    link_count: usize = 0,
    pending_count: usize = 0,
    octet_count: usize = 0,

    /// Whether the tree's storage holds any tree that a text of `text_len` octets gives.
    pub fn holds(tree: *const Tree, text_len: usize) bool {
        return tree.items.len >= text_len and tree.links.len >= text_len and tree.pending.len >= text_len and tree.octets.len >= text_len;
    }

    fn put(tree: *Tree, item: Item) Index {
        assert(tree.item_count < tree.items.len);
        tree.items[tree.item_count] = item;
        tree.item_count += 1;
        return @intCast(tree.item_count - 1);
    }

    /// Moves the parts read since `mark` from `pending` to `links`, and gives their span.
    fn close(tree: *Tree, mark: usize) Span {
        assert(mark <= tree.pending_count);
        const parts = tree.pending[mark..tree.pending_count];
        assert(parts.len <= tree.links.len - tree.link_count);
        const span: Span = .{ .start = tree.link_count, .len = parts.len };
        @memcpy(tree.links[span.start..][0..span.len], parts);
        tree.link_count += span.len;
        tree.pending_count = mark;
        return span;
    }
};

/// What a text gives: the place of its tree's root, or what is wrong with it.
pub const Parsed = union(enum) { root: Index, problem: grammar.Problem };

/// Reads `text` into `tree`, which holds nothing yet and has room for a text of this length.
pub fn parse(tree: *Tree, text: []const u8) Parsed {
    assert(tree.holds(text.len));
    assert(tree.item_count == 0 and tree.link_count == 0 and tree.pending_count == 0 and tree.octet_count == 0);
    var reader = grammar.start(Builder, text, .{ .tree = tree });
    const root = grammar.whole(Builder, &reader) catch return .{ .problem = reader.problem };
    assert(tree.pending_count == 0);
    return .{ .root = root };
}

/// The grammar's builder over a `Tree`.
pub const Builder = struct {
    tree: *Tree,

    pub const Value = Index;
    /// Where the parts of an open call or list literal start in the tree's `pending`.
    pub const Arguments = struct { mark: usize };

    pub fn int(b: Builder, value: i64) Index {
        return b.tree.put(.{ .int = value });
    }

    pub fn uint(b: Builder, value: u64) Index {
        return b.tree.put(.{ .uint = value });
    }

    pub fn double(b: Builder, value: f64, text: []const u8) Index {
        return b.tree.put(.{ .double = .{ .value = value, .text = text } });
    }

    pub fn boolean(b: Builder, value: bool) Index {
        return b.tree.put(.{ .boolean = value });
    }

    pub fn nothing(b: Builder) Index {
        return b.tree.put(.null);
    }

    pub fn name(b: Builder, text: []const u8) Index {
        return b.tree.put(.{ .name = text });
    }

    /// A string's or a bytes literal's octets, or null for a wrong escape. A literal states no
    /// more octets than its own text holds, so the room left takes it.
    pub fn text_literal(b: Builder, kind: token_file.Kind, text: []const u8) ?Index {
        const room = b.tree.octets[b.tree.octet_count..];
        assert(room.len >= text.len);
        const octets = literal.unescape(text, room) catch return null;
        b.tree.octet_count += octets.len;
        if (kind == .bytes) return b.tree.put(.{ .bytes = octets });
        return b.tree.put(.{ .string = octets });
    }

    pub fn select(b: Builder, of: Index, field: []const u8) Index {
        return b.tree.put(.{ .select = .{ .of = of, .field = field } });
    }

    pub fn index(b: Builder, of: Index, at: Index) Index {
        return b.tree.put(.{ .index = .{ .of = of, .at = at } });
    }

    pub fn unary(b: Builder, op: UnaryOp, of: Index) Index {
        return b.tree.put(.{ .unary = .{ .op = op, .of = of } });
    }

    pub fn binary(b: Builder, op: BinaryOp, left: Index, right: Index) Index {
        return b.tree.put(.{ .binary = .{ .op = op, .left = left, .right = right } });
    }

    pub fn conditional(b: Builder, condition: Index, then: Index, otherwise: Index) Index {
        return b.tree.put(.{ .conditional = .{ .condition = condition, .then = then, .otherwise = otherwise } });
    }

    pub fn arguments(b: Builder) Arguments {
        return .{ .mark = b.tree.pending_count };
    }

    pub fn add(b: Builder, _: *Arguments, value: Index) void {
        assert(b.tree.pending_count < b.tree.pending.len);
        b.tree.pending[b.tree.pending_count] = value;
        b.tree.pending_count += 1;
    }

    pub fn call(b: Builder, call_name: []const u8, target: ?Index, call_arguments: Arguments) Index {
        return b.tree.put(.{ .call = .{ .name = call_name, .target = target, .arguments = b.tree.close(call_arguments.mark) } });
    }

    pub fn list(b: Builder, elements: Arguments) Index {
        return b.tree.put(.{ .list = b.tree.close(elements.mark) });
    }
};

/// How a tree's text writes a double: its value with an exponent, which the compiler's tree
/// holds, or its text in the expression, which a model with no floating point compares.
pub const Doubles = enum { values, texts };

const Writer = std.Io.Writer;

/// Writes the part at `at` as `cel_node.render` writes the compiler's tree: every part in
/// brackets, and each literal so that it reads back as itself.
pub fn write(tree: *const Tree, at: Index, doubles: Doubles, writer: *Writer) Writer.Error!void {
    switch (tree.items[at]) {
        .int, .uint, .double, .boolean, .string, .bytes, .null, .name => try write_leaf(tree.items[at], doubles, writer),
        .unary, .binary, .conditional => try write_operator(tree, at, doubles, writer),
        .select, .index, .call, .list => try write_member(tree, at, doubles, writer),
    }
}

fn write_leaf(item: Item, doubles: Doubles, writer: *Writer) Writer.Error!void {
    switch (item) {
        .int => |value| try writer.print("{d}", .{value}),
        .uint => |value| try writer.print("{d}u", .{value}),
        .double => |double| try write_double(double, doubles, writer),
        .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        .string => |octets| try write_octets("'", octets, false, writer),
        .bytes => |octets| try write_octets("b'", octets, true, writer),
        .null => try writer.writeAll("null"),
        .name => |text| try writer.writeAll(text),
        else => unreachable,
    }
}

/// A double as its value, or as its text in the expression after its sign: a literal's text
/// holds no sign, and a literal with a "-" before it has a value below zero or the zero below.
fn write_double(double: Item.Double, doubles: Doubles, writer: *Writer) Writer.Error!void {
    if (doubles == .values) return writer.print("{e}", .{double.value});
    if (std.math.signbit(double.value)) try writer.writeAll("-");
    try writer.writeAll(double.text);
}

fn write_octets(open: []const u8, octets: []const u8, comptime of_bytes: bool, writer: *Writer) Writer.Error!void {
    try writer.writeAll(open);
    for (octets) |octet| {
        const written = node_file.written_of(octet, of_bytes);
        try writer.writeAll(written.text());
    }
    try writer.writeAll("'");
}

fn write_operator(tree: *const Tree, at: Index, doubles: Doubles, writer: *Writer) Writer.Error!void {
    try writer.writeAll("(");
    switch (tree.items[at]) {
        .unary => |unary| {
            try writer.writeAll(unary.op.text());
            // A "-" before a number is the number's sign, so a part whose text starts with a
            // number is written in brackets under a negation.
            const bracketed = unary.op == .negate and starts_with_number(tree, unary.of);
            if (bracketed) try writer.writeAll("(");
            try write(tree, unary.of, doubles, writer);
            if (bracketed) try writer.writeAll(")");
        },
        .binary => |binary| {
            try write(tree, binary.left, doubles, writer);
            try writer.print(" {s} ", .{binary.op.text()});
            try write(tree, binary.right, doubles, writer);
        },
        .conditional => |conditional| {
            try write(tree, conditional.condition, doubles, writer);
            try writer.writeAll(" ? ");
            try write(tree, conditional.then, doubles, writer);
            try writer.writeAll(" : ");
            try write(tree, conditional.otherwise, doubles, writer);
        },
        else => unreachable,
    }
    try writer.writeAll(")");
}

/// Whether the text of the part at `start` starts with an int or a double: the number itself,
/// or a selection, an index or a call on a part that starts with one.
fn starts_with_number(tree: *const Tree, start: Index) bool {
    var at = start;
    // Each step moves to a part the part before it holds, so the parts bound the steps.
    for (0..tree.item_count) |_| {
        at = switch (tree.items[at]) {
            .int, .double => return true,
            .select => |select| select.of,
            .index => |index| index.of,
            .call => |call| call.target orelse return false,
            else => return false,
        };
    }
    return false;
}

fn write_member(tree: *const Tree, at: Index, doubles: Doubles, writer: *Writer) Writer.Error!void {
    switch (tree.items[at]) {
        .select => |select| {
            try write(tree, select.of, doubles, writer);
            try writer.print(".{s}", .{select.field});
        },
        .index => |index| {
            try write(tree, index.of, doubles, writer);
            try writer.writeAll("[");
            try write(tree, index.at, doubles, writer);
            try writer.writeAll("]");
        },
        .call => |call| {
            if (call.target) |target| {
                try write(tree, target, doubles, writer);
                try writer.writeAll(".");
            }
            try writer.writeAll(call.name);
            try write_parts(tree, call.arguments, "(", ")", doubles, writer);
        },
        .list => |elements| try write_parts(tree, elements, "[", "]", doubles, writer),
        else => unreachable,
    }
}

fn write_parts(tree: *const Tree, span: Span, open: []const u8, close: []const u8, doubles: Doubles, writer: *Writer) Writer.Error!void {
    try writer.writeAll(open);
    for (tree.links[span.start..][0..span.len], 0..) |part, place| {
        if (place != 0) try writer.writeAll(", ");
        try write(tree, part, doubles, writer);
    }
    try writer.writeAll(close);
}
