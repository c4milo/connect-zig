//! Arithmetic on timestamps and durations, and the parts and the text of a duration (CEL
//! language definition, "Arithmetic Operators", "Date/Time Functions" and "Types and
//! Conversions").
//! cel-go holds a duration as Go's `time.Duration`, a count of nanoseconds in an int64, and
//! checks each sum for overflow. This file computes as it does: "Arithmetic operations raise
//! an error when the results exceed the range of the integer type (int, uint) or the timestamp
//! or duration type" ("Overflow").
const std = @import("std");
const proto = @import("protobuf");
const constants = @import("../constants.zig");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const timestamp_file = @import("cel_timestamp.zig");
const time = @import("cel_time.zig");
const Function = node_file.Function;
const BinaryOp = node_file.BinaryOp;
const Timestamp = proto.wkt.Timestamp;
const Duration = proto.wkt.Duration;
const Error = type_file.Error;
const Text = type_file.Text;

/// The type of `left op right` for a timestamp and a duration, or null: a timestamp plus or
/// minus a duration, a duration plus a timestamp, two durations added or subtracted, and the
/// duration between two timestamps.
pub fn Result(comptime op: BinaryOp, comptime L: type, comptime R: type) ?type {
    return switch (op) {
        .add => Sum(L, R),
        .subtract => Difference(L, R),
        else => null,
    };
}

fn Sum(comptime L: type, comptime R: type) ?type {
    if (L == Duration and R == Duration) return Duration;
    if ((L == Timestamp and R == Duration) or (L == Duration and R == Timestamp)) return Timestamp;
    return null;
}

fn Difference(comptime L: type, comptime R: type) ?type {
    if (L == Timestamp and R == Duration) return Timestamp;
    if ((L == Duration or L == Timestamp) and L == R) return Duration;
    return null;
}

pub fn compute(comptime op: BinaryOp, left: anytype, right: anytype) Error!Result(op, @TypeOf(left), @TypeOf(right)).? {
    const L = @TypeOf(left);
    const R = @TypeOf(right);
    if (comptime L == Duration and R == Duration) {
        const sum = if (op == .add) std.math.add(i64, nanos_of(left), nanos_of(right)) else std.math.sub(i64, nanos_of(left), nanos_of(right));
        return duration_of(sum catch return error.Unevaluable);
    }
    if (comptime L == Timestamp and R == Timestamp) return between(left, right);
    if (comptime L == Duration) return add_to(right, nanos_of(left));
    if (comptime op == .add) return add_to(left, nanos_of(right));
    // cel-go negates the duration, and the least one has no negation.
    const nanos = nanos_of(right);
    if (nanos == std.math.minInt(i64)) return error.Unevaluable;
    return add_to(left, -nanos);
}

/// A duration's nanoseconds, as protobuf-go's `AsDuration` gives cel-go them: a duration past
/// an int64 of nanoseconds is the greatest or the least one.
pub fn nanos_of(duration: Duration) i64 {
    const total = @as(i128, duration.seconds) * constants.nanos_per_second + duration.nanos;
    return std.math.cast(i64, total) orelse if (duration.seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

/// The duration of `nanos`, whose `nanos` has the sign of its seconds.
fn duration_of(nanos: i64) Duration {
    return .{ .seconds = @divTrunc(nanos, constants.nanos_per_second), .nanos = @intCast(@rem(nanos, constants.nanos_per_second)) };
}

/// `timestamp + duration`: a timestamp outside the range of "Overflow" fails.
fn add_to(timestamp: Timestamp, nanos: i64) Error!Timestamp {
    const instant: timestamp_file.Instant = .of(timestamp);
    const total = @as(i128, instant.seconds) * constants.nanos_per_second + instant.nanos + nanos;
    const seconds = @divFloor(total, constants.nanos_per_second);
    if (seconds < constants.timestamp_seconds_min or seconds > constants.timestamp_seconds_max) return error.Unevaluable;
    return .{ .seconds = @intCast(seconds), .nanos = @intCast(@mod(total, constants.nanos_per_second)) };
}

/// `left - right` of two timestamps. cel-go scales the seconds between them to nanoseconds,
/// then adds the nanoseconds between them, and fails when either step leaves an int64.
fn between(left: Timestamp, right: Timestamp) Error!Duration {
    const later: timestamp_file.Instant = .of(left);
    const earlier: timestamp_file.Instant = .of(right);
    const seconds = std.math.sub(i64, later.seconds, earlier.seconds) catch return error.Unevaluable;
    const scaled = std.math.mul(i64, seconds, constants.nanos_per_second) catch return error.Unevaluable;
    return duration_of(std.math.add(i64, scaled, later.nanos - earlier.nanos) catch return error.Unevaluable);
}

const nanos_per_minute = constants.nanos_per_second * constants.seconds_per_minute;
const nanos_per_hour = constants.nanos_per_second * constants.seconds_per_hour;

/// A `get` function of a duration. getHours, getMinutes and getSeconds "convert the duration"
/// to the unit, as cel-go does with Go's `Hours()`, `Minutes()` and `Seconds()`, which it
/// truncates to an int. getMilliseconds gives "the milliseconds portion of the duration value"
/// in the definition, as in `duration("1.234s").getMilliseconds() // 234`. cel-go gives Go's
/// `Milliseconds()`, all of them, and this module follows it (docs/specs/README.md).
pub fn part_of(comptime function: Function, duration: Duration) i64 {
    const nanos = nanos_of(duration);
    return switch (function) {
        .getHours => go_units(nanos, nanos_per_hour),
        .getMinutes => go_units(nanos, nanos_per_minute),
        .getSeconds => go_units(nanos, constants.nanos_per_second),
        .getMilliseconds => @divTrunc(nanos, constants.nanos_per_millisecond),
        else => comptime unreachable,
    };
}

/// Go's `Duration.Hours()` and the like: the whole units as a double, plus the rest as a
/// double's fraction of a unit. The sum may round up to the next unit, as Go's does.
fn go_units(nanos: i64, unit: i64) i64 {
    return @intFromFloat(@trunc(go_float_units(nanos, unit)));
}

fn go_float_units(nanos: i64, unit: i64) f64 {
    const whole: f64 = @floatFromInt(@divTrunc(nanos, unit));
    const rest: f64 = @floatFromInt(@rem(nanos, unit));
    return whole + rest / @as(f64, @floatFromInt(unit));
}

/// `string(duration)`: "seconds and fractional seconds with an 's' suffix", as cel-go writes
/// Go's `Seconds()` with the fewest digits, in fixed form.
pub fn write(duration: Duration, text: *Text) Error!void {
    const written = std.fmt.bufPrint(text.unwritten(), "{d}s", .{go_float_units(nanos_of(duration), constants.nanos_per_second)}) catch return text.overflow();
    text.len += written.len;
}

/// `duration(string)` of a text the build does not know: null for a text that states no
/// duration, which fails the run.
pub fn parse(text: []const u8) ?Duration {
    return time.parse_duration(text);
}

const testing = std.testing;

test "a timestamp and a duration add and subtract, and each sum stays in its range" {
    const christmas: Timestamp = .{ .seconds = 1_703_462_400 };
    const hour: Duration = .{ .seconds = constants.seconds_per_hour };
    const half: Duration = .{ .nanos = 500_000_000 };
    try testing.expectEqual(Timestamp{ .seconds = 1_703_466_000 }, try compute(.add, christmas, hour));
    try testing.expectEqual(Timestamp{ .seconds = 1_703_466_000 }, try compute(.add, hour, christmas));
    try testing.expectEqual(Timestamp{ .seconds = 1_703_462_399, .nanos = 500_000_000 }, try compute(.subtract, christmas, half));
    try testing.expectEqual(Duration{ .seconds = constants.seconds_per_hour }, try compute(.subtract, try compute(.add, christmas, hour), christmas));
    try testing.expectEqual(Duration{ .seconds = -constants.seconds_per_hour }, try compute(.subtract, christmas, try compute(.add, christmas, hour)));
    try testing.expectEqual(Duration{ .seconds = 3_600, .nanos = 500_000_000 }, try compute(.add, hour, half));
    try testing.expectEqual(Duration{ .seconds = 3_599, .nanos = 500_000_000 }, try compute(.subtract, hour, half));
    const last: Timestamp = .{ .seconds = constants.timestamp_seconds_max, .nanos = 999_999_999 };
    try testing.expectError(error.Unevaluable, compute(.add, last, Duration{ .nanos = 1 }));
    const first: Timestamp = .{ .seconds = constants.timestamp_seconds_min };
    try testing.expectError(error.Unevaluable, compute(.subtract, first, Duration{ .nanos = 1 }));
    // The span from the first timestamp to the last is no int64 of nanoseconds.
    try testing.expectError(error.Unevaluable, compute(.subtract, last, first));
    const most: Duration = .{ .seconds = 9_223_372_036, .nanos = 854_775_807 };
    try testing.expectError(error.Unevaluable, compute(.add, most, Duration{ .nanos = 1 }));
    try testing.expect(comptime Result(.add, Timestamp, Timestamp) == null and Result(.multiply, Duration, Duration) == null);
}

test "a duration's parts, as Go's Hours, Minutes and Seconds truncate them" {
    const ninety_minutes: Duration = .{ .seconds = 5_400 };
    try testing.expectEqual(@as(i64, 1), part_of(.getHours, ninety_minutes));
    try testing.expectEqual(@as(i64, 90), part_of(.getMinutes, ninety_minutes));
    try testing.expectEqual(@as(i64, 5_400), part_of(.getSeconds, ninety_minutes));
    const negative: Duration = .{ .seconds = -1, .nanos = -234_000_000 };
    try testing.expectEqual(@as(i64, -1), part_of(.getSeconds, negative));
    try testing.expectEqual(@as(i64, -1_234), part_of(.getMilliseconds, negative));
    try testing.expectEqual(@as(i64, 1_234), part_of(.getMilliseconds, Duration{ .seconds = 1, .nanos = 234_000_000 }));
    try testing.expectEqual(@as(i64, 5_400_000), part_of(.getMilliseconds, ninety_minutes));
    // Go's sum of the whole seconds and the fraction rounds up to the next second here.
    try testing.expectEqual(@as(i64, 9_223_372_036), part_of(.getSeconds, Duration{ .seconds = 9_223_372_035, .nanos = 999_999_999 }));
    // A duration past an int64 of nanoseconds is the greatest or the least one, as protobuf-go
    // gives cel-go.
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), nanos_of(.{ .seconds = 315_576_000_000 }));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), nanos_of(.{ .seconds = -315_576_000_000 }));
}

test "string of a duration is its seconds, with the fewest digits, and an s" {
    var room: [constants.decimal_base * 4]u8 = undefined;
    inline for (.{
        .{ Duration{ .seconds = 60, .nanos = 1_000_000 }, "60.001s" },
        .{ Duration{ .seconds = 90 }, "90s" },
        .{ Duration{ .seconds = -3 }, "-3s" },
        .{ Duration{ .nanos = 1 }, "0.000000001s" },
        .{ Duration{}, "0s" },
    }) |case| {
        var text: Text = .{ .room = &room };
        try write(case[0], &text);
        try testing.expectEqualStrings(case[1], room[0..text.len]);
    }
}
