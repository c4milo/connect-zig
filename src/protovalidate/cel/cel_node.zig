//! A CEL expression as a tree, which the parser builds at comptime (CEL language definition,
//! "Syntax"). A macro such as `all` and a function such as `has` are calls here; the typing
//! gives each its meaning.
const std = @import("std");

pub const Node = union(enum) {
    int: i64,
    uint: u64,
    double: f64,
    boolean: bool,
    string: []const u8,
    /// A bytes literal's octets.
    bytes: []const u8,
    null,
    /// An identifier: `this`, `now`, `rule`, `rules`, or a macro's variable.
    name: []const u8,
    select: Select,
    index: Index,
    unary: Unary,
    binary: Binary,
    conditional: Conditional,
    call: Call,
    /// A list literal's elements.
    list: []const Node,

    pub const Select = struct { of: *const Node, field: []const u8 };
    pub const Index = struct { of: *const Node, at: *const Node };
    pub const Unary = struct { op: UnaryOp, of: *const Node };
    pub const Binary = struct { op: BinaryOp, left: *const Node, right: *const Node };
    pub const Conditional = struct { condition: *const Node, then: *const Node, otherwise: *const Node };
    /// `name(arguments)`, or `target.name(arguments)`.
    pub const Call = struct { name: []const u8, target: ?*const Node = null, arguments: []const Node = &.{} };
};

pub const UnaryOp = enum {
    not,
    negate,

    /// The operator as an expression writes it.
    pub fn text(op: UnaryOp) []const u8 {
        return if (op == .not) "!" else "-";
    }
};

pub const BinaryOp = enum {
    @"or",
    @"and",
    less,
    less_or_equal,
    greater,
    greater_or_equal,
    equal,
    not_equal,
    in,
    add,
    subtract,
    multiply,
    divide,
    modulo,

    /// The operator as an expression writes it.
    pub fn text(op: BinaryOp) []const u8 {
        return switch (op) {
            .@"or" => "||",
            .@"and" => "&&",
            .less => "<",
            .less_or_equal => "<=",
            .greater => ">",
            .greater_or_equal => ">=",
            .equal => "==",
            .not_equal => "!=",
            .in => "in",
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
            .modulo => "%",
        };
    }
};

/// The tree as text with every part in brackets, which shows how the parser grouped it:
/// "(a < (b + 1))". A test compares it.
pub fn render(comptime node: *const Node) []const u8 {
    comptime {
        return switch (node.*) {
            .int, .uint, .double, .boolean, .string, .bytes, .null, .name => render_leaf(node),
            .select => |select| render(select.of) ++ "." ++ select.field,
            .index => |index| render(index.of) ++ "[" ++ render(index.at) ++ "]",
            .unary => |unary| "(" ++ unary.op.text() ++ render(unary.of) ++ ")",
            .binary => |binary| "(" ++ render(binary.left) ++ " " ++ binary.op.text() ++ " " ++ render(binary.right) ++ ")",
            .conditional => |conditional| "(" ++ render(conditional.condition) ++ " ? " ++ render(conditional.then) ++ " : " ++ render(conditional.otherwise) ++ ")",
            .call => |call| render_target(call.target) ++ call.name ++ "(" ++ render_list(call.arguments) ++ ")",
            .list => |elements| "[" ++ render_list(elements) ++ "]",
        };
    }
}

/// A call's target and the "." after it, or nothing for a call with none.
fn render_target(comptime target: ?*const Node) []const u8 {
    const of = target orelse return "";
    return render(of) ++ ".";
}

/// A literal or a name.
fn render_leaf(comptime node: *const Node) []const u8 {
    return switch (node.*) {
        .int => |value| std.fmt.comptimePrint("{d}", .{value}),
        .uint => |value| std.fmt.comptimePrint("{d}u", .{value}),
        .double => |value| std.fmt.comptimePrint("{d}", .{value}),
        .boolean => |value| if (value) "true" else "false",
        .string => |value| "'" ++ value ++ "'",
        .bytes => |value| "b'" ++ value ++ "'",
        .null => "null",
        .name => |name| name,
        else => unreachable,
    };
}

fn render_list(comptime nodes: []const Node) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (nodes, 0..) |*node, index| text = text ++ (if (index == 0) "" else ", ") ++ render(node);
        return text;
    }
}
