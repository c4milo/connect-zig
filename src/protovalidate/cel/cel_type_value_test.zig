//! Tests of types as values in an expression: `type(x)`, CEL's own type names, and a message's
//! or a well-known type's full name (CEL language definition, "Type Values").
const std = @import("std");
const testing = std.testing;
/// The build target's CPU features, which `matches` searches with in the tests.
const testing_cpu_features = @import("stdx").platform.CpuFeatures.target();
const proto = @import("protobuf");
const program = @import("cel_program.zig");
const type_file = @import("cel_type.zig");
const Scope = type_file.Scope;
const Env = type_file.Env;

const Leaf = struct {
    name: []const u8 = "",
    pub const FieldNumber = enum(u29) { name = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Leaf", .fields = &.{proto.field_of(FieldNumber.name, .string, .{})} };
};

const CountsEntry = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message.CountsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

const Message = struct {
    leaf: ?Leaf = null,
    numbers: proto.Repeated(i32, .int32) = .{},
    counts: proto.Repeated(CountsEntry, .message) = .{},
    at: ?proto.wkt.Timestamp = null,
    boxed: ?proto.wkt.Int64Value = null,
    pub const FieldNumber = enum(u29) { leaf = 1, numbers = 2, counts = 3, at = 4, boxed = 5 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.leaf, .message, .{}),   proto.field_of(FieldNumber.numbers, .int32, .{}),
        proto.field_of(FieldNumber.counts, .message, .{}), proto.field_of(FieldNumber.at, .message, .{}),
        proto.field_of(FieldNumber.boxed, .message, .{}),
    } };
};

const scope: Scope = .{ .types = &.{*const Message} };

fn expect_true(comptime text: []const u8, message: *const Message) !void {
    var env: Env = .{ .cpu_features = &testing_cpu_features };
    try testing.expect(try program.run(text, scope, .{message}, &env));
}

fn expect_problem(comptime text: []const u8, comptime expected: []const u8) !void {
    const problem = comptime program.problem_of(text, scope);
    try testing.expectEqualStrings("`" ++ text ++ "`: " ++ expected, problem orelse return error.TestExpectedProblem);
}

const empty: Message = .{};

test "type gives each value's type, and CEL's own type names name them" {
    try expect_true("type(1) == int && type(1u) == uint && type(1.5) == double && type(true) == bool", &empty);
    try expect_true("type('a') == string && type(b'a') == bytes && type(null) == null_type && type(1) != string", &empty);
    try expect_true("type([1]) == list && type(this.numbers) == list && type(this.counts) == map && type(type(1)) == type", &empty);
    try expect_true("type(type(1)) == type(string) && type(dyn(1)) == int && type(this.numbers.filter(n, n > 0)) == list", &empty);
    try expect_true("type(1) in [int, uint] && !(type(1.5) in [int, uint]) && int == int && int != uint", &empty);
    // Two names of one length are two types.
    try expect_true("type(1) != map && type(true) != list && type(1u) != bool", &empty);
}

test "a message's full name and a well-known type's name a type" {
    try expect_true("type(this) == t.Message && type(this.leaf) == t.Leaf && type(this.leaf) != t.Message", &empty);
    try expect_true("type(this.at) == google.protobuf.Timestamp && type(duration('1s')) == google.protobuf.Duration", &empty);
}

test "a wrapper's type is null_type when it is not set, and the type it wraps when it is" {
    try expect_true("type(this.boxed) == null_type", &empty);
    const boxed: Message = .{ .boxed = .{ .value = 1 } };
    try expect_true("type(this.boxed) == int", &boxed);
}

test "a name in scope hides a type's name" {
    try expect_true("[1].all(int, int == 1) && [2].exists(t, t == 2)", &empty);
}

test "a type an expression cannot name or compare stops the build" {
    try expect_problem("type(1) == integer", "undeclared reference to `integer`");
    try expect_problem("type(1) < int", "found no matching overload for `<` applied to (type, type)");
    try expect_problem("type(1) == google.protobuf.Nothing", "undeclared reference to `google`");
    try expect_problem("type(1) == t.Missing", "undeclared reference to `t`");
}
