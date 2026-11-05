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
/// duration.proto: the seconds of 10,000 years, either way, which take 12 digits.
pub const duration_seconds_max: i64 = 315_576_000_000;
const duration_seconds_digits_max = 12;
/// The shortest Duration text: one digit and "s".
const duration_len_min = 2;
/// The longest text either form takes: "-315576000000.000000000s" and a Timestamp's 30 octets.
pub const text_len_max = 32;

const nanos_per_second = 1_000_000_000;
const nanos_per_milli = 1_000_000;
const nanos_per_micro = 1_000;
const seconds_per_day = 86_400;
const seconds_per_hour = 3_600;
const seconds_per_minute = 60;
const minutes_per_hour = 60;
const hour_max = 23;
const minute_max = 59;
const second_max = 59;
const months_per_year = 12;
const decimal_base = 10;
/// A fraction has at most 9 digits, and the mapping writes 3, 6 or 9 of them.
const fraction_digits_max = 9;
const milli_digits = 3;
const micro_digits = 6;
/// The fraction's text: the dot and its digits.
const fraction_text_len_max = fraction_digits_max + 1;

// The proleptic Gregorian calendar in eras of 400 years, counted from 0000-03-01, so that the
// leap day ends each year (Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms").
const years_per_era = 400;
const days_per_era = 146_097;
const days_per_year = 365;
const years_per_leap = 4;
const years_per_century = 100;
/// The day of an era's fourth, hundredth and last year that the leap days push forward.
const day_of_era_leap_shift = 1_460;
const day_of_era_century_shift = 36_524;
const day_of_era_last_shift = 146_096;
/// Days from 0000-03-01 to 1970-01-01.
const days_to_epoch = 719_468;
/// Months from March are 153 days for each 5, so day = (153 * month + 2) / 5.
const month_days_numerator = 153;
const month_days_denominator = 5;
const month_days_rounding = 2;
/// February ends the year counted from March: months 1 and 2 belong to the year before.
const february = 2;
/// Month 1 of the civil year is month 10 of the year counted from March.
const march_offset = 9;

// RFC 3339 §5.6's fixed layout: "YYYY-MM-DDTHH:MM:SS", then a fraction and an offset.
const year_len = 4;
const two_digits = 2;
const year_at = 0;
const month_dash_at = year_at + year_len;
const month_at = month_dash_at + 1;
const day_dash_at = month_at + two_digits;
const day_at = day_dash_at + 1;
const time_mark_at = day_at + two_digits;
const hour_at = time_mark_at + 1;
const minute_colon_at = hour_at + two_digits;
const minute_at = minute_colon_at + 1;
const second_colon_at = minute_at + two_digits;
const second_at = second_colon_at + 1;
const fraction_at = second_at + two_digits;
/// The shortest timestamp: the fixed fields and "Z".
const timestamp_len_min = fraction_at + 1;
/// An offset: "+HH:MM".
const offset_hour_at = 1;
const offset_colon_at = offset_hour_at + two_digits;
const offset_minute_at = offset_colon_at + 1;
const offset_len = offset_minute_at + two_digits;

/// Days from 1970-01-01 to the civil date, proleptic Gregorian.
fn days_from_civil(year: i64, month: u32, day: u32) i64 {
    const shifted_year = year - @intFromBool(month <= february);
    const era = @divFloor(shifted_year, years_per_era);
    const year_of_era = shifted_year - era * years_per_era;
    const month_index: i64 = (month + march_offset) % months_per_year;
    const day_of_year = @divFloor(month_days_numerator * month_index + month_days_rounding, month_days_denominator) + day - 1;
    const day_of_era = year_of_era * days_per_year + @divFloor(year_of_era, years_per_leap) - @divFloor(year_of_era, years_per_century) + day_of_year;
    return era * days_per_era + day_of_era - days_to_epoch;
}

const Civil = struct { year: i64, month: u32, day: u32 };

fn civil_from_days(days: i64) Civil {
    const shifted = days + days_to_epoch;
    const era = @divFloor(shifted, days_per_era);
    const day_of_era = shifted - era * days_per_era;
    const leap_days = @divFloor(day_of_era, day_of_era_leap_shift) - @divFloor(day_of_era, day_of_era_century_shift) + @divFloor(day_of_era, day_of_era_last_shift);
    const year_of_era = @divFloor(day_of_era - leap_days, days_per_year);
    const day_of_year = day_of_era - (days_per_year * year_of_era + @divFloor(year_of_era, years_per_leap) - @divFloor(year_of_era, years_per_century));
    const month_index = @divFloor(month_days_denominator * day_of_year + month_days_rounding, month_days_numerator);
    const day: u32 = @intCast(day_of_year - @divFloor(month_days_numerator * month_index + month_days_rounding, month_days_denominator) + 1);
    const month: u32 = @intCast(@mod(month_index + february, months_per_year) + 1);
    const year = year_of_era + era * years_per_era + @intFromBool(month <= february);
    return .{ .year = year, .month = month, .day = day };
}

/// Writes the fraction digits the mapping writes into `buffer`: none, or 3, 6 or 9, the fewest
/// that hold `nanos`. Returns the octets written.
fn write_fraction(nanos: u32, buffer: []u8) Error!usize {
    if (nanos == 0) return 0;
    const digits = std.fmt.bufPrint(buffer, ".{d:0>9}", .{nanos}) catch return error.NoSpaceLeft;
    if (nanos % nanos_per_milli == 0) return 1 + milli_digits;
    if (nanos % nanos_per_micro == 0) return 1 + micro_digits;
    return digits.len;
}

pub fn format_timestamp(instant: Instant, buffer: []u8) Error![]const u8 {
    if (instant.seconds < timestamp_seconds_min or instant.seconds > timestamp_seconds_max) return error.InvalidTimestamp;
    if (instant.nanos < 0 or instant.nanos >= nanos_per_second) return error.InvalidTimestamp;
    const days = @divFloor(instant.seconds, seconds_per_day);
    const second_of_day: u64 = @intCast(instant.seconds - days * seconds_per_day);
    const civil = civil_from_days(days);
    const whole = std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(civil.year)),                        civil.month,
        civil.day,                                             second_of_day / seconds_per_hour,
        second_of_day / seconds_per_minute % minutes_per_hour, second_of_day % seconds_per_minute,
    }) catch return error.NoSpaceLeft;
    return finish_text(buffer, whole.len, @intCast(instant.nanos), "Z");
}

pub fn format_duration(instant: Instant, buffer: []u8) Error![]const u8 {
    try check_duration(instant);
    const negative = instant.seconds < 0 or instant.nanos < 0;
    const whole = std.fmt.bufPrint(buffer, "{s}{d}", .{ if (negative) "-" else "", @abs(instant.seconds) }) catch return error.NoSpaceLeft;
    return finish_text(buffer, whole.len, @abs(instant.nanos), "s");
}

/// Writes the fraction and the suffix after the `len` octets already in `buffer`.
fn finish_text(buffer: []u8, len: usize, nanos: u32, suffix: []const u8) Error![]const u8 {
    var end = len + try write_fraction(nanos, buffer[len..]);
    if (end + suffix.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[end..][0..suffix.len], suffix);
    end += suffix.len;
    return buffer[0..end];
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
        value = value * decimal_base + (octet - '0');
    }
    return value;
}

/// Reads a fraction of 1 to 9 digits after the dot at `text[0]`, as nanoseconds, and its length.
fn read_fraction(text: []const u8) ?struct { nanos: u32, len: usize } {
    if (text.len == 0 or text[0] != '.') return .{ .nanos = 0, .len = 0 };
    var end: usize = 1;
    for (text[1..@min(text.len, fraction_text_len_max)]) |octet| {
        if (octet < '0' or octet > '9') break;
        end += 1;
    }
    if (end == 1) return null;
    var nanos = digits_value(text[1..end]) orelse return null;
    for (end..fraction_text_len_max) |_| nanos *= decimal_base;
    return .{ .nanos = nanos, .len = end };
}

fn field_value(text: []const u8, start: usize, len: usize) Error!u32 {
    if (start + len > text.len) return error.InvalidTimestamp;
    return digits_value(text[start..][0..len]) orelse error.InvalidTimestamp;
}

/// Days in `month` of `year`: the days from its first to the next month's first.
fn days_in_month(year: u32, month: u32) u32 {
    const next_year = year + month / months_per_year;
    const next_month = month % months_per_year + 1;
    return @intCast(days_from_civil(next_year, next_month, 1) - days_from_civil(year, month, 1));
}

/// Whether the fixed separators of "YYYY-MM-DDTHH:MM:SS" are where RFC 3339 §5.6 puts them.
fn separators_hold(text: []const u8) bool {
    if (text.len < timestamp_len_min) return false;
    const dashes = text[month_dash_at] == '-' and text[day_dash_at] == '-';
    const colons = text[minute_colon_at] == ':' and text[second_colon_at] == ':';
    // RFC 3339 §5.6: "T" separates the date and the time, in either case.
    const mark = text[time_mark_at] == 'T' or text[time_mark_at] == 't';
    return dashes and colons and mark;
}

/// Reads RFC 3339 text: "YYYY-MM-DDTHH:MM:SS", a fraction, and "Z" or an offset "+HH:MM".
pub fn parse_timestamp(text: []const u8) Error!Instant {
    if (!separators_hold(text)) return error.InvalidTimestamp;
    const year = try field_value(text, year_at, year_len);
    const month = try field_value(text, month_at, two_digits);
    const day = try field_value(text, day_at, two_digits);
    const hour = try field_value(text, hour_at, two_digits);
    const minute = try field_value(text, minute_at, two_digits);
    const second = try field_value(text, second_at, two_digits);
    if (month < 1 or month > months_per_year or day < 1 or day > days_in_month(year, month)) return error.InvalidTimestamp;
    if (hour > hour_max or minute > minute_max or second > second_max) return error.InvalidTimestamp;
    const fraction = read_fraction(text[fraction_at..]) orelse return error.InvalidTimestamp;
    const offset = try parse_offset(text[fraction_at + fraction.len ..]);
    const days = days_from_civil(year, month, day);
    const seconds = days * seconds_per_day + hour * seconds_per_hour + minute * seconds_per_minute + second - offset;
    if (seconds < timestamp_seconds_min or seconds > timestamp_seconds_max) return error.InvalidTimestamp;
    return .{ .seconds = seconds, .nanos = @intCast(fraction.nanos) };
}

/// The offset's seconds east of UTC: "Z", or "+HH:MM" and "-HH:MM" (RFC 3339 §5.6).
fn parse_offset(text: []const u8) Error!i64 {
    if (text.len == 1 and (text[0] == 'Z' or text[0] == 'z')) return 0;
    if (text.len != offset_len or text[offset_colon_at] != ':' or (text[0] != '+' and text[0] != '-')) return error.InvalidTimestamp;
    const hours = try field_value(text, offset_hour_at, two_digits);
    const minutes = try field_value(text, offset_minute_at, two_digits);
    if (hours > hour_max or minutes > minute_max) return error.InvalidTimestamp;
    const seconds: i64 = hours * seconds_per_hour + minutes * seconds_per_minute;
    return if (text[0] == '-') -seconds else seconds;
}

/// Reads "-1.5s": an optional sign, whole seconds, a fraction of up to 9 digits, and "s".
pub fn parse_duration(text: []const u8) Error!Instant {
    if (text.len < duration_len_min or text[text.len - 1] != 's') return error.InvalidDuration;
    const negative = text[0] == '-';
    const body = text[@intFromBool(negative) .. text.len - 1];
    const dot = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
    if (dot == 0 or dot > duration_seconds_digits_max) return error.InvalidDuration;
    const whole = std.fmt.parseInt(i64, body[0..dot], decimal_base) catch return error.InvalidDuration;
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
