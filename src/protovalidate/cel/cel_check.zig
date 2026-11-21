//! The type of each part of an expression, which the compiler finds while it reads a message's
//! table (CEL language definition, "Type Checking"). A part with no type gives its problem as
//! a value, so `rules_error` reports it. Under `dyn` a mistake of types is not a problem: the
//! part gets the type `Failing`, and fails when it runs.
const std = @import("std");
const proto = @import("protobuf");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const select_file = @import("cel_select.zig");
const function = @import("cel_function.zig");
const value_file = @import("cel_value.zig");
const time = @import("cel_time.zig");
const collection = @import("cel_collection.zig");
const Node = node_file.Node;
const BinaryOp = node_file.BinaryOp;
const Scope = type_file.Scope;
const Typed = type_file.Typed;
const Bytes = type_file.Bytes;
const Null = type_file.Null;
const Failing = type_file.Failing;
const Timestamp = proto.wkt.Timestamp;
const Duration = proto.wkt.Duration;

pub fn type_of(comptime node: *const Node, comptime scope: Scope) Typed {
    comptime {
        return switch (node.*) {
            .int => .of(i64),
            .uint => .of(u64),
            .double => .of(f64),
            .boolean => .of(bool),
            .string => .of([]const u8),
            .bytes => .of(Bytes),
            .null => .of(Null),
            .name => |name| of_name(name, scope),
            .select => |select| of_select(select, scope),
            .unary => |unary| of_unary(unary, scope),
            .binary => |binary| of_binary(binary, scope),
            .conditional => |conditional| of_conditional(conditional, scope),
            .call => |call| of_call(call, scope),
            .index => |index| collection.of_index(index, scope),
            .list => |elements| collection.of_list(elements, scope),
        };
    }
}

/// A mistake of types: the build's problem, or, in a part that came through `dyn`, a part
/// that fails when it runs.
pub fn mistake(comptime dynamic: bool, comptime problem: []const u8) Typed {
    if (dynamic) return .{ .ok = .{ .type = Failing, .dynamic = true } };
    return .{ .problem = problem };
}

fn of_name(comptime name: []const u8, comptime scope: Scope) Typed {
    if (scope.index_of(name)) |index| return .of(scope.types[index]);
    // validate.proto, Rule.expression: `now` is the time of the validation.
    if (std.mem.eql(u8, name, "now")) return .of(Timestamp);
    return .{ .problem = "undeclared reference to `" ++ name ++ "`" };
}

fn of_select(comptime select: Node.Select, comptime scope: Scope) Typed {
    const target = switch (type_of(select.of, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const T = target.type;
    if (T == Failing) return .{ .ok = target };
    const M = type_file.MessageOf(T) orelse return mistake(target.dynamic, "type `" ++ type_file.name_of(T) ++ "` has no field `" ++ select.field ++ "`");
    const field = select_file.field_of(M, select.field) orelse {
        return mistake(target.dynamic, "undefined field `" ++ select.field ++ "` of " ++ M.protobuf.full_name);
    };
    const F = select_file.Type(M, field) orelse {
        return .{ .problem = M.protobuf.full_name ++ "." ++ select.field ++ ": the module reads no field of the message's own type in an expression" };
    };
    return .{ .ok = .{ .type = F, .dynamic = target.dynamic } };
}

fn of_unary(comptime unary: Node.Unary, comptime scope: Scope) Typed {
    const operand = switch (type_of(unary.of, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const T = operand.type;
    if (T == Failing) return .{ .ok = operand };
    const fits = if (unary.op == .not) T == bool else T == i64 or T == f64;
    if (fits) return .{ .ok = operand };
    return mistake(operand.dynamic, "found no matching overload for `" ++ unary.op.text() ++ "` applied to (" ++ type_file.name_of(T) ++ ")");
}

fn of_binary(comptime binary: Node.Binary, comptime scope: Scope) Typed {
    const left = switch (type_of(binary.left, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const right = switch (type_of(binary.right, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const dynamic = left.dynamic or right.dynamic;
    if (Overload(binary.op, left.type, right.type)) |R| return .{ .ok = .{ .type = R, .dynamic = dynamic } };
    return mistake(dynamic, "found no matching overload for `" ++ binary.op.text() ++ "` applied to (" ++ type_file.name_of(left.type) ++ ", " ++ type_file.name_of(right.type) ++ ")");
}

/// The type `left op right` has, or null when the operator takes no such pair.
pub fn Overload(comptime op: BinaryOp, comptime L: type, comptime R: type) ?type {
    if (op == .@"and" or op == .@"or") return logical(L, R);
    if (L == Failing or R == Failing) return Failing;
    return switch (op) {
        .equal, .not_equal => bool_when(value_file.equatable(L, R)),
        .less, .less_or_equal, .greater, .greater_or_equal => bool_when(value_file.ordered(L, R)),
        .add, .subtract, .multiply, .divide => arithmetic(L, R, .with_double),
        .modulo => arithmetic(L, R, .integers),
        .in => collection.In(L, R),
        .@"and", .@"or" => null,
    };
}

/// `&&` and `||` take two bools. A side that fails may still be absorbed by the other, so the
/// result is a bool: `false && error` is false.
fn logical(comptime L: type, comptime R: type) ?type {
    const takes = (L == bool or L == Failing) and (R == bool or R == Failing);
    return if (takes) bool else null;
}

fn bool_when(comptime takes: bool) ?type {
    return if (takes) bool else null;
}

/// An arithmetic operator takes two numbers of one type, and `%` no double.
fn arithmetic(comptime L: type, comptime R: type, comptime numbers: enum { with_double, integers }) ?type {
    if (L != R or !type_file.is_number(L)) return null;
    if (numbers == .integers and L == f64) return null;
    return L;
}

fn of_conditional(comptime conditional: Node.Conditional, comptime scope: Scope) Typed {
    const condition = switch (type_of(conditional.condition, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const then = switch (type_of(conditional.then, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const otherwise = switch (type_of(conditional.otherwise, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const dynamic = condition.dynamic or then.dynamic or otherwise.dynamic;
    if (condition.type != bool and condition.type != Failing) return mistake(condition.dynamic, "the condition of `? :` is a " ++ type_file.name_of(condition.type));
    // A side that fails takes the other side's type.
    const R = if (then.type == Failing) otherwise.type else then.type;
    if (otherwise.type != R and otherwise.type != Failing) {
        return mistake(dynamic, "the sides of `? :` are a " ++ type_file.name_of(then.type) ++ " and a " ++ type_file.name_of(otherwise.type));
    }
    return .{ .ok = .{ .type = if (condition.type == Failing) Failing else R, .dynamic = dynamic } };
}

/// The operands of a call: its target, then its arguments.
pub fn operands_of(comptime call: Node.Call) []const Node {
    if (call.target) |target| return [_]Node{target.*} ++ call.arguments;
    return call.arguments;
}

fn of_call(comptime call: Node.Call, comptime scope: Scope) Typed {
    const operands = operands_of(call);
    if (std.mem.eql(u8, call.name, "has")) return of_has(operands, scope);
    if (std.mem.eql(u8, call.name, "dyn") and operands.len == 1) return of_dyn(&operands[0], scope);
    if (std.mem.eql(u8, call.name, "duration") and operands.len == 1) return of_duration(&operands[0]);
    if (std.mem.eql(u8, call.name, "matches")) return .{ .problem = "`matches` waits for stdx's regular expressions (docs/design.md §8 step 35)" };
    if (collection.of_macro(call, scope)) |typed| return typed;
    const taken = switch (of_operands(operands, scope)) {
        .types => |taken| taken,
        .stopped => |typed| return typed,
    };
    if (taken.types.len == 1 and collection.is_size(call, taken.types[0])) return .{ .ok = .{ .type = i64, .dynamic = taken.dynamic } };
    if (function.Result(call.name, taken.types)) |R| return .{ .ok = .{ .type = R, .dynamic = taken.dynamic } };
    return mistake(taken.dynamic, "found no matching overload for `" ++ call.name ++ "` applied to (" ++ taken.names ++ ")");
}

/// The types of a call's operands, or what stops the call: an operand's problem, or an operand
/// that fails when it runs.
const Taken = union(enum) {
    types: struct { types: []const type, names: []const u8, dynamic: bool },
    stopped: Typed,
};

fn of_operands(comptime operands: []const Node, comptime scope: Scope) Taken {
    var types: []const type = &.{};
    var names: []const u8 = "";
    var dynamic = false;
    for (operands, 0..) |*operand, index| {
        const typed = switch (type_of(operand, scope)) {
            .ok => |ok| ok,
            .problem => |problem| return .{ .stopped = .{ .problem = problem } },
        };
        if (typed.type == Failing) return .{ .stopped = .{ .ok = typed } };
        dynamic = dynamic or typed.dynamic;
        types = types ++ [_]type{typed.type};
        names = names ++ (if (index == 0) "" else ", ") ++ type_file.name_of(typed.type);
    }
    return .{ .types = .{ .types = types, .names = names, .dynamic = dynamic } };
}

/// `has(e.f)`: "e.f" selects a field (CEL language definition, "Macros").
fn of_has(comptime operands: []const Node, comptime scope: Scope) Typed {
    if (operands.len != 1 or operands[0] != .select) return .{ .problem = "`has` takes one field selection" };
    const select = operands[0].select;
    const target = switch (type_of(select.of, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    if (target.type == Failing) return .{ .ok = target };
    const M = type_file.MessageOf(target.type) orelse return mistake(target.dynamic, "type `" ++ type_file.name_of(target.type) ++ "` has no field `" ++ select.field ++ "`");
    if (select_file.field_of(M, select.field) == null) return mistake(target.dynamic, "undefined field `" ++ select.field ++ "` of " ++ M.protobuf.full_name);
    return .{ .ok = .{ .type = bool, .dynamic = target.dynamic } };
}

fn of_dyn(comptime operand: *const Node, comptime scope: Scope) Typed {
    return switch (type_of(operand, scope)) {
        .ok => |ok| .{ .ok = .{ .type = ok.type, .dynamic = true } },
        .problem => |problem| .{ .problem = problem },
    };
}

/// `duration(string)` of a literal, which the compiler reads once.
fn of_duration(comptime operand: *const Node) Typed {
    if (operand.* != .string) return .{ .problem = "`duration` takes a string literal" };
    if (time.parse_duration(operand.string) == null) return .{ .problem = "`" ++ operand.string ++ "` is no duration" };
    return .of(Duration);
}
