//! CEL's `format`: `text.format(list)` writes each value of the list where a conversion stands
//! in the text (CEL strings extension, "string.format(list) -> string"). The text is a string
//! literal and the list a list literal, so the compiler reads the text once into pieces and
//! types each value alone. The run writes the result into the room that `Env.text` gives.
const std = @import("std");
const proto = @import("protobuf");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const check = @import("cel_check.zig");
const evaluation = @import("cel_eval.zig");
const list_file = @import("cel_list.zig");
const Node = node_file.Node;
const Scope = type_file.Scope;
const Env = type_file.Env;
const Error = type_file.Error;
const Typed = type_file.Typed;
const Bytes = type_file.Bytes;
const Null = type_file.Null;

/// CEL strings extension, "Conversion": the conversions the module writes. `f`, `e`, `o`, `b`
/// and a precision stop the build: no rule of protovalidate's suite uses them.
const Conversion = enum { s, d, x, X };

/// One piece of a format's text: text as it stands, or the conversion of the value at `index`.
const Piece = union(enum) {
    text: []const u8,
    value: struct { conversion: Conversion, index: usize },
};

/// The octets a conversion takes in a format's text: the `%` and its letter.
const conversion_len = "%s".len;

/// A format's pieces, or why its text has none.
const Parsed = union(enum) {
    pieces: []const Piece,
    problem: []const u8,
};

/// CEL strings extension, "Format": `%[.precision]conversion`.
fn parse(comptime text: []const u8) Parsed {
    var pieces: []const Piece = &.{};
    // Where the text since the last conversion starts, and whether an octet is a conversion's
    // letter, which the `%` before it read.
    var start: usize = 0;
    var letter = false;
    for (text, 0..) |octet, place| {
        if (letter) {
            letter = false;
            continue;
        }
        if (octet != '%') continue;
        if (place + 1 == text.len) return .{ .problem = "the text of `format` ends with a `%`" };
        const conversion = conversion_of(text[place + 1]) orelse {
            return .{ .problem = "`format` does not read the conversion `" ++ text[place..][0..conversion_len] ++ "` yet" };
        };
        if (place != start) pieces = pieces ++ [_]Piece{.{ .text = text[start..place] }};
        pieces = pieces ++ [_]Piece{.{ .value = .{ .conversion = conversion, .index = value_count(pieces) } }};
        letter = true;
        start = place + conversion_len;
    }
    if (start != text.len) pieces = pieces ++ [_]Piece{.{ .text = text[start..] }};
    return .{ .pieces = pieces };
}

fn conversion_of(comptime letter: u8) ?Conversion {
    return switch (letter) {
        's' => .s,
        'd' => .d,
        'x' => .x,
        'X' => .X,
        else => null,
    };
}

/// The count of the values a format's pieces read.
fn value_count(comptime pieces: []const Piece) usize {
    var count: usize = 0;
    for (pieces) |piece| count += @intFromBool(piece == .value);
    return count;
}

/// The type of `text.format(list)`: a string, when the text is a literal whose conversions the
/// module reads and the list a list literal with a value of a type each conversion takes.
pub fn of_format(comptime call: Node.Call, comptime scope: Scope) Typed {
    const target = call.target orelse return .{ .problem = "`format` is called on its text: `'...'.format([...])`" };
    if (call.arguments.len != 1) return .{ .problem = "`format` takes one list" };
    const text = switch (target.*) {
        .string => |value| value,
        else => return .{ .problem = "the text of `format` is no string literal, and this module reads it as it compiles" },
    };
    const values = switch (call.arguments[0]) {
        .list => |elements| elements,
        else => return .{ .problem = "the values of `format` are no list literal, and this module types each one as it compiles" },
    };
    const pieces = switch (parse(text)) {
        .pieces => |pieces| pieces,
        .problem => |problem| return .{ .problem = problem },
    };
    if (value_count(pieces) != values.len) return .{ .problem = "the text of `format` has another count of conversions than its list has values" };
    return of_values(pieces, values, scope);
}

fn of_values(comptime pieces: []const Piece, comptime values: []const Node, comptime scope: Scope) Typed {
    var dynamic = false;
    for (pieces) |piece| {
        const value = switch (piece) {
            .text => continue,
            .value => |value| value,
        };
        const typed = switch (check.type_of(&values[value.index], scope)) {
            .ok => |ok| ok,
            .problem => |problem| return .{ .problem = problem },
        };
        dynamic = dynamic or typed.dynamic;
        if (!takes(value.conversion, typed.type)) {
            return check.mistake(typed.dynamic, "`%" ++ @tagName(value.conversion) ++ "` of `format` takes no " ++ type_file.name_of(typed.type));
        }
    }
    return .{ .ok = .{ .type = []const u8, .dynamic = dynamic } };
}

/// Whether `conversion` writes a value of type `T` (CEL strings extension, "Conversion"). A
/// wrapper is its value, or null.
fn takes(comptime conversion: Conversion, comptime T: type) bool {
    if (@typeInfo(T) == .optional) return takes(conversion, @typeInfo(T).optional.child) and conversion == .s;
    return switch (conversion) {
        .s => T == bool or type_file.is_number(T) or T == []const u8 or T == Bytes or T == Null or takes_list(T),
        .d => T == i64 or T == u64,
        .x, .X => T == i64 or T == u64 or T == []const u8 or T == Bytes,
    };
}

fn takes_list(comptime T: type) bool {
    if (!list_file.is_list(T)) return false;
    return takes(.s, list_file.ElementOf(T));
}

/// Writes `text.format(list)` into `env.text` and gives the written text. Each value is read
/// before any is written, so a `format` inside a value writes its text first.
pub fn eval_format(comptime call: Node.Call, comptime scope: Scope, values: anytype, env: *Env) Error![]const u8 {
    const pieces = comptime parse(call.target.?.string).pieces;
    const nodes = comptime call.arguments[0].list;
    var taken: Taken(nodes, scope) = undefined;
    inline for (nodes, 0..) |*node, index| taken[index] = try evaluation.eval(node, scope, values, env);
    const text = env.text orelse return error.ReportFull;
    const start = text.len;
    inline for (pieces) |piece| switch (piece) {
        .text => |part| try text.write(part),
        .value => |value| try write_value(value.conversion, taken[value.index], env),
    };
    return text.room[start..text.len];
}

/// The tuple of a format's values.
fn Taken(comptime nodes: []const Node, comptime scope: Scope) type {
    var types: []const type = &.{};
    for (nodes) |*node| types = types ++ [_]type{evaluation.Result(node, scope)};
    return std.meta.Tuple(types);
}

fn write_value(comptime conversion: Conversion, value: anytype, env: *Env) Error!void {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .optional) {
        if (value) |held| return write_value(conversion, held, env);
        return put(env, "null");
    }
    switch (conversion) {
        .s => return write_string(value, env),
        .d => return write_print("{d}", value, env),
        .x => return write_hex(.lower, value, env),
        .X => return write_hex(.upper, value, env),
    }
}

/// CEL strings extension, "Conversion": `s` of each type.
fn write_string(value: anytype, env: *Env) Error!void {
    const T = @TypeOf(value);
    if (comptime T == []const u8) return put(env, value);
    if (comptime T == Bytes) return write_valid_utf8(value.octets, env);
    if (comptime T == bool) return put(env, if (value) "true" else "false");
    if (comptime T == Null) return put(env, "null");
    if (comptime T == f64) return write_double(value, env);
    if (comptime type_file.is_number(T)) return write_print("{d}", value, env);
    return write_list(value, env);
}

/// "In all cases where `double` is accepted: if the value is NaN the result is `NaN`, if the
/// value is infinity the result is `[-]Infinity`." Otherwise base 10 with no insignificant
/// zero, and no `.` with no digit after it, as Zig's `{d}` writes a double.
fn write_double(value: f64, env: *Env) Error!void {
    if (std.math.isNan(value)) return put(env, "NaN");
    if (std.math.isInf(value)) return put(env, if (value < 0) "-Infinity" else "Infinity");
    return write_print("{d}", value, env);
}

/// "The value is formatted as if each element was formatted as `"%s".format([element])`,
/// joined together with `, ` and enclosed with `[` and `]`."
fn write_list(list: anytype, env: *Env) Error!void {
    try put(env, "[");
    var elements = list_file.iterate(list);
    var first = true;
    for (0..proto.constants.limits.elements_max) |_| {
        const element = try elements.next(env) orelse break;
        if (!first) try put(env, ", ");
        first = false;
        try write_string(element, env);
    }
    try put(env, "]");
}

/// bytes under `s`: "formatted as if `string(value)` was performed and any invalid UTF-8
/// sequences are replaced with `\ufffd`. Multiple adjacent invalid UTF-8 sequences must be
/// replaced with a single `\ufffd`."
fn write_valid_utf8(octets: []const u8, env: *Env) Error!void {
    const replacement = "\u{fffd}";
    var rest = octets;
    var replaced = false;
    for (0..octets.len) |_| {
        if (rest.len == 0) break;
        const len = sequence_len(rest) orelse {
            if (!replaced) try put(env, replacement);
            replaced = true;
            rest = rest[1..];
            continue;
        };
        try put(env, rest[0..len]);
        replaced = false;
        rest = rest[len..];
    }
}

/// The octets of the UTF-8 sequence that starts `octets`, or null when none starts it (RFC
/// 3629 §3).
fn sequence_len(octets: []const u8) ?usize {
    const len = std.unicode.utf8ByteSequenceLength(octets[0]) catch return null;
    if (len > octets.len) return null;
    _ = std.unicode.utf8Decode(octets[0..len]) catch return null;
    return len;
}

/// `x` and `X`: an int or a uint "in base 16 with no insignificant digits. If the value was
/// negative `-` is prepended", and a string or bytes as "each byte ... in base 16 with exactly
/// 2 digits".
fn write_hex(comptime case: std.fmt.Case, value: anytype, env: *Env) Error!void {
    const T = @TypeOf(value);
    if (comptime T == []const u8) return write_hex_octets(case, value, env);
    if (comptime T == Bytes) return write_hex_octets(case, value.octets, env);
    if (comptime T == i64) {
        if (value < 0) try put(env, "-");
        return write_print(if (case == .lower) "{x}" else "{X}", @abs(value), env);
    }
    return write_print(if (case == .lower) "{x}" else "{X}", value, env);
}

fn write_hex_octets(comptime case: std.fmt.Case, octets: []const u8, env: *Env) Error!void {
    for (octets) |octet| try write_print(if (case == .lower) "{x:0>2}" else "{X:0>2}", octet, env);
}

fn write_print(comptime pattern: []const u8, value: anytype, env: *Env) Error!void {
    const text = env.text.?;
    const written = std.fmt.bufPrint(text.unwritten(), pattern, .{value}) catch return text.overflow();
    text.len += written.len;
}

/// Writes `octets` into the text, which `eval_format` found the run has.
fn put(env: *Env, octets: []const u8) Error!void {
    return env.text.?.write(octets);
}
