//! Tests of map literals, `{k: v, ...}`, and of `==` of two maps (`cel_map_literal.zig` and
//! `cel_equal.zig`).
const std = @import("std");
const testing = std.testing;
/// The build target's CPU features, which `matches` searches with in the tests.
const testing_cpu_features = @import("stdx").platform.CpuFeatures.target();
const proto = @import("protobuf");
/// The tests decode and encode with the build target's CPU features.
const protobuf_decoder: proto.Decoder = .init(.target());
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
    numbers: proto.Repeated(i32, .int32) = .{},
    counts: proto.Repeated(CountsEntry, .message) = .{},
    pub const FieldNumber = enum(u29) { name = 1, numbers = 2, counts = 3 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),    proto.field_of(FieldNumber.numbers, .int32, .{}),
        proto.field_of(FieldNumber.counts, .message, .{}),
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
/// A map with the key "b" twice: its last entry is the map's.
const sample: Message = .{
    .name = "ann",
    .numbers = .of(&.{ two, four }),
    .counts = .of(&.{ .{ .key = "a", .value = 1 }, .{ .key = "b", .value = four }, .{ .key = "b", .value = two } }),
};
/// Room for `sample` encoded.
const encoded_len_max = 64;

test "a map literal gives the value of each of its keys" {
    try expect_true("{'a': 1, 'b': 2}['b'] == 2 && {1: 'x'}[1] == 'x' && {true: 1, false: 2}[false] == 2", &sample);
    try expect_true("{1u: 2u}[1u] == 2u && {'a': 1}.a == 1 && {'k': [1]}['k'] == [1] && {'m': {'k': 'v'}}.m.k == 'v'", &sample);
    try expect_true("has({'a': 1}.a) && !has({'a': 1}.b) && !has({}.a) && type({1: 2}) == map", &sample);
    try expect_true("size({}) == 0 && size({'a': 1, 'b': 2}) == 2 && {'a': 1}.size() == 1", &sample);
    try expect_true("'a' in {'a': 1} && !('b' in {'a': 1}) && !('a' in {}) && {this.name: this.numbers}.ann == [2, 4]", &sample);
    // A key the map does not hold fails the run.
    try testing.expectError(error.Unevaluable, run("{'a': 1}['b'] == 1", &sample));
    try testing.expectError(error.Unevaluable, run("{}.a == 1", &sample));
}

test "a map literal's index reads each key until it finds the one it looks for" {
    // Two keys read, of a map whose keys are known: no entry is read as the map is built.
    var counted: Env = .{ .cpu_features = &testing_cpu_features, .steps = 2 };
    try testing.expect(try program.run("{'a': 1, 'b': 2}['b'] == 2", scope, .{&sample}, &counted));
    counted.steps = 1;
    try testing.expectError(error.TooManyItems, program.run("{'a': 1, 'b': 2}['b'] == 2", scope, .{&sample}, &counted));
}

test "two equal keys of a map literal fail the run" {
    try testing.expectError(error.Unevaluable, run("{'a': 1, 'a': 2}.size() == 1", &sample));
    try testing.expectError(error.Unevaluable, run("{1: 2, 3: 4, 1: 5}.size() == 2", &sample));
    try testing.expectError(error.Unevaluable, run("{this.name: 1, 'ann': 2}.size() == 2", &sample));
    try expect_true("{this.name: 1, 'bob': 2}.size() == 2", &sample);
}

test "a macro reads each key of a map literal" {
    try expect_true("{'a': 1, 'b': 2}.all(k, k.size() == 1) && {'a': 1}.exists(k, k == 'a') && !{'a': 1}.exists(k, k == 'b')", &sample);
    try expect_true("{6: 'six', 7: 'seven', 8: 'eight'}.exists_one(k, k % 5 == 2) && {}.all(k, false) && !{}.exists(k, true)", &sample);
    try expect_true("{'John': 'smart'}.map(k, k) == ['John'] && {'a': 1, 'b': 2}.filter(k, k == 'b') == ['b']", &sample);
    try expect_true("{'a': 1, 'b': 2}.all(k, {'a': 1, 'b': 2}[k] < 3)", &sample);
}

test "two maps are equal when they hold the same keys with equal values" {
    try expect_true("{'k1': 'v1', 'k2': 'v2'} == {'k2': 'v2', 'k1': 'v1'} && {'k': 'v'} != {'k': 'v1'}", &sample);
    try expect_true("{'k': 'v', 'k1': 'v1'} != {'k': 'v'} && {'k': 'v'} != {'k': 'v', 'k1': 'v1'} && {'k': 'v'} != {'j': 'v'}", &sample);
    try expect_true("{} == {} && {} != {'a': 1} && {'a': 1} != {} && {'k': 1.0} == {'k': 1e+0} && {'k': null} == {'k': null}", &sample);
    try expect_true("{'m': {'k': 1}} == {'m': {'k': 1}} && {'m': {'k': 1}} != {'m': {'k': 2}} && {'l': [1]} != {'l': [2]}", &sample);
    // A message's map is the map of its last entry for each key.
    try expect_true("this.counts == {'a': 1, 'b': 2} && {'b': 2, 'a': 1} == this.counts && this.counts != {'a': 1, 'b': 4}", &sample);
    try expect_true("this.counts == this.counts && this.counts != {'a': 1}", &sample);
    var octets: [encoded_len_max]u8 = undefined;
    const viewed = try protobuf_decoder.decode(Message, try proto.encode(Message, &sample, &octets));
    try testing.expect(viewed.counts.items.len == 0 and viewed.counts.view.bytes.len != 0);
    try expect_true("this.counts == {'a': 1, 'b': 2} && this.counts != {'a': 1, 'b': 4}", &viewed);
    // Behind `dyn` the keys and the values are compared as they run.
    try expect_true("dyn({1: 2}) == {1u: 2u} && dyn({'a': 1}) != {1: 1} && dyn({}) != {1: 1} && dyn({}) == {}", &sample);
}

test "a map literal's key is an int, a uint, a bool or a string" {
    try expect_problem("{1.5: 2}", "a map's key is an int, a uint, a bool or a string, not a double");
    try expect_problem("{1: 2} == {'a': 2}", "found no matching overload for `==` applied to (map(int, int), map(string, int))");
    try expect_problem("{1: 2}['a']", "found no matching overload for `[]` applied to (map(int, int), string)");
}
