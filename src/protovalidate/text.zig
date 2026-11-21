//! A rule's value as its message states it, built at comptime: what CEL's `format` writes for
//! `%s` in validate.proto's messages, such as "must be greater than 5" (decision 47).
const std = @import("std");
const proto = @import("protobuf");
const constants = @import("constants.zig");

/// The text of one rule value: a number in decimal, a string as it is, a duration in seconds
/// with an "s", a timestamp in RFC 3339 and a list between brackets.
pub fn of(comptime value: anytype) []const u8 {
    comptime {
        @setEvalBranchQuota(constants.eval_branches_per_rule);
        const V = @TypeOf(value);
        if (V == proto.wkt.Duration) return duration(value);
        if (V == proto.wkt.Timestamp) return timestamp(value);
        return switch (@typeInfo(V)) {
            .bool => if (value) "true" else "false",
            .int, .comptime_int => std.fmt.comptimePrint("{d}", .{value}),
            .float, .comptime_float => float(value),
            .@"enum" => std.fmt.comptimePrint("{d}", .{@intFromEnum(value)}),
            .pointer => value,
            else => @compileError("no text for " ++ @typeName(V)),
        };
    }
}

fn float(comptime value: anytype) []const u8 {
    if (std.math.isNan(value)) return "NaN";
    if (std.math.isInf(value)) return if (value > 0) "Infinity" else "-Infinity";
    return std.fmt.comptimePrint("{d}", .{value});
}

/// A timestamp in RFC 3339, in UTC: "1970-01-01T00:00:07Z", and "1970-01-01T00:00:00.001Z" for
/// a fraction of a second.
fn timestamp(comptime value: proto.wkt.Timestamp) []const u8 {
    const seconds_per_minute = 60;
    const seconds_per_hour = 3600;
    const seconds_per_day = 86_400;
    const day = @divFloor(value.seconds, seconds_per_day);
    const second_of_day = @mod(value.seconds, seconds_per_day);
    const date = date_of(day);
    const clock = std.fmt.comptimePrint("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(date.year)),                                  @as(u64, @intCast(date.month)),                                                           @as(u64, @intCast(date.day)),
        @as(u64, @intCast(@divFloor(second_of_day, seconds_per_hour))), @as(u64, @intCast(@divFloor(@mod(second_of_day, seconds_per_hour), seconds_per_minute))), @as(u64, @intCast(@mod(second_of_day, seconds_per_minute))),
    });
    if (value.nanos == 0) return clock ++ "Z";
    var digits: []const u8 = std.fmt.comptimePrint("{d:0>9}", .{@as(u64, @intCast(value.nanos))});
    while (digits[digits.len - 1] == '0') digits = digits[0 .. digits.len - 1];
    return clock ++ "." ++ digits ++ "Z";
}

const Date = struct { year: i64, month: i64, day: i64 };

/// The Gregorian date of a day counted from 1970-01-01. The calendar repeats every 400 years,
/// which are 146,097 days. The count runs over years that start on March 1, so a leap day is
/// the last day of its year, and the months before March belong to the year after.
fn date_of(comptime day: i64) Date {
    const days_per_cycle = 146_097;
    const years_per_cycle = 400;
    const days_per_year = 365;
    const days_per_4_years = 1460;
    const days_per_century = 36_524;
    // The days from 0000-03-01 to 1970-01-01.
    const epoch_day = 719_468;
    // The days of the five months from March to July, which the months after repeat.
    const days_per_5_months = 153;
    const months_per_group = 5;
    // Half a group of months, rounded down, which turns a day into the month that holds it.
    const month_rounding = 2;
    const months_per_year = 12;
    const march = 3;
    const years_per_leap = 4;
    const years_per_century = 100;
    const shifted = day + epoch_day;
    const cycle = @divFloor(shifted, days_per_cycle);
    const day_of_cycle = shifted - cycle * days_per_cycle;
    const year_of_cycle = @divFloor(day_of_cycle - @divFloor(day_of_cycle, days_per_4_years) + @divFloor(day_of_cycle, days_per_century) - @divFloor(day_of_cycle, days_per_cycle - 1), days_per_year);
    const day_of_year = day_of_cycle - (days_per_year * year_of_cycle + @divFloor(year_of_cycle, years_per_leap) - @divFloor(year_of_cycle, years_per_century));
    const month_from_march = @divFloor(months_per_group * day_of_year + month_rounding, days_per_5_months);
    const month = if (month_from_march + march > months_per_year) month_from_march + march - months_per_year else month_from_march + march;
    return .{
        .year = year_of_cycle + cycle * years_per_cycle + (if (month < march) 1 else 0),
        .month = month,
        .day = day_of_year - @divFloor(days_per_5_months * month_from_march + month_rounding, months_per_group) + 1,
    };
}

/// A duration in seconds: "3600s", "0.001s".
fn duration(comptime value: proto.wkt.Duration) []const u8 {
    const negative = value.seconds < 0 or value.nanos < 0;
    const whole = @abs(value.seconds);
    const fraction = @abs(value.nanos);
    if (fraction == 0) return std.fmt.comptimePrint("{s}{d}s", .{ if (negative) "-" else "", whole });
    var digits: []const u8 = std.fmt.comptimePrint("{d:0>9}", .{fraction % constants.nanos_per_second});
    while (digits[digits.len - 1] == '0') digits = digits[0 .. digits.len - 1];
    return std.fmt.comptimePrint("{s}{d}.{s}s", .{ if (negative) "-" else "", whole, digits });
}

/// Octets as CEL's `%x` writes them: two lowercase hexadecimal digits each.
pub fn hex(comptime octets: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(constants.eval_branches_per_rule * (octets.len + 1));
        var digits: []const u8 = "";
        for (octets) |octet| digits = digits ++ std.fmt.comptimePrint("{x:0>2}", .{octet});
        return digits;
    }
}

/// A list of byte strings, each in hexadecimal.
pub fn hex_list(comptime items: []const []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(constants.eval_branches_per_rule * (items.len + 1));
        var joined: []const u8 = "[";
        for (items, 0..) |item, index| joined = joined ++ (if (index == 0) "" else ", ") ++ hex(item);
        return joined ++ "]";
    }
}

/// A list as CEL writes one: "[1, 2, 3]".
pub fn list(comptime items: anytype) []const u8 {
    comptime {
        @setEvalBranchQuota(constants.eval_branches_per_rule * (items.len + 1));
        var joined: []const u8 = "[";
        for (items, 0..) |item, index| joined = joined ++ (if (index == 0) "" else ", ") ++ of(item);
        return joined ++ "]";
    }
}

const testing = std.testing;

test "a rule's value reads as validate.proto's messages state it" {
    try testing.expectEqualStrings("-5", comptime of(@as(i32, -5)));
    try testing.expectEqualStrings("18446744073709551615", comptime of(@as(u64, std.math.maxInt(u64))));
    try testing.expectEqualStrings("0.5", comptime of(@as(f32, 0.5)));
    try testing.expectEqualStrings("16", comptime of(@as(f64, 16)));
    try testing.expectEqualStrings("NaN", comptime of(std.math.nan(f64)));
    try testing.expectEqualStrings("-Infinity", comptime of(-std.math.inf(f32)));
    try testing.expectEqualStrings("true", comptime of(true));
    try testing.expectEqualStrings("abc", comptime of(@as([]const u8, "abc")));
    try testing.expectEqualStrings("3600s", comptime of(proto.wkt.Duration{ .seconds = 3600 }));
    try testing.expectEqualStrings("0.001s", comptime of(proto.wkt.Duration{ .nanos = 1_000_000 }));
    try testing.expectEqualStrings("-1.5s", comptime of(proto.wkt.Duration{ .seconds = -1, .nanos = -500_000_000 }));
    try testing.expectEqualStrings("1970-01-01T00:00:07Z", comptime of(proto.wkt.Timestamp{ .seconds = 7 }));
    try testing.expectEqualStrings("1970-01-01T00:00:00.001Z", comptime of(proto.wkt.Timestamp{ .nanos = 1_000_000 }));
    try testing.expectEqualStrings("2009-02-13T23:31:30Z", comptime of(proto.wkt.Timestamp{ .seconds = 1_234_567_890 }));
    // A leap day, the day after it, the last second of a year and a time before the epoch.
    try testing.expectEqualStrings("2024-02-29T12:00:00Z", comptime of(proto.wkt.Timestamp{ .seconds = 1_709_208_000 }));
    try testing.expectEqualStrings("2024-03-01T00:00:00Z", comptime of(proto.wkt.Timestamp{ .seconds = 1_709_251_200 }));
    try testing.expectEqualStrings("1999-12-31T23:59:59Z", comptime of(proto.wkt.Timestamp{ .seconds = 946_684_799 }));
    try testing.expectEqualStrings("2000-01-01T00:00:00Z", comptime of(proto.wkt.Timestamp{ .seconds = 946_684_800 }));
    try testing.expectEqualStrings("1969-12-31T23:59:59.5Z", comptime of(proto.wkt.Timestamp{ .seconds = -1, .nanos = 500_000_000 }));
    try testing.expectEqualStrings("1900-03-01T00:00:00Z", comptime of(proto.wkt.Timestamp{ .seconds = -2_203_891_200 }));
    try testing.expectEqualStrings("[1, 2, 3]", comptime list(&[_]i32{ 1, 2, 3 }));
    try testing.expectEqualStrings("[]", comptime list(&[_]i32{}));
    try testing.expectEqualStrings("00ff62", comptime hex("\x00\xffb"));
    try testing.expectEqualStrings("[61, 6263]", comptime hex_list(&.{ "a", "bc" }));
}
