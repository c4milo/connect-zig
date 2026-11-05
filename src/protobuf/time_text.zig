//! The JSON text of google.protobuf.Timestamp and Duration (proto3 JSON mapping, "JSON Mapping"
//! table, and the comments of timestamp.proto and duration.proto).
//!
//! - A Timestamp is RFC 3339 text, "1972-01-01T10:00:20.021Z": UTC, with 0, 3, 6 or 9 fraction
//!   digits written, and any offset accepted on input. Its range is 0001-01-01T00:00:00Z to
//!   9999-12-31T23:59:59.999999999Z.
//! - A Duration is seconds with an "s" suffix, "1.000340012s", with 0, 3, 6 or 9 fraction
//!   digits written. Its range is about ±10,000 years: ±315,576,000,000 seconds.
const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{ InvalidTimestamp, InvalidDuration, NoSpaceLeft };

pub const Instant = struct { seconds: i64, nanos: i32 };

/// timestamp.proto: seconds of 0001-01-01T00:00:00Z and of 9999-12-31T23:59:59Z.
pub const timestamp_seconds_min: i64 = -62_135_596_800;
pub const timestamp_seconds_max: i64 = 253_402_300_799;
/// duration.proto: the seconds of 10,000 years, either way.
pub const duration_seconds_max: i64 = 315_576_000_000;
const nanos_per_second = 1_000_000_000;
const seconds_per_day = 86_400;
/// The longest text either form takes: "-315576000000.000000000s" and a Timestamp's 30 octets.
pub const text_len_max = 32;

/// Days from 1970-01-01 to the civil date, proleptic Gregorian.
fn days_from_civil(year: i64, month: u32, day: u32) i64 {
    const shifted_year = if (month <= 2) year - 1 else year;
    const era = @divFloor(shifted_year, 400);
    const year_of_era = shifted_year - era * 400;
    const month_index: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * month_index + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

const Civil = struct { year: i64, month: u32, day: u32 };

fn civil_from_days(days: i64) Civil {
    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    const day: u32 = @intCast(day_of_year - @divFloor(153 * month_index + 2, 5) + 1);
    const month: u32 = @intCast(if (month_index < 10) month_index + 3 else month_index - 9);
    const year = year_of_era + era * 400 + @intFromBool(month <= 2);
    return .{ .year = year, .month = month, .day = day };
}

/// The fraction digits the mapping writes: none, or 3, 6 or 9, the fewest that hold `nanos`.
fn write_fraction(nanos: u32, buffer: []u8) []const u8 {
    if (nanos == 0) return buffer[0..0];
    var digits = std.fmt.bufPrint(buffer, ".{d:0>9}", .{nanos}) catch unreachable;
    if (nanos % 1_000_000 == 0) return digits[0..4];
    if (nanos % 1_000 == 0) return digits[0..7];
    return digits;
}

pub fn format_timestamp(instant: Instant, buffer: []u8) Error![]const u8 {
    if (instant.seconds < timestamp_seconds_min or instant.seconds > timestamp_seconds_max) return error.InvalidTimestamp;
    if (instant.nanos < 0 or instant.nanos >= nanos_per_second) return error.InvalidTimestamp;
    const days = @divFloor(instant.seconds, seconds_per_day);
    const second_of_day: u64 = @intCast(instant.seconds - days * seconds_per_day);
    const civil = civil_from_days(days);
    var fraction: [10]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}Z", .{
        @as(u64, @intCast(civil.year)),                     civil.month,             civil.day,
        second_of_day / 3600,                               second_of_day / 60 % 60, second_of_day % 60,
        write_fraction(@intCast(instant.nanos), &fraction),
    }) catch error.NoSpaceLeft;
}

pub fn format_duration(instant: Instant, buffer: []u8) Error![]const u8 {
    try check_duration(instant);
    const negative = instant.seconds < 0 or instant.nanos < 0;
    var fraction: [10]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s}{d}{s}s", .{
        if (negative) "-" else "",
        @abs(instant.seconds),
        write_fraction(@abs(instant.nanos), &fraction),
    }) catch error.NoSpaceLeft;
}

fn check_duration(instant: Instant) Error!void {
    // duration.proto: seconds within ±315,576,000,000, nanos within ±999,999,999, the same sign.
    if (@abs(instant.seconds) > duration_seconds_max) return error.InvalidDuration;
    if (@abs(instant.nanos) >= nanos_per_second) return error.InvalidDuration;
    if ((instant.seconds < 0 and instant.nanos > 0) or (instant.seconds > 0 and instant.nanos < 0)) return error.InvalidDuration;
}

fn digits_value(text: []const u8) ?u32 {
    var value: u32 = 0;
    for (text) |octet| {
        if (octet < '0' or octet > '9') return null;
        value = value * 10 + (octet - '0');
    }
    return value;
}

/// Reads a fraction of 1 to 9 digits after the dot at `text[0]`, as nanoseconds, and its length.
fn read_fraction(text: []const u8) ?struct { nanos: u32, len: usize } {
    if (text.len == 0 or text[0] != '.') return .{ .nanos = 0, .len = 0 };
    var end: usize = 1;
    // At most 9 digits follow the dot.
    for (text[1..@min(text.len, 10)]) |octet| {
        if (octet < '0' or octet > '9') break;
        end += 1;
    }
    if (end == 1) return null;
    var nanos = digits_value(text[1..end]) orelse return null;
    for (end..10) |_| nanos *= 10;
    return .{ .nanos = nanos, .len = end };
}

fn field_value(text: []const u8, start: usize, len: usize) Error!u32 {
    if (start + len > text.len) return error.InvalidTimestamp;
    return digits_value(text[start..][0..len]) orelse error.InvalidTimestamp;
}

/// Reads RFC 3339 text: "YYYY-MM-DDTHH:MM:SS", a fraction, and "Z" or an offset "+HH:MM".
pub fn parse_timestamp(text: []const u8) Error!Instant {
    // RFC 3339 §5.6: the date and time are separated by "T", and the octets are fixed.
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or text[13] != ':' or text[16] != ':') return error.InvalidTimestamp;
    if (text[10] != 'T' and text[10] != 't') return error.InvalidTimestamp;
    const year = try field_value(text, 0, 4);
    const month = try field_value(text, 5, 2);
    const day = try field_value(text, 8, 2);
    const hour = try field_value(text, 11, 2);
    const minute = try field_value(text, 14, 2);
    const second = try field_value(text, 17, 2);
    if (month < 1 or month > 12 or day < 1 or day > days_in_month(year, month)) return error.InvalidTimestamp;
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    const fraction = read_fraction(text[19..]) orelse return error.InvalidTimestamp;
    const offset = try parse_offset(text[19 + fraction.len ..]);
    const days = days_from_civil(year, month, day);
    const seconds = days * seconds_per_day + hour * 3600 + minute * 60 + second - offset;
    if (seconds < timestamp_seconds_min or seconds > timestamp_seconds_max) return error.InvalidTimestamp;
    return .{ .seconds = seconds, .nanos = @intCast(fraction.nanos) };
}

fn days_in_month(year: u32, month: u32) u32 {
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const lengths = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return lengths[month - 1];
}

/// The offset's seconds east of UTC: "Z", or "+HH:MM" and "-HH:MM" (RFC 3339 §5.6).
fn parse_offset(text: []const u8) Error!i64 {
    if (text.len == 1 and (text[0] == 'Z' or text[0] == 'z')) return 0;
    if (text.len != 6 or text[3] != ':' or (text[0] != '+' and text[0] != '-')) return error.InvalidTimestamp;
    const hours = try field_value(text, 1, 2);
    const minutes = try field_value(text, 4, 2);
    if (hours > 23 or minutes > 59) return error.InvalidTimestamp;
    const seconds: i64 = hours * 3600 + minutes * 60;
    return if (text[0] == '-') -seconds else seconds;
}

/// Reads "-1.5s": an optional sign, whole seconds, a fraction of up to 9 digits, and "s".
pub fn parse_duration(text: []const u8) Error!Instant {
    if (text.len < 2 or text[text.len - 1] != 's') return error.InvalidDuration;
    const negative = text[0] == '-';
    const body = text[@intFromBool(negative) .. text.len - 1];
    const dot = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
    if (dot == 0 or dot > 12) return error.InvalidDuration;
    const whole = std.fmt.parseInt(i64, body[0..dot], 10) catch return error.InvalidDuration;
    if (body[0] == '+' or body[0] == '-') return error.InvalidDuration;
    const fraction = read_fraction(body[dot..]) orelse return error.InvalidDuration;
    if (dot + fraction.len != body.len) return error.InvalidDuration;
    const sign: i64 = if (negative) -1 else 1;
    const instant: Instant = .{ .seconds = sign * whole, .nanos = @intCast(sign * fraction.nanos) };
    check_duration(instant) catch return error.InvalidDuration;
    return instant;
}

const testing = std.testing;

test "timestamps format with 0, 3, 6 or 9 digits and read back" {
    var buffer: [text_len_max]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", try format_timestamp(.{ .seconds = 0, .nanos = 0 }, &buffer));
    try testing.expectEqualStrings("1972-01-01T10:00:20.021Z", try format_timestamp(.{ .seconds = 63_108_020, .nanos = 21_000_000 }, &buffer));
    try testing.expectEqualStrings("0001-01-01T00:00:00.000001Z", try format_timestamp(.{ .seconds = timestamp_seconds_min, .nanos = 1000 }, &buffer));
    try testing.expectEqualStrings("9999-12-31T23:59:59.999999999Z", try format_timestamp(.{ .seconds = timestamp_seconds_max, .nanos = 999_999_999 }, &buffer));
    const back = try parse_timestamp("1972-01-01T10:00:20.021Z");
    try testing.expectEqual(@as(i64, 63_108_020), back.seconds);
    try testing.expectEqual(@as(i32, 21_000_000), back.nanos);
}

test "an offset moves the instant, and malformed or out-of-range text is refused" {
    try testing.expectEqual(@as(i64, -3600), (try parse_timestamp("1970-01-01T00:00:00+01:00")).seconds);
    try testing.expectEqual(@as(i64, 5400), (try parse_timestamp("1970-01-01T00:00:00-01:30")).seconds);
    try testing.expectError(error.InvalidTimestamp, parse_timestamp("1970-02-30T00:00:00Z"));
    try testing.expectError(error.InvalidTimestamp, parse_timestamp("1970-01-01 00:00:00Z"));
    try testing.expectError(error.InvalidTimestamp, parse_timestamp("1970-01-01T00:00:00"));
    var buffer: [text_len_max]u8 = undefined;
    try testing.expectError(error.InvalidTimestamp, format_timestamp(.{ .seconds = timestamp_seconds_max + 1, .nanos = 0 }, &buffer));
}

test "durations format and read with their sign and fraction" {
    var buffer: [text_len_max]u8 = undefined;
    try testing.expectEqualStrings("1.000340012s", try format_duration(.{ .seconds = 1, .nanos = 340_012 }, &buffer));
    try testing.expectEqualStrings("-0.500s", try format_duration(.{ .seconds = 0, .nanos = -500_000_000 }, &buffer));
    try testing.expectEqual(Instant{ .seconds = -1, .nanos = -500_000_000 }, try parse_duration("-1.5s"));
    try testing.expectError(error.InvalidDuration, parse_duration("1.5"));
    try testing.expectError(error.InvalidDuration, parse_duration("315576000001s"));
    try testing.expectError(error.InvalidDuration, format_duration(.{ .seconds = 1, .nanos = -1 }, &buffer));
}
