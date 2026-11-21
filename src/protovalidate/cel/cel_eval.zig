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
const Node = node_file.Node;
const Scope = type_file.Scope;
const Env = type_file.Env;
const Error = type_file.Error;
const Failing = type_file.Failing;

/// The type of the value `node` gives. The expression has no problem: `check.type_of` read it.
pub fn Result(comptime node: *const Node, comptime scope: Scope) type {
    return check.type_of(node, scope).ok.type;
}

/// The value of `node` for `values`, one for each name of `scope`.
pub fn eval(comptime node: *const Node, comptime scope: Scope, values: anytype, env: *const Env) Error!Result(node, scope) {
    if (comptime Result(node, scope) == Failing) return error.Unevaluable;
    switch (comptime node.*) {
        inline .int, .uint, .double, .boolean, .string => |value| return value,
        .bytes => |octets| return .{ .octets = octets },
        .null => return .{},
        .name => |name| return eval_name(name, scope, values, env),
        .select => |select| return eval_select(select, scope, values, env),
        .unary => |unary| return eval_unary(unary, scope, values, env),
        .binary => |binary| return eval_binary(binary, scope, values, env),
        .conditional => |conditional| return eval_conditional(conditional, comptime Result(node, scope), scope, values, env),
        .call => |call| return eval_call(call, comptime Result(node, scope), scope, values, env),
        .index, .list => comptime unreachable,
    }
}

/// The value of `node` as an `R`, or the failure of a part whose type is `Failing`.
fn eval_as(comptime R: type, comptime node: *const Node, comptime scope: Scope, values: anytype, env: *const Env) Error!R {
    if (comptime Result(node, scope) == Failing) return error.Unevaluable;
    return eval(node, scope, values, env);
}

fn eval_name(comptime name: []const u8, comptime scope: Scope, values: anytype, env: *const Env) Error!Result(&.{ .name = name }, scope) {
    if (comptime scope.index_of(name)) |index| return values[index];
    return env.now orelse error.TimeMissing;
}

fn eval_select(comptime select: Node.Select, comptime scope: Scope, values: anytype, env: *const Env) Error!Result(&.{ .select = select }, scope) {
    const target = try eval(select.of, scope, values, env);
    const M = @typeInfo(@TypeOf(target)).pointer.child;
    return select_file.read(M, comptime select_file.field_of(M, select.field).?, target);
}

fn eval_unary(comptime unary: Node.Unary, comptime scope: Scope, values: anytype, env: *const Env) Error!Result(unary.of, scope) {
    const operand = try eval(unary.of, scope, values, env);
    if (comptime unary.op == .not) return !operand;
    return number.negate(@TypeOf(operand), operand);
}

fn eval_binary(comptime binary: Node.Binary, comptime scope: Scope, values: anytype, env: *const Env) Error!Result(&.{ .binary = binary }, scope) {
    switch (comptime binary.op) {
        .@"and" => return eval_logic(binary, false, scope, values, env),
        .@"or" => return eval_logic(binary, true, scope, values, env),
        else => {},
    }
    const left = try eval(binary.left, scope, values, env);
    const right = try eval(binary.right, scope, values, env);
    return switch (comptime binary.op) {
        .equal => value_file.equal(left, right),
        .not_equal => !value_file.equal(left, right),
        // A double that is not a number stands in no order, so each comparison is false.
        .less => value_file.order(left, right) == .lt,
        .greater => value_file.order(left, right) == .gt,
        .less_or_equal => if (value_file.order(left, right)) |order| order != .gt else false,
        .greater_or_equal => if (value_file.order(left, right)) |order| order != .lt else false,
        .add => number.compute(@TypeOf(left), .add, left, right),
        .subtract => number.compute(@TypeOf(left), .subtract, left, right),
        .multiply => number.compute(@TypeOf(left), .multiply, left, right),
        .divide => number.compute(@TypeOf(left), .divide, left, right),
        .modulo => number.compute(@TypeOf(left), .modulo, left, right),
        .in, .@"and", .@"or" => comptime unreachable,
    };
}

/// `left && right`, whose absorbing value is false, and `left || right`, whose is true. The
/// operators are commutative over failures: a side that fails is absorbed when the other side
/// gives the absorbing value (CEL language definition, "Logical Operators").
fn eval_logic(comptime binary: Node.Binary, comptime absorbing: bool, comptime scope: Scope, values: anytype, env: *const Env) Error!bool {
    const left = eval_as(bool, binary.left, scope, values, env) catch |failure| {
        const right = eval_as(bool, binary.right, scope, values, env) catch return failure;
        if (right == absorbing) return absorbing;
        return failure;
    };
    if (left == absorbing) return absorbing;
    return eval_as(bool, binary.right, scope, values, env);
}

fn eval_conditional(comptime conditional: Node.Conditional, comptime R: type, comptime scope: Scope, values: anytype, env: *const Env) Error!R {
    if (try eval(conditional.condition, scope, values, env)) return eval_as(R, conditional.then, scope, values, env);
    return eval_as(R, conditional.otherwise, scope, values, env);
}

fn eval_call(comptime call: Node.Call, comptime R: type, comptime scope: Scope, values: anytype, env: *const Env) Error!R {
    const operands = comptime check.operands_of(call);
    if (comptime std.mem.eql(u8, call.name, "has")) return eval_has(operands[0].select, scope, values, env);
    if (comptime std.mem.eql(u8, call.name, "dyn")) return eval(&operands[0], scope, values, env);
    if (comptime std.mem.eql(u8, call.name, "duration")) return comptime time.parse_duration(operands[0].string).?;
    var taken: Operands(operands, scope) = undefined;
    inline for (operands, 0..) |*operand, index| taken[index] = try eval(operand, scope, values, env);
    return function.run(call.name, R, taken);
}

/// The tuple of a call's operands' values.
fn Operands(comptime operands: []const Node, comptime scope: Scope) type {
    var types: []const type = &.{};
    for (operands) |*operand| types = types ++ [_]type{Result(operand, scope)};
    return std.meta.Tuple(types);
}

fn eval_has(comptime select: Node.Select, comptime scope: Scope, values: anytype, env: *const Env) Error!bool {
    const target = try eval(select.of, scope, values, env);
    const M = @typeInfo(@TypeOf(target)).pointer.child;
    return select_file.has(M, comptime select_file.field_of(M, select.field).?, target);
}
