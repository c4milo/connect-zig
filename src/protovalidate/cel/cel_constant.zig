//! The value of a part of an expression that reads no name: a literal, or a type conversion of
//! a constant. protovalidate-go builds each program with cel-go's `OptOptimize`, which computes
//! a type conversion of a constant once, before the expression runs, from the inside out, and
//! refuses the rule when one fails (docs/specs/README.md). So `uint(double(-100))` stops the
//! build here, as `uint(-1)` does.
const std = @import("std");
const proto = @import("protobuf");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const function = @import("cel_function.zig");
const time_literal = @import("cel_time_literal.zig");
const Node = node_file.Node;
const Function = node_file.Function;
const Bytes = type_file.Bytes;

/// A constant's value, of each type a conversion takes or gives.
pub const Constant = union(enum) {
    int: i64,
    uint: u64,
    double: f64,
    boolean: bool,
    string: []const u8,
    bytes: Bytes,
    timestamp: proto.wkt.Timestamp,
    duration: proto.wkt.Duration,
};

/// Whether `converter` is one of the type conversions cel-go computes for a constant: those of
/// cel-go's `IsTypeConversionFunction` that may fail here. `dyn` and `type` never fail, and a
/// literal of `duration` or `timestamp` is checked where it is typed.
pub fn is_conversion(converter: Function) bool {
    return switch (converter) {
        .int, .uint, .double, .string, .bytes, .bool => true,
        else => false,
    };
}

/// The value of `node` when it reads no name, or null: a literal, `dyn`, `duration` or
/// `timestamp` of a constant, or a conversion of a constant that does not fail.
pub fn value_of(comptime node: *const Node) ?Constant {
    return switch (node.*) {
        .int => |value| .{ .int = value },
        .uint => |value| .{ .uint = value },
        .double => |value| .{ .double = value },
        .boolean => |value| .{ .boolean = value },
        .string => |value| .{ .string = value },
        .bytes => |octets| .{ .bytes = .{ .octets = octets } },
        .call => |call| of_call(call),
        else => null,
    };
}

fn of_call(comptime call: Node.Call) ?Constant {
    if (call.target != null or call.arguments.len != 1) return null;
    const operand = &call.arguments[0];
    return switch (call.function) {
        .dyn => value_of(operand),
        .duration => if (operand.* == .string and time_literal.Valid(proto.wkt.Duration, operand.string).value) .{ .duration = time_literal.Literal(proto.wkt.Duration, operand.string).value } else null,
        .timestamp => if (operand.* == .string and time_literal.Valid(proto.wkt.Timestamp, operand.string).value) .{ .timestamp = time_literal.Literal(proto.wkt.Timestamp, operand.string).value } else null,
        else => if (is_conversion(call.function)) convert(call.function, value_of(operand) orelse return null) else null,
    };
}

/// `converter` of `operand`, or null when it fails or takes no such operand.
pub fn convert(comptime converter: Function, comptime operand: Constant) ?Constant {
    switch (operand) {
        inline else => |value| {
            const R = function.Result(converter, &.{@TypeOf(value)}) orelse return null;
            if (comptime converter == .string and @TypeOf(value) != Bytes and @TypeOf(value) != []const u8) {
                return .{ .string = time_literal.Text(value).value };
            }
            const result = function.run(converter, R, .{value}) catch return null;
            return of_value(result);
        },
    }
}

fn of_value(comptime value: anytype) Constant {
    return switch (@TypeOf(value)) {
        i64 => .{ .int = value },
        u64 => .{ .uint = value },
        f64 => .{ .double = value },
        bool => .{ .boolean = value },
        []const u8 => .{ .string = value },
        Bytes => .{ .bytes = value },
        else => comptime unreachable,
    };
}

const testing = std.testing;

fn parsed(comptime text: []const u8) *const Node {
    return comptime @import("cel_parse.zig").tree_of(text);
}

/// The value of `text`, which must be a constant.
fn expect_constant(comptime text: []const u8) !Constant {
    const value = comptime value_of(parsed(text));
    return value orelse error.TestExpectedConstant;
}

test "a conversion of a constant is computed from the inside out" {
    try testing.expectEqual(@as(f64, -100), (try expect_constant("double(-100)")).double);
    try testing.expect(comptime value_of(parsed("uint(double(-100))")) == null);
    try testing.expectEqualStrings("1.5", (try expect_constant("string(1.5)")).string);
    try testing.expectEqual(@as(i64, 2), (try expect_constant("int(string(2u))")).int);
    try testing.expectEqualStrings("1s", (try expect_constant("string(duration('1s'))")).string);
    try testing.expect(comptime value_of(parsed("int(string(duration('1s')))")) == null);
    try testing.expectEqual(@as(i64, 3), (try expect_constant("dyn(int(3.5))")).int);
    try testing.expectEqual(@as(i64, 2), (try expect_constant("dyn(2)")).int);
    try testing.expect(comptime value_of(parsed("int(this.a)")) == null);
}
