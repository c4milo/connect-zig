//! The type of each part of an expression, which the compiler finds while it reads a message's
//! table (CEL language definition, "Gradual Type Checking"). A part with no type gives its problem as
//! a value, so `rules_error` reports it. Under `dyn` a mistake of types is not a problem: the
//! part gets the type `Failing`, and fails when it runs.
const std = @import("std");
const proto = @import("protobuf");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const select_file = @import("cel_select.zig");
const function = @import("cel_function.zig");
const value_file = @import("cel_value.zig");
const collection = @import("cel_collection.zig");
const pattern_file = @import("../pattern.zig");
const format_file = @import("cel_format.zig");
const text_file = @import("cel_text.zig");
const timestamp_file = @import("cel_timestamp.zig");
const duration_file = @import("cel_duration.zig");
const time_literal = @import("cel_time_literal.zig");
const type_value = @import("cel_type_value.zig");
const TypeValue = type_value.TypeValue;
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
    if (type_value.named(name) != null) return .of(TypeValue);
    return .{ .problem = "undeclared reference to `" ++ name ++ "`" };
}

fn of_select(comptime select: Node.Select, comptime scope: Scope) Typed {
    const target = switch (type_of(select.of, scope)) {
        .ok => |ok| ok,
        // A target that names no value may be the start of a type's name, such as
        // `google.protobuf` of `google.protobuf.Timestamp`.
        .problem => |problem| return if (type_value.dotted(select, scope) != null) .of(TypeValue) else .{ .problem = problem },
    };
    const T = target.type;
    if (T == Failing) return .{ .ok = target };
    const M = type_file.MessageOf(T) orelse {
        if (collection.KeySelected(T)) |V| return .{ .ok = .{ .type = V, .dynamic = target.dynamic } };
        return mistake(target.dynamic, "type `" ++ type_file.name_of(T) ++ "` has no field `" ++ select.field ++ "`");
    };
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
    // Behind `dyn` the checker knows no type, so `==`, `!=` and `in` take any two values and
    // compare them as they run: two values of unlike types are not equal (CEL language
    // definition, "Equality").
    if (dynamic and compares_as_it_runs(binary.op, right.type)) return .{ .ok = .{ .type = bool, .dynamic = true } };
    return mistake(dynamic, "found no matching overload for `" ++ binary.op.text() ++ "` applied to (" ++ type_file.name_of(left.type) ++ ", " ++ type_file.name_of(right.type) ++ ")");
}

/// Whether `op` behind `dyn` takes operands the checker has no overload for: `==` and `!=`,
/// and `in` with a list or a map on its right.
fn compares_as_it_runs(comptime op: BinaryOp, comptime R: type) bool {
    return switch (op) {
        .equal, .not_equal => R != Failing,
        .in => collection.is_collection(R),
        else => false,
    };
}

/// The type `left op right` has, or null when the operator takes no such pair.
pub fn Overload(comptime op: BinaryOp, comptime L: type, comptime R: type) ?type {
    if (op == .@"and" or op == .@"or") return logical(L, R);
    if (L == Failing or R == Failing) return Failing;
    return switch (op) {
        .equal, .not_equal => bool_when(value_file.equatable(L, R)),
        .less, .less_or_equal, .greater, .greater_or_equal => bool_when(value_file.ordered(L, R)),
        .add => first_of(arithmetic(L, R, .with_double), first_of(duration_file.Result(op, L, R), text_file.Concatenated(L, R))),
        .subtract => first_of(arithmetic(L, R, .with_double), duration_file.Result(op, L, R)),
        .multiply, .divide => arithmetic(L, R, .with_double),
        .modulo => arithmetic(L, R, .integers),
        .in => collection.In(L, R),
        .@"and", .@"or" => null,
    };
}

/// The type of the first overload that takes the operands, or null.
fn first_of(comptime first: ?type, comptime second: ?type) ?type {
    return if (first) |T| T else second;
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
    if (of_own(call, operands, scope)) |typed| return typed;
    if (collection.of_macro(call, scope)) |typed| return typed;
    const taken = switch (of_operands(operands, scope)) {
        .types => |taken| taken,
        .stopped => |typed| return typed,
    };
    if (taken.types.len == 1 and collection.is_size(call, taken.types[0])) return .{ .ok = .{ .type = i64, .dynamic = taken.dynamic } };
    const R = function.Result(call.function, taken.types) orelse {
        return mistake(taken.dynamic, "found no matching overload for `" ++ call.name ++ "` applied to (" ++ names_of(taken.types) ++ ")");
    };
    if (converts_no_literal(call, operands, R)) return .{ .problem = "the conversion `" ++ call.name ++ "` fails for its literal" };
    return .{ .ok = .{ .type = R, .dynamic = taken.dynamic } };
}

/// The type of a call that reads its operands' nodes, not their types alone: `has`, `dyn`,
/// a literal of `duration` or `timestamp`, `format`, and the literal of `matches` or of a
/// zone. Null for any other call, which the overloads type.
fn of_own(comptime call: Node.Call, comptime operands: []const Node, comptime scope: Scope) ?Typed {
    switch (call.function) {
        .has => return of_has(operands, scope),
        .dyn => if (operands.len == 1) return of_dyn(&operands[0], scope),
        .type => if (operands.len == 1) return of_type_call(&operands[0], scope),
        .matches => if (pattern_problem(operands)) |problem| return .{ .problem = problem },
        .format => return format_file.of_format(call, scope),
        else => return of_time(call, operands, scope),
    }
    return null;
}

/// `of_own` of `duration`, `timestamp` and the `get` functions.
fn of_time(comptime call: Node.Call, comptime operands: []const Node, comptime scope: Scope) ?Typed {
    switch (call.function) {
        .duration => if (operands.len == 1) return of_duration(&operands[0], scope),
        .timestamp => if (operands.len == 1) return of_timestamp(&operands[0], scope),
        else => if (call.function.is_time_part()) {
            if (zone_problem(operands)) |problem| return .{ .problem = problem };
        },
    }
    return null;
}

/// `type(value)`: the type of any value (CEL language definition, "Type Values").
fn of_type_call(comptime operand: *const Node, comptime scope: Scope) Typed {
    const typed = switch (type_of(operand, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    if (typed.type == Failing) return .{ .ok = typed };
    return .{ .ok = .{ .type = TypeValue, .dynamic = typed.dynamic } };
}

/// What stops the pattern of `matches` from compiling, or null: it is no string literal, or stdx
/// refuses it. The compiler reads each pattern into a program once (design §8 step 35), where
/// cel-go reads a pattern each time the expression runs. A call of another shape is left to the
/// overloads, which refuse it.
fn pattern_problem(comptime operands: []const Node) ?[]const u8 {
    // `matches` reads two operands: the text and the pattern.
    const text_and_pattern = 2;
    if (operands.len != text_and_pattern) return null;
    return switch (operands[1]) {
        .string => |pattern| pattern_file.problem_of(pattern),
        else => "the pattern of `matches` is no string literal, and this module reads each pattern as it compiles",
    };
}

/// Whether `call` is a conversion of a literal that fails. cel-go computes such a conversion
/// once, before the expression runs, and refuses the expression when it fails: `int('x')`
/// and `bool('k')` can give no value. The compiler computes it here the same way.
fn converts_no_literal(comptime call: Node.Call, comptime operands: []const Node, comptime R: type) bool {
    const converts = switch (call.function) {
        .int, .uint, .double, .bytes, .bool => operands.len == 1,
        // `string` fails for bytes alone, which may not be UTF-8.
        .string => operands.len == 1 and operands[0] == .bytes,
        else => false,
    };
    if (!converts) return false;
    return switch (operands[0]) {
        inline .int, .uint, .double, .boolean, .string => |value| fails(call.function, R, value),
        .bytes => |octets| fails(call.function, R, Bytes{ .octets = octets }),
        else => false,
    };
}

fn fails(comptime converter: node_file.Function, comptime R: type, comptime value: anytype) bool {
    _ = function.run(converter, R, .{value}) catch return true;
    return false;
}

/// The types of a call's operands, or what stops the call: an operand's problem, or an operand
/// that fails when it runs.
const Taken = union(enum) {
    types: struct { types: []const type, dynamic: bool },
    stopped: Typed,
};

fn of_operands(comptime operands: []const Node, comptime scope: Scope) Taken {
    var types: []const type = &.{};
    var dynamic = false;
    for (operands) |*operand| {
        const typed = switch (type_of(operand, scope)) {
            .ok => |ok| ok,
            .problem => |problem| return .{ .stopped = .{ .problem = problem } },
        };
        if (typed.type == Failing) return .{ .stopped = .{ .ok = typed } };
        dynamic = dynamic or typed.dynamic;
        types = types ++ [_]type{typed.type};
    }
    return .{ .types = .{ .types = types, .dynamic = dynamic } };
}

/// The names of `types`, with commas between them, for a call that takes no such operands.
/// Only a mistake's message holds them, so only a mistake pays for them.
fn names_of(comptime types: []const type) []const u8 {
    var names: []const u8 = "";
    for (types, 0..) |T, index| names = names ++ (if (index == 0) "" else ", ") ++ type_file.name_of(T);
    return names;
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
    const M = type_file.MessageOf(target.type) orelse {
        if (collection.KeySelected(target.type) != null) return .{ .ok = .{ .type = bool, .dynamic = target.dynamic } };
        return mistake(target.dynamic, "type `" ++ type_file.name_of(target.type) ++ "` has no field `" ++ select.field ++ "`");
    };
    if (select_file.field_of(M, select.field) == null) return mistake(target.dynamic, "undefined field `" ++ select.field ++ "` of " ++ M.protobuf.full_name);
    return .{ .ok = .{ .type = bool, .dynamic = target.dynamic } };
}

fn of_dyn(comptime operand: *const Node, comptime scope: Scope) Typed {
    return switch (type_of(operand, scope)) {
        .ok => |ok| .{ .ok = .{ .type = ok.type, .dynamic = true } },
        .problem => |problem| .{ .problem = problem },
    };
}

/// `duration(string)`: a literal, which the compiler reads once, or a text read as the
/// expression runs; and `duration(duration)`.
fn of_duration(comptime operand: *const Node, comptime scope: Scope) Typed {
    if (operand.* != .string) return of_conversion(Duration, "duration", operand, scope);
    if (!time_literal.Valid(Duration, operand.string).value) return .{ .problem = "`" ++ operand.string ++ "` is no duration" };
    return .of(Duration);
}

/// `timestamp(string)`, of RFC 3339, the same way; and `timestamp(timestamp)`.
fn of_timestamp(comptime operand: *const Node, comptime scope: Scope) Typed {
    if (operand.* != .string) return of_conversion(Timestamp, "timestamp", operand, scope);
    if (!time_literal.Valid(Timestamp, operand.string).value) return .{ .problem = "`" ++ operand.string ++ "` is no timestamp of RFC 3339 in the range of CEL's timestamps" };
    return .of(Timestamp);
}

/// A conversion to `T` of a value the build does not know: a string, read as the expression
/// runs, or a `T`.
fn of_conversion(comptime T: type, comptime name: []const u8, comptime operand: *const Node, comptime scope: Scope) Typed {
    const typed = switch (type_of(operand, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    if (typed.type == Failing) return .{ .ok = typed };
    if (typed.type == []const u8 or typed.type == T) return .{ .ok = .{ .type = T, .dynamic = typed.dynamic } };
    return mistake(typed.dynamic, "found no matching overload for `" ++ name ++ "` applied to (" ++ type_file.name_of(typed.type) ++ ")");
}

/// What stops a `get` function's literal zone, or null: a zone that is no `UTC` and no offset.
/// cel-go reads a zone's name too, from the IANA time zone database, which this library does
/// not hold (`cel_timestamp.zig`).
fn zone_problem(comptime operands: []const Node) ?[]const u8 {
    // A `get` function's operands: the timestamp, and its zone.
    const timestamp_and_zone = 2;
    if (operands.len != timestamp_and_zone or operands[1] != .string) return null;
    if (timestamp_file.offset_of_zone(operands[1].string) != null) return null;
    return "the time zone `" ++ operands[1].string ++ "` is no `UTC` and no offset such as `+05:30`, and this module reads no zone names";
}
