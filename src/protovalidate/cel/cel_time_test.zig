//! Tests of timestamps and durations in an expression: `timestamp` and `duration` of a text
//! the build does not know, arithmetic, the `get` functions in UTC and in a zone, and their
//! text (CEL language definition, "Types and Conversions", "Arithmetic Operators", "Date/Time
//! Functions" and "Timezones").
const std = @import("std");
const testing = std.testing;
/// The build target's CPU features, which `matches` searches with in the tests.
const testing_cpu_features = @import("stdx").platform.CpuFeatures.target();
const proto = @import("protobuf");
const program = @import("cel_program.zig");
const type_file = @import("cel_type.zig");
const Scope = type_file.Scope;
const Env = type_file.Env;
const Text = type_file.Text;
const Timestamp = proto.wkt.Timestamp;
const Duration = proto.wkt.Duration;

const Message = struct {
    at: ?Timestamp = null,
    wait: ?Duration = null,
    text: []const u8 = "",
    zone: []const u8 = "",
    pub const FieldNumber = enum(u29) { at = 1, wait = 2, text = 3, zone = 4 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.at, .message, .{}),  proto.field_of(FieldNumber.wait, .message, .{}),
        proto.field_of(FieldNumber.text, .string, .{}), proto.field_of(FieldNumber.zone, .string, .{}),
    } };
};

const scope: Scope = .{ .types = &.{*const Message} };

/// The room of the tests that write a timestamp's or a duration's text.
const room_len = 64;

fn run(comptime text: []const u8, message: *const Message) !program.Type(text, scope) {
    var room: [room_len]u8 = undefined;
    var held: Text = .{ .room = &room };
    // 2023-12-25T00:00:00Z.
    var env: Env = .{ .cpu_features = &testing_cpu_features, .now = .{ .seconds = christmas }, .text = &held };
    return program.run(text, scope, .{message}, &env);
}

fn expect_true(comptime text: []const u8, message: *const Message) !void {
    try testing.expect(try run(text, message));
}

fn expect_problem(comptime text: []const u8, comptime expected: []const u8) !void {
    const problem = comptime program.problem_of(text, scope);
    try testing.expectEqualStrings("`" ++ text ++ "`: " ++ expected, problem orelse return error.TestExpectedProblem);
}

/// The times of `sample`, which the expected values state too: 2023-12-25T00:00:00Z, half a
/// second before it, and ninety seconds.
const christmas = 1_703_462_400;
const half_second_nanos = 500_000_000;
const ninety_seconds = 90;
const sample: Message = .{ .at = .{ .seconds = christmas - 1, .nanos = half_second_nanos }, .wait = .{ .seconds = ninety_seconds }, .text = "2023-12-25T00:00:00Z", .zone = "+01:00" };

test "a timestamp and a duration add and subtract" {
    try expect_true("timestamp('2023-12-25T00:00:00Z') + duration('1h') == timestamp('2023-12-25T01:00:00Z')", &sample);
    try expect_true("duration('1h') + timestamp('2023-12-25T00:00:00Z') == timestamp('2023-12-25T01:00:00+01:00') + duration('1h')", &sample);
    try expect_true("timestamp('2023-12-25T01:00:00Z') - timestamp('2023-12-25T00:00:00Z') == duration('1h')", &sample);
    try expect_true("now - this.at == duration('0.5s') && this.at - duration('1s') < this.at && this.at + this.wait > now", &sample);
    try expect_true("duration('1h') + duration('30m') == duration('90m') && duration('1h') - duration('2h') == duration('-1h')", &sample);
    // A timestamp past the last one, and a span of nanoseconds past an int64, fail.
    try testing.expectError(error.Unevaluable, run("timestamp('9999-12-31T23:59:59Z') + duration('1s') > now", &sample));
    try testing.expectError(error.Unevaluable, run("timestamp('9999-12-31T23:59:59Z') - timestamp('0001-01-01T00:00:00Z') > duration('0s')", &sample));
}

test "the parts of a timestamp in UTC and in a zone, and of a duration" {
    try expect_true("timestamp('2023-12-25T12:30:45.678Z').getFullYear() == 2023 && timestamp('2023-12-25T12:30:45.678Z').getMonth() == 11", &sample);
    try expect_true("now.getDate() == 25 && now.getDayOfMonth() == 24 && now.getDayOfYear() == 358 && now.getDayOfWeek() == 1", &sample);
    try expect_true("timestamp('2023-12-25T12:30:45.678Z').getHours() == 12 && timestamp('2023-12-25T12:30:45.678Z').getMinutes() == 30", &sample);
    try expect_true("timestamp('2023-12-25T12:30:45.678Z').getSeconds() == 45 && timestamp('2023-12-25T12:30:45.678Z').getMilliseconds() == 678", &sample);
    try expect_true("now.getDate('-08:00') == 24 && now.getHours('+05:30') == 5 && now.getMinutes('+05:30') == 30 && now.getHours('UTC') == 0", &sample);
    try expect_true("now.getHours(this.zone) == 1 && now.getFullYear('-01:00') == 2023", &sample);
    try expect_true("duration('1h30m').getMinutes() == 90 && duration('3h').getHours() == 3 && duration('1m30s').getSeconds() == 90", &sample);
    try expect_true("duration('1.234s').getMilliseconds() == 1234 && this.wait.getMinutes() == 1", &sample);
    // A zone the module does not read fails the run.
    const named: Message = .{ .zone = "America/Los_Angeles" };
    try testing.expectError(error.Unevaluable, run("now.getHours(this.zone) == 0", &named));
}

test "timestamp and duration read a text as the expression runs" {
    try expect_true("timestamp(this.text) == now && timestamp(now) == now && duration(string(this.wait)) == this.wait", &sample);
    const wrong: Message = .{ .text = "2023-12-25" };
    try testing.expectError(error.Unevaluable, run("timestamp(this.text) == now", &wrong));
    try testing.expectError(error.Unevaluable, run("duration(this.text) == duration('0s')", &wrong));
}

test "string writes a timestamp in RFC 3339 and a duration in seconds" {
    try expect_true("string(this.at) == '2023-12-24T23:59:59.5Z' && string(now) == '2023-12-25T00:00:00Z'", &sample);
    try expect_true("string(timestamp('2023-12-25T01:30:00+01:30')) == '2023-12-25T00:00:00Z'", &sample);
    try expect_true("string(duration('1m1ms')) == '60.001s' && string(this.wait) == '90s' && string(duration('-1.5s')) == '-1.5s'", &sample);
}

test "a timestamp, a zone or an operator the module does not read stops the build" {
    try expect_problem("timestamp('2023-02-30T00:00:00Z') == now", "`2023-02-30T00:00:00Z` is no timestamp of RFC 3339 in the range of CEL's timestamps");
    try expect_problem("now.getHours('Europe/Paris') == 0", "the time zone `Europe/Paris` is no `UTC` and no offset such as `+05:30`, and this module reads no zone names");
    try expect_problem("timestamp(1) == now", "found no matching overload for `timestamp` applied to (int)");
    try expect_problem("now + now", "found no matching overload for `+` applied to (google.protobuf.Timestamp, google.protobuf.Timestamp)");
    try expect_problem("this.wait.getFullYear() == 0", "found no matching overload for `getFullYear` applied to (google.protobuf.Duration)");
}
