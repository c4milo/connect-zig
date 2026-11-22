//! The code an expression unfolds into (CEL language definition, "Evaluation"). The tree and
//! the type of each part are comptime, so `eval` leaves the reads, the comparisons and the
//! calls the expression states, and no tree at run time.
const std = @import("std");
const proto = @import("protobuf");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const check = @import("cel_check.zig");
const select_file = @import("cel_select.zig");
const function = @import("cel_function.zig");
const value_file = @import("cel_value.zig");
const number = @import("cel_number.zig");
const time = @import("cel_time.zig");
const collection = @import("cel_collection.zig");
const list_file = @import("cel_list.zig");
const pattern_file = @import("../pattern.zig");
const format_file = @import("cel_format.zig");
const text_file = @import("cel_text.zig");
const timestamp_file = @import("cel_timestamp.zig");
const duration_file = @import("cel_duration.zig");
const time_literal = @import("cel_time_literal.zig");
const Node = node_file.Node;
const Scope = type_file.Scope;
const Env = type_file.Env;
const Error = type_file.Error;
const Failing = type_file.Failing;

/// The type of the value `node` gives. The expression has no problem: `check.type_of` read it.
pub fn Result(comptime node: *const Node, comptime scope: Scope) type {
    return check.type_of(node, scope).ok.type;
}

/// The value of `node` for `values`, one for each name of `scope`. Each part of an expression
/// is one function: the helper of its kind is inline, since a function costs the compiler
/// more than the helper's lines do (docs/performance.md).
pub fn eval(comptime node: *const Node, comptime scope: Scope, values: anytype, env: *Env) Error!Result(node, scope) {
    if (comptime Result(node, scope) == Failing) return error.Unevaluable;
    // A part whose value holds no text frees the text it wrote once the value is known.
    if (comptime text_file.writes(node) and text_file.holds_no_text(Result(node, scope))) {
        const written = text_file.mark(env);
        defer text_file.free(env, written);
        return eval_part(node, scope, values, env);
    }
    return eval_part(node, scope, values, env);
}

fn eval_part(comptime node: *const Node, comptime scope: Scope, values: anytype, env: *Env) Error!Result(node, scope) {
    switch (comptime node.*) {
        inline .int, .uint, .double, .boolean, .string => |value| return value,
        .bytes => |octets| return .{ .octets = octets },
        .null => return .{},
        // Each of these takes the part itself, so its result's type is the question the
        // typing answered for this part, which the compiler answers from its memory.
        .name => return eval_name(node, scope, values, env),
        .select => return eval_select(node, scope, values, env),
        .unary => |unary| return eval_unary(unary, scope, values, env),
        .binary => return eval_binary(node, scope, values, env),
        .conditional => |conditional| return eval_conditional(conditional, comptime Result(node, scope), scope, values, env),
        .call => |call| return eval_call(call, comptime Result(node, scope), scope, values, env),
        .index => |index| return collection.eval_index(index, comptime Result(node, scope), scope, values, env),
        .list => |elements| return collection.eval_list(elements, comptime Result(node, scope), scope, values, env),
    }
}

/// The value of `node` as an `R`, or the failure of a part whose type is `Failing`.
pub fn eval_as(comptime R: type, comptime node: *const Node, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    if (comptime Result(node, scope) == Failing) return error.Unevaluable;
    return eval(node, scope, values, env);
}

inline fn eval_name(comptime node: *const Node, comptime scope: Scope, values: anytype, env: *Env) Error!Result(node, scope) {
    if (comptime scope.index_of(node.name)) |index| return values[index];
    return env.now orelse error.TimeMissing;
}

inline fn eval_select(comptime node: *const Node, comptime scope: Scope, values: anytype, env: *Env) Error!Result(node, scope) {
    const select = comptime node.select;
    const target = try eval(select.of, scope, values, env);
    if (comptime type_file.MessageOf(@TypeOf(target)) == null) return collection.select_key(target, select.field, env);
    const M = comptime type_file.MessageOf(@TypeOf(target)).?;
    return select_file.read(M, comptime select_file.field_of(M, select.field).?, pointer_to(M, &target));
}

/// The message a message value holds: the pointer's, or the value's own, which lasts as long
/// as the caller keeps the value.
fn pointer_to(comptime M: type, value: anytype) *const M {
    if (comptime @TypeOf(value.*) == M) return value;
    return value.*;
}

inline fn eval_unary(comptime unary: Node.Unary, comptime scope: Scope, values: anytype, env: *Env) Error!Result(unary.of, scope) {
    const operand = try eval(unary.of, scope, values, env);
    if (comptime unary.op == .not) return !operand;
    return number.negate(@TypeOf(operand), operand);
}

inline fn eval_binary(comptime node: *const Node, comptime scope: Scope, values: anytype, env: *Env) Error!Result(node, scope) {
    const binary = comptime node.binary;
    switch (comptime binary.op) {
        .@"and" => return eval_logic(binary, false, scope, values, env),
        .@"or" => return eval_logic(binary, true, scope, values, env),
        else => {},
    }
    const left = try eval(binary.left, scope, values, env);
    const right = try eval(binary.right, scope, values, env);
    // Behind `dyn` the two sides may be of unlike types, which are not equal.
    const alike = comptime value_file.equal_as_they_run(@TypeOf(left), @TypeOf(right));
    return switch (comptime binary.op) {
        .equal => if (alike) value_file.equal(left, right) else false,
        .not_equal => if (alike) !value_file.equal(left, right) else true,
        // A double that is not a number stands in no order, so each comparison is false.
        .less => value_file.order(left, right) == .lt,
        .greater => value_file.order(left, right) == .gt,
        .less_or_equal => if (value_file.order(left, right)) |order| order != .gt else false,
        .greater_or_equal => if (value_file.order(left, right)) |order| order != .lt else false,
        .add, .subtract, .multiply, .divide, .modulo => arithmetic(binary.op, left, right, env),
        .in => collection.holds(right, left, env),
        .@"and", .@"or" => comptime unreachable,
    };
}

/// `left op right` of two numbers, and `+` of two strings, bytes values or lists.
inline fn arithmetic(comptime op: node_file.BinaryOp, left: anytype, right: anytype, env: *Env) Error!check.Overload(op, @TypeOf(left), @TypeOf(right)).? {
    const T = @TypeOf(left);
    if (comptime duration_file.Result(op, T, @TypeOf(right)) != null) return duration_file.compute(op, left, right);
    if (comptime op == .add and !type_file.is_number(T)) return text_file.concat(left, right, env);
    return number.compute(T, comptime @field(number.Arithmetic, @tagName(op)), left, right);
}

/// `left && right`, whose absorbing value is false, and `left || right`, whose is true. The
/// operators are commutative over failures: a side that fails is absorbed when the other side
/// gives the absorbing value (CEL language definition, "Logical Operators").
inline fn eval_logic(comptime binary: Node.Binary, comptime absorbing: bool, comptime scope: Scope, values: anytype, env: *Env) Error!bool {
    const left = eval_as(bool, binary.left, scope, values, env) catch |failure| {
        const right = eval_as(bool, binary.right, scope, values, env) catch return failure;
        if (right == absorbing) return absorbing;
        return failure;
    };
    if (left == absorbing) return absorbing;
    return eval_as(bool, binary.right, scope, values, env);
}

inline fn eval_conditional(comptime conditional: Node.Conditional, comptime R: type, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    if (try eval(conditional.condition, scope, values, env)) return eval_as(R, conditional.then, scope, values, env);
    return eval_as(R, conditional.otherwise, scope, values, env);
}

inline fn eval_call(comptime call: Node.Call, comptime R: type, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    const operands = comptime check.operands_of(call);
    switch (comptime call.function) {
        .has => return eval_has(operands[0].select, scope, values, env),
        .dyn => return eval(&operands[0], scope, values, env),
        .duration => return eval_time(proto.wkt.Duration, operands, scope, values, env),
        .timestamp => return eval_time(proto.wkt.Timestamp, operands, scope, values, env),
        // The pattern is a literal, which `check.type_of` required.
        .matches => return pattern_file.matches(operands[1].string, try eval(&operands[0], scope, values, env)),
        .format => return format_file.eval_format(call, scope, values, env),
        .string => if (comptime operands.len == 1 and text_file.converts(Result(&operands[0], scope))) return text_file.to_string(try eval(&operands[0], scope, values, env), env),
        .map, .filter => return collection.eval_derived(call, R, scope, values, env),
        .all, .exists, .exists_one => if (comptime collection.is_macro(call)) return collection.eval_macro(call, scope, values, env),
        else => {},
    }
    var taken: Operands(operands, scope) = undefined;
    inline for (operands, 0..) |*operand, index| taken[index] = try eval(operand, scope, values, env);
    if (comptime operands.len == 1 and collection.is_size(call, @TypeOf(taken[0]))) return list_file.count(taken[0], env);
    return function.run(call.function, R, taken);
}

/// `duration` or `timestamp` of one operand: a literal, which the compiler read, a `T` as it
/// is, or a text read as the expression runs, which fails when it names no `T`.
inline fn eval_time(comptime T: type, comptime operands: []const Node, comptime scope: Scope, values: anytype, env: *Env) Error!T {
    if (comptime operands[0] == .string) return time_literal.Literal(T, operands[0].string).value;
    const value = try eval(&operands[0], scope, values, env);
    if (comptime @TypeOf(value) == T) return value;
    return parse_time(T, value) orelse error.Unevaluable;
}

fn parse_time(comptime T: type, text: []const u8) ?T {
    return time_literal.parse(T, text);
}

/// The tuple of a call's operands' values.
fn Operands(comptime operands: []const Node, comptime scope: Scope) type {
    var types: []const type = &.{};
    for (operands) |*operand| types = types ++ [_]type{Result(operand, scope)};
    return std.meta.Tuple(types);
}

inline fn eval_has(comptime select: Node.Select, comptime scope: Scope, values: anytype, env: *Env) Error!bool {
    const target = try eval(select.of, scope, values, env);
    if (comptime type_file.MessageOf(@TypeOf(target)) == null) return collection.has_key(target, select.field, env);
    const M = comptime type_file.MessageOf(@TypeOf(target)).?;
    return select_file.has(M, comptime select_file.field_of(M, select.field).?, pointer_to(M, &target));
}
