//! Tests of list and map literals whose elements are of two types or more (`cel_mixed.zig`).
const std = @import("std");
const testing = std.testing;
/// The build target's CPU features, which `matches` searches with in the tests.
const testing_cpu_features = @import("stdx").platform.CpuFeatures.target();
const proto = @import("protobuf");
const program = @import("cel_program.zig");
const type_file = @import("cel_type.zig");
const Scope = type_file.Scope;
const Env = type_file.Env;
const Error = type_file.Error;

const CountsEntry = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message.CountsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

const Message = struct {
    name: []const u8 = "",
    count: i32 = 0,
    numbers: proto.Repeated(i32, .int32) = .{},
    counts: proto.Repeated(CountsEntry, .message) = .{},
    pub const FieldNumber = enum(u29) { name = 1, count = 2, numbers = 3, counts = 4 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),   proto.field_of(FieldNumber.count, .int32, .{}),
        proto.field_of(FieldNumber.numbers, .int32, .{}), proto.field_of(FieldNumber.counts, .message, .{}),
    } };
};

const scope: Scope = .{ .types = &.{*const Message} };

fn run(comptime text: []const u8, message: *const Message) Error!program.Type(text, scope) {
    var env: Env = .{ .cpu_features = &testing_cpu_features };
    return program.run(text, scope, .{message}, &env);
}

fn expect_true(comptime text: []const u8, message: *const Message) !void {
    try testing.expect(try run(text, message));
}

fn expect_problem(comptime text: []const u8, comptime expected: []const u8) !void {
    const problem = comptime program.problem_of(text, scope);
    try testing.expectEqualStrings("`" ++ text ++ "`: " ++ expected, problem orelse return error.TestExpectedProblem);
}

const two = 2;
const four = 4;
const sample: Message = .{
    .name = "ann",
    .count = 1,
    .numbers = .of(&.{ two, four }),
    .counts = .of(&.{ .{ .key = "a", .value = 1 }, .{ .key = "b", .value = two } }),
};

test "a list literal of two element types is a list of each" {
    try expect_true("[1, 'a'].size() == 2 && size([1, 'a', 2u]) == 3 && type([1, 'a']) == list && type(dyn([1, 'one'])) == list", &sample);
    try expect_true("'elem' in [1, 'elem', 2] && !('elem' in [1u, 'str', 2, b'bytes']) && 2u in [1, 2.0, 'x']", &sample);
    // An index the build knows reads its element, of its own type.
    try expect_true("[1, 'a'][1] == 'a' && [1, 'a'][0] + 1 == 2 && [this.name, 7][0] == 'ann'", &sample);
    try testing.expectError(error.Unevaluable, run("[1, 'a'][2] == 1", &sample));
}

test "two lists are equal when each element equals the one at its place" {
    try expect_true("[1.0, 2.0, 3] == [1u, 2, 3u] && [1, 2, null] != [1, null, 3] && [1, 'dos', 3] != [1, 2, 4]", &sample);
    try expect_true("[1, 'a'] == [1, 'a'] && [1, 'a'] != [1, 'a', 2] && [1, 'a'] != [1] && [1.0, 2.1] != [1u, 2]", &sample);
    try expect_true("this.numbers == [2, 4.0] && [2u, 4] == this.numbers && this.numbers != [2, 'four']", &sample);
    try expect_true("[[1], [2, 3]] == [[1], [2, 3]] && [[1], [2, 3]] != [[1], [2, 4]] && [1, 'a'] in [[1, 'a'], [2]]", &sample);
    try expect_true("[2u, 4.0] != [2, 4, 6] && [2u, 4.0] == [2, 4] && [2, 4, 6] != [2u, 4.0]", &sample);
}

test "a macro reads each element as behind dyn, and absorbs a failure as the logic operators do" {
    try expect_true("![1, 'foo', 3].all(e, e == 1) && [1, 'foo', 3].exists(e, e != '1') && ![1, 'foo', 3].exists(e, e == '10')", &sample);
    try expect_true("[1, 'a', 2u].exists_one(e, e == 'a') && ![1, 'a', 1u].exists_one(e, e == 1) && [1, 'x'].all(e, e != this.name)", &sample);
    // 'foo' % 2 fails, and no other element gives `all` its absorbing false.
    try testing.expectError(error.Unevaluable, run("[1, 'foo', 3].all(e, e % 2 == 1)", &sample));
    try expect_true("![1, 'foo', 2].all(e, e % 2 == 1)", &sample);
    try testing.expectError(error.Unevaluable, run("[1, 'a'].all(e, e)", &sample));
}

test "a map literal of two key or value types holds each entry" {
    try expect_true("{'k': 'v', 1: 1}.size() == 2 && type({'a': 1, 2: 'b'}) == map && 'key' in {3: 3.0, 'key': 2u}", &sample);
    try expect_true("!('key' in {1u: 'str', 2: b'bytes'}) && 3.0 in {1: 1, 2: 2, 3u: 3} && !(3.1 in {1: 1, 2: 2, 3u: 3})", &sample);
    // Values of one type are read at any key; values of two types at a key the build knows.
    try expect_true("{true: 1, 2: 2, 5u: 3}[true] == 1 && {1u: 1.0, 2: 2.0, 3u: 3.0}[3.0] == 3.0 && {1u: 1.0, 2: 2.0}[this.count] == 1.0", &sample);
    try expect_true("{0u: 1u, 2u: 'happy', 5u: 3u}[2u] == 'happy' && {0: 1, 2: 2, 5: true}[5] && {'m': {'k': 'v'}, 'l': [1]}['m'].k == 'v'", &sample);
    try testing.expectError(error.Unevaluable, run("{1u: 1.0, 2: 2.0}[3.1] == 1.0", &sample));
    try testing.expectError(error.Unevaluable, run("{0u: 1u, 2u: 'happy'}[7u] == 1u", &sample));
    // Two keys equal as numbers fail the run.
    try testing.expectError(error.Unevaluable, run("{0: 1, 0u: 2}[0.0] == 1", &sample));
    try expect_true("!{'key': 1, 1: 42}.exists(k, k == 2) && {'key': 1, 1: 21}.exists(k, k != 2) && {'a': 1, 2: 'b'}.exists_one(k, k == 2)", &sample);
}

test "two maps are equal when they hold the same keys with equal values" {
    try expect_true("{1: 1.0, 2u: 3u} == {1u: 1, 2: 3.0} && {'k': 'v', 1: 1} != {'k': 'v', 1: 'v1'} && {'k': 1, 'j': 2} != {'k': 1, 'j': null}", &sample);
    try expect_true("{'a': 1, 'b': 2u} == {'a': 1, 'b': 2} && {'a': 1, 'b': 2} == {'a': 1, 'b': 2u} && {'a': 1, 'b': 2u} != {'a': 1, 'b': 3}", &sample);
    try expect_true("{'a': 1, 'b': 2u} == this.counts && this.counts != {'a': 1, 'c': 2u} && {'a': 1, 'b': 2u} != {'a': 1}", &sample);
    try expect_true("{'a': 1, 2: 'b'} != {'a': 1, 2: 'b', 3: 'c'} && {'a': 1, 2: 'b'} == {2: 'b', 'a': 1}", &sample);
    try expect_true("{'a': 1, 2: 2} != {'a': 1, 'b': 2} && {'a': 1, 'b': 2} != {'a': 1, 2: 2}", &sample);
}

test "`in` and an index read each element in turn" {
    var counted: Env = .{ .cpu_features = &testing_cpu_features, .steps = 2 };
    try testing.expect(try program.run("'b' in [1, 'b']", scope, .{&sample}, &counted));
    counted.steps = 1;
    try testing.expectError(error.TooManyItems, program.run("'b' in [1, 'b']", scope, .{&sample}, &counted));
    counted.steps = 2;
    try testing.expect(try program.run("{1u: 1.0, 2: 2.0}[2] == 2.0", scope, .{&sample}, &counted));
    counted.steps = 1;
    try testing.expectError(error.TooManyItems, program.run("{1u: 1.0, 2: 2.0}[2] == 2.0", scope, .{&sample}, &counted));
}

test "what a mixed list or map gives no one type for stops the build" {
    try expect_problem("[1, 'a'][this.count]", "an index of a `list(dyn)` whose elements are of two types, at a place the build does not know");
    try expect_problem("{1: 'a', 2: 3}[this.count]", "an index of a `map(dyn, dyn)` whose values are of two types, at a place the build does not know");
    try expect_problem("[1, 'a'].filter(e, true)", "the macro `filter` reads no `list(dyn)`, whose elements are of two types");
    try expect_problem("{1.5: 2, 'a': 3}", "a map's key is an int, a uint, a bool or a string, not a double");
    try expect_problem("[1, 'a'] == 1", "found no matching overload for `==` applied to (list(dyn), int)");
}
