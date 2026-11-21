//! CEL's `duration(string)` (CEL language definition, "Types and Conversions"): "Duration
//! strings may be zero (`"0"`), negative (`-1h`), fractional (`-23.4s`), and/or compound
//! (`1h34us`)", with the suffixes h, m, s, ms, us and ns. The definition states no grammar of
//! the text. cel-go reads it with Go's time.ParseDuration, and this file follows that.
const std = @import("std");
const proto = @import("protobuf");
const constants = @import("../constants.zig");
const Duration = proto.wkt.Duration;

const Unit = struct { suffix: []const u8, nanos: i128 };

/// Each unit's suffix and its nanoseconds, a longer suffix before the one it starts with.
const units = [_]Unit{
    .{ .suffix = "ns", .nanos = 1 },
    .{ .suffix = "us", .nanos = constants.nanos_per_microsecond },
    .{ .suffix = "ms", .nanos = constants.nanos_per_millisecond },
    .{ .suffix = "s", .nanos = constants.nanos_per_second },
    .{ .suffix = "m", .nanos = constants.seconds_per_minute * constants.nanos_per_second },
    .{ .suffix = "h", .nanos = constants.seconds_per_hour * constants.nanos_per_second },
};

/// The duration `text` states: a sign, then numbers with a unit each, such as "1h30m" and
/// "-1.5s", or "0". Null for any other text, and for a duration past the range of
/// google.protobuf.Duration.
pub fn parse_duration(text: []const u8) ?Duration {
    if (text.len == 0) return null;
    const negative = text[0] == '-';
    // The type is stated: the compiler reads a literal's duration, and there a slice of known
    // bounds is a pointer to an array, which no shorter rest fits.
    var rest: []const u8 = if (negative or text[0] == '+') text[1..] else text;
    if (std.mem.eql(u8, rest, "0")) return .{};
    if (rest.len == 0) return null;
    var total: i128 = 0;
    for (0..text.len) |_| {
        if (rest.len == 0) break;
        const part = read_part(rest) orelse return null;
        total += part.nanos;
        rest = rest[part.len..];
    }
    return from_nanos(if (negative) -total else total);
}

const Part = struct { len: usize, nanos: i128 };

/// One number and its unit: digits, an optional fraction, and a suffix.
fn read_part(rest: []const u8) ?Part {
    const whole_len = digits_len(rest);
    var len = whole_len;
    var fraction: []const u8 = "";
    if (len < rest.len and rest[len] == '.') {
        fraction = rest[len + 1 ..][0..digits_len(rest[len + 1 ..])];
        len += 1 + fraction.len;
    }
    if (whole_len == 0 and fraction.len == 0) return null;
    const unit = unit_of(rest[len..]) orelse return null;
    const whole: i128 = if (whole_len == 0) 0 else std.fmt.parseInt(i128, rest[0..whole_len], constants.decimal_base) catch return null;
    return .{ .len = len + unit.suffix.len, .nanos = whole * unit.nanos + fraction_nanos(fraction, unit.nanos) };
}

/// The nanoseconds of a fraction of a unit: each digit is a tenth of the one before it, and
/// what lies under a nanosecond is dropped.
fn fraction_nanos(fraction: []const u8, unit_nanos: i128) i128 {
    var nanos: i128 = 0;
    var scale = unit_nanos;
    for (fraction) |digit| {
        nanos += @divTrunc(scale * (digit - '0'), constants.decimal_base);
        scale = @divTrunc(scale, constants.decimal_base);
        // A digit under a tenth of a nanosecond adds nothing more.
        if (scale == 0) break;
    }
    return nanos;
}

fn digits_len(rest: []const u8) usize {
    for (rest, 0..) |octet, index| {
        if (!std.ascii.isDigit(octet)) return index;
    }
    return rest.len;
}

fn unit_of(rest: []const u8) ?Unit {
    for (units) |unit| {
        if (std.mem.startsWith(u8, rest, unit.suffix)) return unit;
    }
    return null;
}

/// "Duration values are limited to a single int64 value, or roughly +-290 years" (CEL language
/// definition, "Overflow"): the nanoseconds of a duration's text fit an int64. `nanos` has the
/// sign of `seconds` (google/protobuf/duration.proto).
fn from_nanos(total: i128) ?Duration {
    if (total < std.math.minInt(i64) or total > std.math.maxInt(i64)) return null;
    const seconds = @divTrunc(total, constants.nanos_per_second);
    return .{ .seconds = @intCast(seconds), .nanos = @intCast(@rem(total, constants.nanos_per_second)) };
}

const testing = std.testing;

fn expect_duration(text: []const u8, seconds: i64, nanos: i32) !void {
    const duration = parse_duration(text) orelse return error.TestExpectedDuration;
    try testing.expectEqual(seconds, duration.seconds);
    try testing.expectEqual(nanos, duration.nanos);
}

test "a duration's text is numbers with a unit each, and a sign" {
    const hour = constants.seconds_per_hour;
    const half_second_nanos = 500_000_000;
    try expect_duration("10s", 10, 0);
    try expect_duration("0", 0, 0);
    try expect_duration("-0", 0, 0);
    try expect_duration("1h30m", hour + hour / 2, 0);
    try expect_duration("1.5s", 1, half_second_nanos);
    try expect_duration("-1.5s", -1, -half_second_nanos);
    try expect_duration("+2m", 2 * constants.seconds_per_minute, 0);
    try expect_duration(".5s", 0, half_second_nanos);
    try expect_duration("1500ms", 1, half_second_nanos);
    try expect_duration("3us", 0, 3 * constants.nanos_per_microsecond);
    try expect_duration("7ns", 0, 7);
    try expect_duration("1.5ns", 0, 1);
    try expect_duration("0.0000000001s", 0, 0);
    try expect_duration("1m6s", constants.seconds_per_minute + 6, 0);
}

test "the compiler reads a literal's duration as a program does" {
    // An expression's `duration('...')` is read while the compiler types it.
    const half_second_nanos = 500_000_000;
    inline for (.{ "10s", "-3s", "+2m", "-1.5s", "1h30m", "0", "-0" }) |text| {
        const compiled = comptime parse_duration(text).?;
        const run = parse_duration(text).?;
        try testing.expectEqual(run.seconds, compiled.seconds);
        try testing.expectEqual(run.nanos, compiled.nanos);
    }
    try testing.expectEqual(@as(i32, -half_second_nanos), (comptime parse_duration("-1.5s").?).nanos);
    try testing.expect(comptime parse_duration("-") == null and parse_duration("+s") == null and parse_duration("-1x") == null);
}

test "a text that states no duration, or one past the type's range, gives none" {
    for ([_][]const u8{ "", "-", "10", "s", "1x", "1.s2", "1 s", "1s ", "--1s", ".s", "1h-1m" }) |text| {
        try testing.expect(parse_duration(text) == null);
    }
    // A duration's nanoseconds fit an int64: about 292 years either side of zero.
    try testing.expect(parse_duration("2562047h47m16.854775807s") != null);
    try testing.expect(parse_duration("2562047h47m16.854775808s") == null);
    try testing.expect(parse_duration("-2562047h47m16.854775808s") != null);
    try testing.expect(parse_duration("-2562047h47m16.854775809s") == null);
    try testing.expect(parse_duration("87660000h") == null);
}
