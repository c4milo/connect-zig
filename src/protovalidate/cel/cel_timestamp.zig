//! CEL's timestamps beyond comparison (CEL language definition, "Types and Conversions",
//! "Timezones" and "Date/Time Functions"): the RFC 3339 text that `timestamp(string)`
//! reads and `string(timestamp)` writes, a time zone, and the parts of a date. cel-go reads a
//! timestamp's text with Go's `time.Parse(time.RFC3339, ...)`, and this file reads it as that
//! does (docs/specs/README.md).
const std = @import("std");
const proto = @import("protobuf");
const constants = @import("../constants.zig");
const type_file = @import("cel_type.zig");
const Function = @import("cel_node.zig").Function;
const Timestamp = proto.wkt.Timestamp;
const Error = type_file.Error;
const Text = type_file.Text;

/// A date of the proleptic Gregorian calendar. `month` counts from 1 for January.
pub const Date = struct { year: i64, month: i64, day: i64 };

// Howard Hinnant's `days_from_civil` and `civil_from_days`, over years that start on March 1,
// so that a leap day is the last day of its year.

/// The days of 400 years, after which the calendar repeats.
const days_per_era = 146_097;
const years_per_era = 400;
/// The days of 100 years and of 4 years that hold no leap day.
const days_per_century = 36_524;
const days_per_four_years = 1_460;
const days_per_year = 365;
/// A year divisible by 4 holds a leap day, and a year divisible by 100 does not, unless it is
/// divisible by 400.
const years_per_leap = 4;
const years_per_century = 100;
/// The days from 0000-03-01 to 1970-01-01.
const days_to_unix_epoch = 719_468;
/// Counted from March, a month's first day falls `(153 * month + 2) / 5` days into the year:
/// five months, March to July, take 153 days.
const days_per_five_months = 153;
const months_per_five = 5;
const month_day_shift = 2;
/// January and February are the last two months of a year that starts on March 1.
const months_before_march = 2;
const march = 3;
/// January is month 10 of a year that starts on March 1, and month 1 of a calendar year.
const months_from_january_to_march = 9;
const months_from_march_to_january = 10;
pub const months_per_year = 12;

/// The days from 1970-01-01 to `date`.
pub fn days_of(date: Date) i64 {
    const year = if (date.month <= months_before_march) date.year - 1 else date.year;
    const era = @divFloor(year, years_per_era);
    const year_of_era = year - era * years_per_era;
    const month_from_march = if (date.month > months_before_march) date.month - march else date.month + months_from_january_to_march;
    const day_of_year = @divTrunc(days_per_five_months * month_from_march + month_day_shift, months_per_five) + date.day - 1;
    const day_of_era = year_of_era * days_per_year + @divTrunc(year_of_era, years_per_leap) - @divTrunc(year_of_era, years_per_century) + day_of_year;
    return era * days_per_era + day_of_era - days_to_unix_epoch;
}

/// The date `days` after 1970-01-01.
pub fn date_of(days: i64) Date {
    const shifted = days + days_to_unix_epoch;
    const era = @divFloor(shifted, days_per_era);
    const day_of_era = shifted - era * days_per_era;
    const leap_days = @divTrunc(day_of_era, days_per_four_years) - @divTrunc(day_of_era, days_per_century) + @divTrunc(day_of_era, days_per_era - 1);
    const year_of_era = @divTrunc(day_of_era - leap_days, days_per_year);
    const day_of_year = day_of_era - (days_per_year * year_of_era + @divTrunc(year_of_era, years_per_leap) - @divTrunc(year_of_era, years_per_century));
    const month_from_march = @divTrunc(months_per_five * day_of_year + month_day_shift, days_per_five_months);
    const day = day_of_year - @divTrunc(days_per_five_months * month_from_march + month_day_shift, months_per_five) + 1;
    const month = if (month_from_march < months_from_march_to_january) month_from_march + march else month_from_march - months_from_january_to_march;
    const year = year_of_era + era * years_per_era;
    return .{ .year = if (month <= months_before_march) year + 1 else year, .month = month, .day = day };
}

/// The days of `month` of `year`.
fn days_in_month(year: i64, month: i64) i64 {
    const next: Date = if (month == months_per_year) .{ .year = year + 1, .month = 1, .day = 1 } else .{ .year = year, .month = month + 1, .day = 1 };
    return days_of(next) - days_of(.{ .year = year, .month = month, .day = 1 });
}

const seconds_per_day = constants.seconds_per_hour * hours_per_day;
const hours_per_day = 24;
const minutes_per_hour = constants.seconds_per_hour / constants.seconds_per_minute;
/// The greatest year of a timestamp's text, which RFC 3339 writes in four digits.
const year_max = 9999;

/// A timestamp's seconds and nanoseconds, with the nanoseconds in [0, 1e9) as Go's time keeps
/// them. A message's timestamp may hold nanoseconds outside, which carry into the seconds.
pub const Instant = struct {
    seconds: i64,
    nanos: i64,

    pub fn of(timestamp: Timestamp) Instant {
        const total = @as(i128, timestamp.seconds) * constants.nanos_per_second + timestamp.nanos;
        return .{ .seconds = @intCast(@divFloor(total, constants.nanos_per_second)), .nanos = @intCast(@mod(total, constants.nanos_per_second)) };
    }
};

/// The timestamp a text of RFC 3339 names, as Go's `time.Parse(time.RFC3339, ...)` reads it:
/// a date and a time, a fraction of a second of any length, of which the first nine digits
/// count, and `Z` or an offset such as `-07:00`. Null for any other text, and for a time
/// outside the range CEL language definition, "Overflow", gives timestamps.
pub fn parse(text: []const u8) ?Timestamp {
    var reader: Reader = .{ .rest = text };
    const date = reader.date() orelse return null;
    if (!reader.take('T')) return null;
    const hour = reader.number("15".len, hours_per_day - 1) orelse return null;
    if (!reader.take(':')) return null;
    const minute = reader.number("04".len, minutes_per_hour - 1) orelse return null;
    if (!reader.take(':')) return null;
    const second = reader.number("05".len, constants.seconds_per_minute - 1) orelse return null;
    const nanos = reader.fraction();
    const offset = reader.offset() orelse return null;
    const seconds = days_of(date) * seconds_per_day + (hour * minutes_per_hour + minute) * constants.seconds_per_minute + second - offset;
    if (seconds < constants.timestamp_seconds_min or seconds > constants.timestamp_seconds_max) return null;
    return .{ .seconds = seconds, .nanos = @intCast(nanos) };
}

/// Reads the parts of a timestamp's text in order, each with its range.
const Reader = struct {
    rest: []const u8,

    fn take(reader: *Reader, octet: u8) bool {
        if (reader.rest.len == 0 or reader.rest[0] != octet) return false;
        reader.rest = reader.rest[1..];
        return true;
    }

    /// A number of `len` digits in [0, `max`].
    fn number(reader: *Reader, len: usize, max: i64) ?i64 {
        if (reader.rest.len < len) return null;
        var value: i64 = 0;
        for (reader.rest[0..len]) |digit| {
            if (!std.ascii.isDigit(digit)) return null;
            value = value * constants.decimal_base + (digit - '0');
        }
        if (value > max) return null;
        reader.rest = reader.rest[len..];
        return value;
    }

    /// `2006-01-02`: a year, a month and a day that the month holds.
    fn date(reader: *Reader) ?Date {
        const year = reader.number("2006".len, year_max) orelse return null;
        if (!reader.take('-')) return null;
        const month = reader.number("01".len, months_per_year) orelse return null;
        if (month == 0 or !reader.take('-')) return null;
        const day = reader.number("02".len, days_in_month(year, month)) orelse return null;
        if (day == 0) return null;
        return .{ .year = year, .month = month, .day = day };
    }

    /// The nanoseconds of a fraction of a second, or 0 when none follows.
    fn fraction(reader: *Reader) i64 {
        if (reader.rest.len < ".0".len or reader.rest[0] != '.' or !std.ascii.isDigit(reader.rest[1])) return 0;
        reader.rest = reader.rest[1..];
        var nanos: i64 = 0;
        var scale: i64 = constants.nanos_per_second;
        for (0..reader.rest.len) |_| {
            if (reader.rest.len == 0 or !std.ascii.isDigit(reader.rest[0])) break;
            scale = @divTrunc(scale, constants.decimal_base);
            nanos += scale * (reader.rest[0] - '0');
            reader.rest = reader.rest[1..];
        }
        return nanos;
    }

    /// The seconds east of UTC of `Z` or `+07:00`, which end the text.
    fn offset(reader: *Reader) ?i64 {
        if (std.mem.eql(u8, reader.rest, "Z")) return 0;
        if (reader.rest.len != "-07:00".len) return null;
        const negative = reader.rest[0] == '-';
        if (!negative and reader.rest[0] != '+') return null;
        reader.rest = reader.rest[1..];
        const hours = reader.number("07".len, hours_per_day - 1) orelse return null;
        if (!reader.take(':')) return null;
        const minutes = reader.number("00".len, minutes_per_hour - 1) orelse return null;
        const seconds = (hours * minutes_per_hour + minutes) * constants.seconds_per_minute;
        return if (negative) -seconds else seconds;
    }
};

/// The digits of a timestamp's nanoseconds that RFC 3339 writes, before the zeros that end
/// them are dropped.
const fraction_digits = 9;

/// `string(timestamp)`: RFC 3339 in UTC, as Go's `Format(time.RFC3339Nano)` writes it. The
/// fraction drops the zeros that end it, and a whole second has none.
pub fn write(timestamp: Timestamp, text: *Text) Error!void {
    const instant: Instant = .of(timestamp);
    const days = @divFloor(instant.seconds, seconds_per_day);
    const second_of_day = @mod(instant.seconds, seconds_per_day);
    const date = date_of(days);
    if (date.year < 0) try text.write("-");
    try print(text, "{d:0>4}-{d:0>2}-{d:0>2}T", .{ @abs(date.year), @as(u64, @intCast(date.month)), @as(u64, @intCast(date.day)) });
    const minute_of_day = @divTrunc(second_of_day, constants.seconds_per_minute);
    try print(text, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(@divTrunc(minute_of_day, minutes_per_hour))),
        @as(u64, @intCast(@mod(minute_of_day, minutes_per_hour))),
        @as(u64, @intCast(@mod(second_of_day, constants.seconds_per_minute))),
    });
    if (instant.nanos != 0) {
        var digits: [fraction_digits]u8 = undefined;
        _ = std.fmt.bufPrint(&digits, "{d:0>9}", .{@as(u64, @intCast(instant.nanos))}) catch unreachable;
        try text.write(".");
        try text.write(std.mem.trimEnd(u8, &digits, "0"));
    }
    try text.write("Z");
}

fn print(text: *Text, comptime pattern: []const u8, values: anytype) Error!void {
    const written = std.fmt.bufPrint(text.unwritten(), pattern, values) catch return text.overflow();
    text.len += written.len;
}

/// The seconds east of UTC of a time zone's text, as cel-go reads it, or null for a text this
/// module does not read (CEL language definition, "Timezones"). A text with a colon is hours
/// from -23 to 23, then minutes from 0 to 59, each an int as Go's `strconv.Atoi` reads it, and
/// a `-` before the hours subtracts the minutes too. A text with none is a zone's name, of
/// which the module reads "UTC" and the empty name alone: any other name needs the IANA time
/// zone database, which a library that reads no file does not hold (docs/specs/README.md).
pub fn offset_of_zone(zone: []const u8) ?i64 {
    const colon = std.mem.indexOfScalar(u8, zone, ':') orelse {
        if (zone.len == 0 or std.mem.eql(u8, zone, "UTC")) return 0;
        return null;
    };
    const hours = go_atoi(zone[0..colon]) orelse return null;
    const minutes = go_atoi(zone[colon + 1 ..]) orelse return null;
    if (@abs(hours) >= hours_per_day or minutes < 0 or minutes >= minutes_per_hour) return null;
    const hour_minutes = std.math.mul(i64, hours, minutes_per_hour) catch return null;
    const total = (if (zone[0] == '-') std.math.sub(i64, hour_minutes, minutes) else std.math.add(i64, hour_minutes, minutes)) catch return null;
    return std.math.mul(i64, total, constants.seconds_per_minute) catch null;
}

/// Go's `strconv.Atoi`: an optional sign, then one or more decimal digits.
fn go_atoi(text: []const u8) ?i64 {
    const digits = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) text[1..] else text;
    if (digits.len == 0) return null;
    for (digits) |digit| {
        if (!std.ascii.isDigit(digit)) return null;
    }
    return std.fmt.parseInt(i64, text, constants.decimal_base) catch null;
}

/// The day of the week of 1970-01-01, a Thursday, with Sunday as 0 (CEL language definition,
/// "Date/Time Functions").
const thursday = 4;
const days_per_week = 7;

/// A `get` function of a timestamp in the zone `offset` seconds east of UTC.
pub fn part_of(comptime function: Function, timestamp: Timestamp, offset: i64) i64 {
    const instant: Instant = .of(timestamp);
    const local = instant.seconds + offset;
    const days = @divFloor(local, seconds_per_day);
    const second_of_day = @mod(local, seconds_per_day);
    return switch (function) {
        .getFullYear => date_of(days).year,
        // "zero-based, 0 for January"
        .getMonth => date_of(days).month - 1,
        // "one-based indexing", and getDayOfMonth's "zero-based indexing"
        .getDate => date_of(days).day,
        .getDayOfMonth => date_of(days).day - 1,
        .getDayOfYear => days - days_of(.{ .year = date_of(days).year, .month = 1, .day = 1 }),
        .getDayOfWeek => @mod(days + thursday, days_per_week),
        .getHours => @divTrunc(second_of_day, constants.seconds_per_hour),
        .getMinutes => @mod(@divTrunc(second_of_day, constants.seconds_per_minute), minutes_per_hour),
        .getSeconds => @mod(second_of_day, constants.seconds_per_minute),
        .getMilliseconds => @divTrunc(instant.nanos, constants.nanos_per_millisecond),
        else => comptime unreachable,
    };
}

const testing = std.testing;

test "a day count and a date stand for each other, across leap days and eras" {
    try testing.expectEqual(@as(i64, 0), days_of(.{ .year = 1970, .month = 1, .day = 1 }));
    try testing.expectEqual(Date{ .year = 2000, .month = 2, .day = 29 }, date_of(days_of(.{ .year = 2000, .month = 2, .day = 29 })));
    try testing.expectEqual(Date{ .year = 1900, .month = 3, .day = 1 }, date_of(days_of(.{ .year = 1900, .month = 2, .day = 28 }) + 1));
    try testing.expectEqual(Date{ .year = 1, .month = 1, .day = 1 }, date_of(@divFloor(constants.timestamp_seconds_min, seconds_per_day)));
    try testing.expectEqual(Date{ .year = 9999, .month = 12, .day = 31 }, date_of(@divFloor(constants.timestamp_seconds_max, seconds_per_day)));
    try testing.expectEqual(@as(i64, 29), days_in_month(2024, 2));
    try testing.expectEqual(@as(i64, 28), days_in_month(2100, 2));
    try testing.expectEqual(@as(i64, 31), days_in_month(2023, 12));
}

fn expect_parse(text: []const u8, seconds: i64, nanos: i32) !void {
    const timestamp = parse(text) orelse return error.TestExpectedTimestamp;
    try testing.expectEqual(seconds, timestamp.seconds);
    try testing.expectEqual(nanos, timestamp.nanos);
}

test "a timestamp's text is RFC 3339, as Go reads it" {
    const christmas = 1_703_462_400;
    try expect_parse("2023-12-25T00:00:00Z", christmas, 0);
    try expect_parse("2023-12-25T01:30:00+01:30", christmas, 0);
    try expect_parse("2023-12-24T16:00:00-08:00", christmas, 0);
    try expect_parse("2023-12-25T00:00:00.5Z", christmas, 500_000_000);
    try expect_parse("2023-12-25T00:00:00.1234567891Z", christmas, 123_456_789);
    try expect_parse("0001-01-01T00:00:00Z", constants.timestamp_seconds_min, 0);
    try expect_parse("9999-12-31T23:59:59.999999999Z", constants.timestamp_seconds_max, 999_999_999);
    for ([_][]const u8{
        "",                         "2023-12-25",            "2023-12-25T00:00:00",  "2023-12-25t00:00:00Z",
        "2023-12-25T00:00:00z",     "2023-02-29T00:00:00Z",  "2023-13-01T00:00:00Z", "2023-00-01T00:00:00Z",
        "2023-12-25T24:00:00Z",     "2023-12-25T00:60:00Z",  "2023-12-25T00:00:60Z", "2023-12-25T00:00:00+24:00",
        "2023-12-25T00:00:00+0100", "2023-12-25 00:00:00Z",  "0000-12-31T00:00:00Z", "0001-01-01T00:00:00+00:01",
        "2023-12-25T00:00:00.Z",    "+2023-12-25T00:00:00Z",
    }) |text| try testing.expect(parse(text) == null);
}

/// The longest text of a timestamp: its date and time, nine digits of fraction and a `Z`.
const date_time_text_len_max = "2006-01-02T15:04:05.999999999Z".len;

fn expect_written(timestamp: Timestamp, expected: []const u8) !void {
    var room: [date_time_text_len_max]u8 = undefined;
    var text: Text = .{ .room = &room };
    try write(timestamp, &text);
    try testing.expectEqualStrings(expected, room[0..text.len]);
}

test "string of a timestamp is RFC 3339 in UTC, its fraction with no zero at the end" {
    const christmas = 1_703_462_400;
    try expect_written(.{ .seconds = christmas }, "2023-12-25T00:00:00Z");
    try expect_written(.{ .seconds = christmas, .nanos = 500_000_000 }, "2023-12-25T00:00:00.5Z");
    try expect_written(.{ .seconds = christmas, .nanos = 1 }, "2023-12-25T00:00:00.000000001Z");
    try expect_written(.{ .seconds = constants.timestamp_seconds_min }, "0001-01-01T00:00:00Z");
    try expect_written(.{ .seconds = -1 }, "1969-12-31T23:59:59Z");
}

test "a zone is UTC, an offset, or a name the module does not read" {
    try testing.expectEqual(@as(?i64, 0), offset_of_zone("UTC"));
    try testing.expectEqual(@as(?i64, 0), offset_of_zone(""));
    try testing.expectEqual(@as(?i64, 19_800), offset_of_zone("+05:30"));
    try testing.expectEqual(@as(?i64, -19_800), offset_of_zone("-05:30"));
    try testing.expectEqual(@as(?i64, -1_800), offset_of_zone("-00:30"));
    try testing.expectEqual(@as(?i64, 18_000), offset_of_zone("5:00"));
    try testing.expectEqual(@as(?i64, 86_340), offset_of_zone("+23:59"));
    try testing.expectEqual(@as(?i64, 19_800), offset_of_zone("05:+30"));
    for ([_][]const u8{ "America/Los_Angeles", "utc", "+05", ":30", "+05:", "a:00", "+05:3x", "24:00", "-24:00", "05:60", "05:-30" }) |zone| {
        try testing.expect(offset_of_zone(zone) == null);
    }
}

test "the parts of a timestamp in UTC and in a zone" {
    // 2023-12-25T12:30:45.678Z, a Monday, day 358 of its year.
    const noon: Timestamp = .{ .seconds = 1_703_507_445, .nanos = 678_000_000 };
    try testing.expectEqual(@as(i64, 2023), part_of(.getFullYear, noon, 0));
    try testing.expectEqual(@as(i64, 11), part_of(.getMonth, noon, 0));
    try testing.expectEqual(@as(i64, 25), part_of(.getDate, noon, 0));
    try testing.expectEqual(@as(i64, 24), part_of(.getDayOfMonth, noon, 0));
    try testing.expectEqual(@as(i64, 358), part_of(.getDayOfYear, noon, 0));
    try testing.expectEqual(@as(i64, 1), part_of(.getDayOfWeek, noon, 0));
    try testing.expectEqual(@as(i64, 12), part_of(.getHours, noon, 0));
    try testing.expectEqual(@as(i64, 30), part_of(.getMinutes, noon, 0));
    try testing.expectEqual(@as(i64, 45), part_of(.getSeconds, noon, 0));
    try testing.expectEqual(@as(i64, 678), part_of(.getMilliseconds, noon, 0));
    // Thirteen hours west of UTC is the day before.
    const west = -13 * constants.seconds_per_hour;
    try testing.expectEqual(@as(i64, 24), part_of(.getDate, noon, west));
    try testing.expectEqual(@as(i64, 0), part_of(.getDayOfWeek, noon, west));
    try testing.expectEqual(@as(i64, 23), part_of(.getHours, noon, west));
    try testing.expectEqual(@as(i64, 2024), part_of(.getFullYear, .{ .seconds = 1_704_067_199 }, 1));
}
