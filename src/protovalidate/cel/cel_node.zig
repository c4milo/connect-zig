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
    /// `name(arguments)`, or `target.name(arguments)`. `function` is `Function.of(name)`.
    pub const Call = struct { name: []const u8, function: Function, target: ?*const Node = null, arguments: []const Node = &.{} };
};

/// The function or the macro a call names. The parser finds it once, so the typing and the
/// code compare no text. A member has the name its function has in an expression.
pub const Function = enum {
    /// A name the module holds no function for.
    unknown,
    has,
    dyn,
    duration,
    matches,
    format,
    all,
    exists,
    exists_one,
    map,
    filter,
    size,
    int,
    uint,
    double,
    string,
    bytes,
    bool,
    startsWith,
    endsWith,
    contains,
    isEmail,
    isHostname,
    isUri,
    isUriRef,
    isHostAndPort,
    isIp,
    isIpPrefix,
    isNan,
    isInf,
    timestamp,
    type,
    getFullYear,
    getMonth,
    getDate,
    getDayOfMonth,
    getDayOfYear,
    getDayOfWeek,
    getHours,
    getMinutes,
    getSeconds,
    getMilliseconds,

    /// Whether the function gives a part of a timestamp, or of a duration (CEL language
    /// definition, the `get` functions of "Standard Environment").
    pub fn is_time_part(function: Function) bool {
        return switch (function) {
            .getFullYear, .getMonth, .getDate, .getDayOfMonth, .getDayOfYear, .getDayOfWeek => true,
            .getHours, .getMinutes, .getSeconds, .getMilliseconds => true,
            else => false,
        };
    }

    /// The function `name` names. The compiler finds an enum's member by its name in one
    /// step, where a comparison with each function's name takes it a step for each octet
    /// (docs/performance.md).
    pub fn of(comptime name: []const u8) Function {
        if (!@hasField(Function, name)) return .unknown;
        return @field(Function, name);
    }
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

/// One octet of a string or of a bytes literal as the tree's text writes it.
pub const Written = struct {
    octets: [written_len_max]u8,
    len: usize,

    pub fn text(written: *const Written) []const u8 {
        return written.octets[0..written.len];
    }
};
/// The octets of the longest form: "\xff".
const written_len_max = 4;
const hexadecimal_digits = "0123456789abcdef";
const nibble_bits = 4;
const nibble_mask = 0xf;

/// How the tree's text writes `octet` of a string, or of a bytes literal. A string keeps each
/// octet but a backslash, a single quote and the line ends, which it escapes. A bytes literal
/// keeps printable ASCII and writes each other octet as "\x" and two digits, so the text is
/// ASCII whatever the octets are.
pub fn written_of(octet: u8, comptime of_bytes: bool) Written {
    const escaped: ?u8 = switch (octet) {
        '\\', '\'' => octet,
        '\n' => 'n',
        '\r' => 'r',
        '\t' => 't',
        else => null,
    };
    if (escaped) |letter| return .{ .octets = .{ '\\', letter, 0, 0 }, .len = "\\n".len };
    if (!of_bytes or std.ascii.isPrint(octet)) return .{ .octets = .{ octet, 0, 0, 0 }, .len = 1 };
    return .{ .octets = .{ '\\', 'x', hexadecimal_digits[octet >> nibble_bits], hexadecimal_digits[octet & nibble_mask] }, .len = written_len_max };
}

/// The tree as text with every part in brackets, which shows how the parser grouped it:
/// "(a < (b + 1))". The text is an expression that reads as the same tree: a string and a
/// bytes literal are written with their escapes, and a double with its exponent. A test
/// compares it with the text `cel_tree.zig` writes of the same expression.
pub fn render(comptime node: *const Node) []const u8 {
    comptime {
        return switch (node.*) {
            .int, .uint, .double, .boolean, .string, .bytes, .null, .name => render_leaf(node),
            .select => |select| render(select.of) ++ "." ++ select.field,
            .index => |index| render(index.of) ++ "[" ++ render(index.at) ++ "]",
            .unary => |unary| "(" ++ unary.op.text() ++ render_operand(unary) ++ ")",
            .binary => |binary| "(" ++ render(binary.left) ++ " " ++ binary.op.text() ++ " " ++ render(binary.right) ++ ")",
            .conditional => |conditional| "(" ++ render(conditional.condition) ++ " ? " ++ render(conditional.then) ++ " : " ++ render(conditional.otherwise) ++ ")",
            .call => |call| render_target(call.target) ++ call.name ++ "(" ++ render_list(call.arguments) ++ ")",
            .list => |elements| "[" ++ render_list(elements) ++ "]",
        };
    }
}

/// A "-" before a number is the number's sign, so a text that starts with a number is written
/// in brackets when a "-" negates it: "(-(5))" is a negation, and "-5" is a number.
fn render_operand(comptime unary: Node.Unary) []const u8 {
    if (unary.op == .negate and starts_with_number(unary.of)) return "(" ++ render(unary.of) ++ ")";
    return render(unary.of);
}

/// Whether the text of `node` starts with an int or a double: the number itself, or a
/// selection, an index or a call on a part that starts with one.
fn starts_with_number(comptime node: *const Node) bool {
    return switch (node.*) {
        .int, .double => true,
        .select => |select| starts_with_number(select.of),
        .index => |index| starts_with_number(index.of),
        .call => |call| if (call.target) |target| starts_with_number(target) else false,
        else => false,
    };
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
        .double => |value| std.fmt.comptimePrint("{e}", .{value}),
        .boolean => |value| if (value) "true" else "false",
        .string => |value| "'" ++ render_octets(value, false) ++ "'",
        .bytes => |value| "b'" ++ render_octets(value, true) ++ "'",
        .null => "null",
        .name => |name| name,
        else => unreachable,
    };
}

fn render_octets(comptime octets: []const u8, comptime of_bytes: bool) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (octets) |octet| {
            const written = written_of(octet, of_bytes);
            text = text ++ written.text();
        }
        return text;
    }
}

fn render_list(comptime nodes: []const Node) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (nodes, 0..) |*node, index| text = text ++ (if (index == 0) "" else ", ") ++ render(node);
        return text;
    }
}

const testing = std.testing;

test "an octet of a literal is written so that it reads back as itself" {
    try testing.expectEqualStrings("a", written_of('a', false).text());
    try testing.expectEqualStrings("\\\\", written_of('\\', false).text());
    try testing.expectEqualStrings("\\'", written_of('\'', true).text());
    try testing.expectEqualStrings("\\n", written_of('\n', false).text());
    try testing.expectEqualStrings("\\r", written_of('\r', true).text());
    try testing.expectEqualStrings("\\t", written_of('\t', false).text());
    // A string keeps an octet that is no ASCII, and a bytes literal writes its number.
    try testing.expectEqualStrings("\xe9", written_of('\xe9', false).text());
    try testing.expectEqualStrings("\\xe9", written_of('\xe9', true).text());
    try testing.expectEqualStrings("\\x00", written_of(0, true).text());
    try testing.expectEqualStrings("\\x7f", written_of('\x7f', true).text());
    try testing.expectEqualStrings("\x00", written_of(0, false).text());
    try testing.expectEqualStrings("~", written_of('~', true).text());
    try testing.expectEqualStrings(" ", written_of(' ', true).text());
}
