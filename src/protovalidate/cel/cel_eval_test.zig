//! Tests of the compiler as a whole: an expression's text, a value for `this`, and what the
//! expression gives, fails with, or is refused for.
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
const Bytes = type_file.Bytes;

const Color = enum(i32) { unspecified = 0, red = 1, _ };

const Inner = struct {
    a: i32 = 0,
    b: i32 = 0,
    pub const FieldNumber = enum(u29) { a = 1, b = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Inner", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}), proto.field_of(FieldNumber.b, .int32, .{}),
    } };
};

const Message = struct {
    a: i32 = 0,
    b: i32 = 0,
    big: u64 = 0,
    ratio: f32 = 0,
    name: []const u8 = "",
    data: []const u8 = "",
    on: bool = false,
    color: Color = .unspecified,
    e: ?Inner = null,
    wrapped: ?proto.wkt.Int32Value = null,
    at: ?proto.wkt.Timestamp = null,
    took: ?proto.wkt.Duration = null,
    maybe: ?i32 = null,
    pub const FieldNumber = enum(u29) { a = 1, b = 2, big = 3, ratio = 4, name = 5, data = 6, on = 7, color = 8, e = 9, wrapped = 10, at = 11, took = 12, maybe = 13 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}),     proto.field_of(FieldNumber.b, .int32, .{}),
        proto.field_of(FieldNumber.big, .uint64, .{}),  proto.field_of(FieldNumber.ratio, .float, .{}),
        proto.field_of(FieldNumber.name, .string, .{}), proto.field_of(FieldNumber.data, .bytes, .{}),
        proto.field_of(FieldNumber.on, .bool, .{}),     proto.field_of(FieldNumber.color, .@"enum", .{}),
        proto.field_of(FieldNumber.e, .message, .{}),   proto.field_of(FieldNumber.wrapped, .message, .{}),
        proto.field_of(FieldNumber.at, .message, .{}),  proto.field_of(FieldNumber.took, .message, .{}),
        proto.field_of(FieldNumber.maybe, .int32, .{}),
    } };
};

const scope: Scope = .{ .types = &.{*const Message} };

/// The value `text` gives for `message`, with no time.
fn run(comptime text: []const u8, message: *const Message) Error!program.Type(text, scope) {
    var env: Env = .{ .cpu_features = &testing_cpu_features };
    return program.run(text, scope, .{message}, &env);
}

fn expect_true(comptime text: []const u8, message: *const Message) !void {
    try testing.expect(try run(text, message));
}

fn expect_false(comptime text: []const u8, message: *const Message) !void {
    try testing.expect(!try run(text, message));
}

fn expect_problem(comptime text: []const u8, comptime expected: []const u8) !void {
    const problem = comptime program.problem_of(text, scope);
    try testing.expectEqualStrings("`" ++ text ++ "`: " ++ expected, problem orelse return error.TestExpectedProblem);
}

/// The numbers of `sample`, which the expressions of the tests state too.
const three = 3;
const four = 4;
const five = 5;
const six = 6;
const nine = 9;
const sample: Message = .{ .a = three, .b = four, .big = five, .ratio = 0.5, .name = "foobar", .data = "\xff\x00", .on = true, .color = .red, .e = .{ .a = six, .b = three }, .maybe = nine };

test "an expression reads fields, compares them and joins the results" {
    try expect_true("this.a < this.b", &sample);
    try expect_false("this.a > this.b", &sample);
    try expect_true("this.a <= 3 && this.b >= 4 && this.a != this.b", &sample);
    try expect_true("this.a == 4 || this.b == 4", &sample);
    try expect_false("!(this.a < this.b)", &sample);
    try expect_true("this.e.a == this.a * 2", &sample);
    try expect_true("this.name == 'foobar' && this.name != \"foo\" && this.name > 'foo'", &sample);
    try expect_true("this.on == true && this.on != false && this.on", &sample);
    try expect_true("this.color == 1", &sample);
    try expect_true("this.data == b'\\xff\\x00' && this.data > b'\\xfe'", &sample);
    try expect_true("this.maybe == 9", &sample);
    // An int, a uint and a double compare by value.
    try expect_true("this.big > this.a && this.big == 5u && this.ratio < this.a && this.ratio == 0.5 && 1u != 2u", &sample);
    // Two numbers of different types stand in an order, and are equal or not behind `dyn` alone.
    try expect_true("dyn(this.big) == 5 && dyn(1u) == 1 && this.big != dyn(5.5) && dyn(this.a) != 3u == false", &sample);
    // Behind `dyn`, two values of unlike types are not equal, and a value of no element's type
    // is no element.
    try expect_true("dyn(this.a) != 'three' && !(dyn(this.name) == this.a) && !(dyn('a') in [1, 2]) && dyn(1u) in [1, 2]", &sample);
    // A "-" before a number is its sign, which a member reads; two are two negations.
    try expect_true("-2.5 < 0.0 && --2.5 > 0.0 && --5 == 5 && !-2.25.isInf() && -1.0.isInf(-1) == false", &sample);
    try expect_true("null == null", &sample);
}

test "arithmetic follows each number's type" {
    try testing.expectEqual(@as(i64, 3 + 4 * 2 - 1), try run("this.a + this.b * 2 - 1", &sample));
    try testing.expectEqual(@as(i64, -3), try run("-this.a", &sample));
    try testing.expectEqual(@as(i64, 3), try run("--this.a", &sample));
    try testing.expectEqual(@as(i64, 1), try run("this.b % this.a", &sample));
    try testing.expectEqual(@as(i64, 2), try run("this.e.a / this.e.b", &sample));
    try testing.expectEqual(@as(u64, 5 * 2), try run("this.big * 2u", &sample));
    try testing.expectEqual(@as(f64, 0.25), try run("this.ratio / 2.0", &sample));
    try testing.expectEqual(@as(f64, -0.5), try run("-this.ratio", &sample));
    try testing.expectError(error.Unevaluable, run("this.a / (this.b - 4)", &sample));
    try testing.expectError(error.Unevaluable, run("this.a % (this.b - 4) == 0", &sample));
    try testing.expectError(error.Unevaluable, run("this.big - 6u", &sample));
    try testing.expectError(error.Unevaluable, run("9223372036854775807 + this.a", &sample));
    // A double that is not a number stands in no order: each comparison with it is false.
    try expect_false("0.0 / (this.ratio - 0.5) <= 1.0 || 0.0 / (this.ratio - 0.5) >= 1.0", &sample);
    try expect_false("0.0 / (this.ratio - 0.5) < 1.0 || 0.0 / (this.ratio - 0.5) > 1.0 || 0.0 / (this.ratio - 0.5) == 0.0 / (this.ratio - 0.5)", &sample);
    try expect_true("0.0 / (this.ratio - 0.5) != 1.0", &sample);
}

test "a conditional gives the side its condition picks" {
    try testing.expectEqualStrings("", try run("this.a < this.b ? '' : 'a must be less than b'", &sample));
    try testing.expectEqualStrings("a must be greater than b", try run("this.a > this.b ? '' : 'a must be greater than b'", &sample));
    try testing.expectEqual(@as(i64, 4), try run("this.on ? this.b : this.a / 0", &sample));
    try testing.expectError(error.Unevaluable, run("!this.on ? this.b : this.a / 0", &sample));
    try testing.expectError(error.Unevaluable, run("this.a / 0 == 1 ? 1 : 2", &sample));
}

test "a side that fails is absorbed when the other side decides" {
    try expect_false("false && this.a / 0 == 1", &sample);
    try expect_false("this.a / 0 == 1 && false", &sample);
    try expect_true("true || this.a / 0 == 1", &sample);
    try expect_true("this.a / 0 == 1 || true", &sample);
    try testing.expectError(error.Unevaluable, run("true && this.a / 0 == 1", &sample));
    try testing.expectError(error.Unevaluable, run("this.a / 0 == 1 && true", &sample));
    try testing.expectError(error.Unevaluable, run("false || this.a / 0 == 1", &sample));
    try testing.expectError(error.Unevaluable, run("this.a / 0 == 1 || this.a / 0 == 1", &sample));
    // Behind `dyn` a side that holds no bool fails, and is absorbed the same way.
    try expect_false("dyn(this.a) && false", &sample);
    try expect_true("true || dyn('a')", &sample);
    try testing.expectError(error.Unevaluable, run("dyn(this.a) && true", &sample));
    try testing.expectError(error.Unevaluable, run("false || dyn(1u)", &sample));
}

test "a field that is not set reads as its default, has tells, and a wrapper is null" {
    const empty: Message = .{};
    try expect_true("this.e.a == 0 && this.name == '' && this.maybe == 0 && this.took == duration('0')", &empty);
    try expect_true("!has(this.e) && !has(this.name) && !has(this.maybe) && !has(this.a) && !has(this.wrapped)", &empty);
    try expect_true("has(this.e) && has(this.name) && has(this.maybe) && has(this.a) && has(this.e.a)", &sample);
    try expect_true("this.wrapped == null && this.wrapped != 0", &empty);
    try expect_true("this.wrapped == 7 && this.wrapped != null && 7 == this.wrapped", &.{ .wrapped = .{ .value = 7 } });
}

test "functions convert and read strings" {
    try expect_true("this.name.startsWith('foo') && this.name.endsWith('bar') && this.name.contains('ob')", &sample);
    try expect_false("this.name.startsWith('bar')", &sample);
    try expect_true("this.name.size() == 6 && size(this.name) == 6 && size(this.data) == 2", &sample);
    try expect_true("uint(this.name.size()) >= 5u", &sample);
    try expect_true("int(this.big) == 5 && uint(this.a) == 3u && double(this.a) == 3.0 && int(this.ratio) == 0", &sample);
    try expect_true("int('12') == 12 && string(b'ab') == 'ab' && bytes('ab') == b'ab' && bool('true')", &sample);
    try testing.expectError(error.Unevaluable, run("uint(this.a - 4) == 0u", &sample));
    try testing.expectError(error.Unevaluable, run("string(this.data) == ''", &sample));
    try testing.expectError(error.Unevaluable, run("int(this.name) == 0", &sample));
}

test "matches finds a pattern in any part of a string, as a function and on a target" {
    try expect_true("this.name.matches('ob') && matches(this.name, '^foo') && this.name.matches('(?i)^FOO[a-z]+$')", &sample);
    try expect_false("this.name.matches('^bar') || matches(this.name, 'baz')", &sample);
    try expect_true("'a/b'.matches('^([^/.][^/]?|[^/][^/.]|[^/]{3,})(/([^/.][^/]?|[^/][^/.]|[^/]{3,}))*$')", &sample);
    try expect_false("'a/..'.matches('^([^/.][^/]?|[^/][^/.]|[^/]{3,})(/([^/.][^/]?|[^/][^/.]|[^/]{3,}))*$')", &sample);
    try testing.expectError(error.Unevaluable, run("string(this.data).matches('a')", &sample));
}

test "protovalidate's functions check a string's form" {
    const address: Message = .{ .name = "10.0.0.0/8", .a = 4, .on = true };
    try expect_true("this.name.isIpPrefix() && this.name.isIpPrefix(this.a) && this.name.isIpPrefix(this.on) && this.name.isIpPrefix(this.a, this.on)", &address);
    try expect_false("this.name.isIp() || this.name.isIpPrefix(6) || this.name.isEmail() || this.name.isUri()", &address);
    try expect_true("'ada@example.com'.isEmail() && 'example.com'.isHostname() && 'a:80'.isHostAndPort(true) && '/a'.isUriRef() && 'a:b'.isUri()", &address);
    try expect_true("has(this.a) ? this.name.isIpPrefix(this.a) : this.name.isIpPrefix()", &address);
    try expect_true("(0.0 / (this.ratio)).isNan() && (1.0 / this.ratio).isInf() && (1.0 / this.ratio).isInf(1) && !(1.0 / this.ratio).isInf(0 - 1)", &address);
    try expect_problem("this.a.isEmail()", "found no matching overload for `isEmail` applied to (int)");
    try expect_problem("this.name.isIp('4')", "found no matching overload for `isIp` applied to (string, string)");
}

test "a duration and a timestamp compare, and now is the time the caller passes" {
    const timed: Message = .{ .at = .{ .seconds = 1_049_587_300 }, .took = .{ .seconds = 9, .nanos = 5 } };
    try expect_true("this.took <= duration('10s') && this.took > duration('9s') && this.took != duration('9s')", &timed);
    try expect_true("this.took > duration('-3s') && this.took < duration('+1h') && duration('-1.5s') < duration('0')", &timed);
    try expect_false("this.took <= duration('9s')", &timed);
    try expect_true("int(this.at) >= 1049587200 && int(this.at) <= 1080432000", &timed);
    try testing.expectError(error.TimeMissing, run("this.at < now", &timed));
    try testing.expectError(error.TimeMissing, run("now == now", &timed));
    var later: Env = .{ .cpu_features = &testing_cpu_features, .now = .{ .seconds = 1_049_587_301 } };
    try testing.expect(try program.run("this.at < now && now == now && !(now < this.at)", scope, .{&timed}, &later));
    try testing.expect(!try program.run("this.at > now", scope, .{&timed}, &later));
    // A check that reads no time needs none.
    try expect_true("false && this.at < now || true", &timed);
}

test "dyn moves a mistake of types to the run" {
    try testing.expectError(error.Unevaluable, run("dyn(this).missing == 'foo'", &sample));
    try testing.expectError(error.Unevaluable, run("dyn(this.a).b", &sample));
    try testing.expectError(error.Unevaluable, run("!dyn(this.a)", &sample));
    try testing.expectError(error.Unevaluable, run("dyn(this.name).size() + dyn(this).missing > 0", &sample));
    try testing.expectError(error.Unevaluable, run("has(dyn(this).missing)", &sample));
    // What a function gives for a part that came through `dyn` came through it too, and two
    // values of unlike types are not equal.
    try expect_false("dyn(this).a == 'foo' || dyn(this.name).size() == 'six' || -dyn(this.a) == 'three'", &sample);
    try expect_true("dyn(this).a != 'foo' && dyn(this.name).size() != 'six'", &sample);
    try testing.expectError(error.Unevaluable, run("dyn(this.name).size() < 'six'", &sample));
    try expect_true("dyn(this).a == 3 && dyn(this.name).startsWith('foo')", &sample);
    // A side that fails is absorbed as any failure is, and a conditional may skip it.
    try expect_false("false && dyn(this).missing == 1", &sample);
    try expect_true("dyn(this).missing == 1 || true", &sample);
    try testing.expectEqual(@as(i64, 3), try run("true ? this.a : dyn(this).missing", &sample));
    try testing.expectError(error.Unevaluable, run("false ? this.a : dyn(this).missing", &sample));
    try testing.expectError(error.Unevaluable, run("dyn(this).missing ? 1 : 2", &sample));
}

test "an expression that does not parse or does not type is a problem of the build" {
    try expect_problem("this.a <", "the expression ends early");
    try expect_problem("this.missing > 0", "undefined field `missing` of t.Message");
    try expect_problem("this.e.missing > 0", "undefined field `missing` of t.Inner");
    try expect_problem("this.a.b", "type `int` has no field `b`");
    try expect_problem("that.a", "undeclared reference to `that`");
    try expect_problem("this.a.startsWith('foo')", "found no matching overload for `startsWith` applied to (int, string)");
    try expect_problem("this.a == 'foo'", "found no matching overload for `==` applied to (int, string)");
    try expect_problem("this.big == 5", "found no matching overload for `==` applied to (uint, int)");
    try expect_problem("this.ratio != this.a", "found no matching overload for `!=` applied to (double, int)");
    try expect_problem("this.wrapped == 1u", "found no matching overload for `==` applied to (wrapper(int), uint)");
    try expect_problem("this.a + 1u", "found no matching overload for `+` applied to (int, uint)");
    try expect_problem("this.name + 1", "found no matching overload for `+` applied to (string, int)");
    try expect_problem("this.on * this.on", "found no matching overload for `*` applied to (bool, bool)");
    try expect_problem("this.ratio % 2.0", "found no matching overload for `%` applied to (double, double)");
    try expect_problem("this.name < 1", "found no matching overload for `<` applied to (string, int)");
    try expect_problem("this.on && 1", "found no matching overload for `&&` applied to (bool, int)");
    try expect_problem("this.a || this.on", "found no matching overload for `||` applied to (int, bool)");
    try expect_problem("!this.a", "found no matching overload for `!` applied to (int)");
    try expect_problem("-this.big", "found no matching overload for `-` applied to (uint)");
    try expect_problem("-this.name", "found no matching overload for `-` applied to (string)");
    try expect_problem("this.a ? 1 : 2", "the condition of `? :` is a int");
    try expect_problem("this.on ? 1 : 'one'", "the sides of `? :` are a int and a string");
    try expect_problem("has(this)", "`has` takes one field selection");
    try expect_problem("has(this.missing)", "undefined field `missing` of t.Message");
    try expect_problem("has(this.a.b)", "type `int` has no field `b`");
    try expect_problem("duration(this.a)", "found no matching overload for `duration` applied to (int)");
    try expect_problem("duration('ten')", "`ten` is no duration");
    try expect_problem("this.name.matches(this.name)", "the pattern of `matches` is no string literal, and this module reads each pattern as it compiles");
    try expect_problem("this.name.matches('(')", "stdx's regular expressions refuse the pattern `(`: MissingParenthesis");
    try expect_problem("this.a.matches('a')", "found no matching overload for `matches` applied to (int, string)");
    try expect_problem("unknown(this.a)", "undeclared reference to `unknown`");
    // A name the module holds no function for, with the operands of a function it holds.
    try expect_problem("this.name.nothing()", "undeclared reference to `nothing`");
    try expect_problem("dyn(this.name).nothing() || true", "undeclared reference to `nothing`");
    // A conversion of a literal is computed once: one that fails is a problem of the build.
    try expect_problem("int('x') == 1", "the conversion `int` fails for its constant operand");
    try expect_problem("this.on || bool('k')", "the conversion `bool` fails for its constant operand");
    try expect_problem("uint(-1) == 1u", "the conversion `uint` fails for its constant operand");
    try expect_problem("double('b') > 1.0", "the conversion `double` fails for its constant operand");
    try expect_problem("string(b'\\xff') == ''", "the conversion `string` fails for its constant operand");
    // A conversion of a conversion of a constant is computed too, as cel-go computes it.
    try expect_problem("uint(double(-100)) == 1u", "the conversion `uint` fails for its constant operand");
    try expect_problem("int(string(1.5)) == 1", "the conversion `int` fails for its constant operand");
    try expect_problem("int(dyn('x')) == 1", "the conversion `int` fails for its constant operand");
    try expect_problem("dyn(this.a, this.b)", "found no matching overload for `dyn` applied to (int, int)");
    try testing.expect(comptime program.problem_of("this.a < this.b", scope) == null);
}

test "this may be a scalar, as a field's rule has it" {
    const of_int: Scope = .{ .types = &.{i64} };
    var env: Env = .{ .cpu_features = &testing_cpu_features };
    try testing.expect(try program.run("this > 42", of_int, .{@as(i64, 43)}, &env));
    try testing.expect(!try program.run("this > 42", of_int, .{@as(i64, 42)}, &env));
    try testing.expect(try program.run("this % 2u == 0u", .{ .types = &.{u64} }, .{@as(u64, 4)}, &env));
    try testing.expect(try program.run("this.startsWith('a')", .{ .types = &.{[]const u8} }, .{@as([]const u8, "abc")}, &env));
    try testing.expect(comptime program.problem_of("this.a", of_int) != null);
}
