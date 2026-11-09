//! The proof harness of the JSON number fast paths (pepegrillo's performance method, step 5),
//! beside protobuf_fast_path_test.zig's harness of the binary values. Each path gives what a
//! reference gives, and the references share no code with the paths they check.
//!
//! - Integers: each 32- and 64-bit type reads every text as the standard library's parsers read
//!   it, the code `parse_integer` ran before its decimal path. The sweeps cover each type's
//!   bounds and one on each side, every length to 21 digits, signs, leading zeros, separators,
//!   exponents and fractions.
//! - A fuzz property over the same check, which `zig build test` runs over its corpus.
const std = @import("std");
const testing = std.testing;
const json_scalar = @import("json_scalar.zig");

/// The integer types the JSON mapping reads: int32, uint32, int64 and uint64, and their fixed and
/// zigzag kinds, which hold the same values.
const integer_types = .{ i32, u32, i64, u64 };
/// Room for any integer text a sweep builds: a sign, 21 digits and an exponent.
const integer_text_len_max = 32;
/// The most digits a sweep writes, one past the 20 that maxInt(u64) takes.
const digits_len_max = 21;
/// The most octets one fuzz input holds.
const fuzz_input_len_max = 32;
const decimal_base = 10;

/// Reads an integer as `parse_integer` read it before its decimal path: the standard library's
/// integer parser, then its float parser for an integral value with an exponent or a fraction.
fn reference_integer(comptime V: type, octets: []const u8) json_scalar.DecodeError!V {
    if (std.fmt.parseInt(V, octets, decimal_base)) |value| return value else |failure| switch (failure) {
        error.Overflow => return error.NumberOutOfRange,
        error.InvalidCharacter => {},
    }
    const float = std.fmt.parseFloat(f64, octets) catch return error.InvalidNumber;
    if (@trunc(float) != float) return error.InvalidNumber;
    const low: f64 = @floatFromInt(std.math.minInt(V));
    const bits_below: i32 = @bitSizeOf(V) - @as(i32, @intFromBool(@typeInfo(V).int.signedness == .signed));
    const high_exclusive = std.math.ldexp(@as(f64, 1), bits_below);
    if (float < low or float >= high_exclusive) return error.NumberOutOfRange;
    return @intFromFloat(float);
}

fn check_integer_as(comptime V: type, octets: []const u8) !void {
    const want = reference_integer(V, octets);
    const got = json_scalar.parse_integer(V, octets);
    if (want) |value| {
        testing.expectEqual(value, try got) catch |failure| {
            std.debug.print("{s} as {s}\n", .{ octets, @typeName(V) });
            return failure;
        };
    } else |refusal| try testing.expectError(refusal, got);
}

/// Checks `octets` as every integer type.
fn check_integer(octets: []const u8) !void {
    inline for (integer_types) |V| try check_integer_as(V, octets);
}

/// Checks `value`'s decimal text, and the texts one below and one above it.
fn check_around(value: i128) !void {
    var buffer: [integer_text_len_max]u8 = undefined;
    for ([_]i128{ value - 1, value, value + 1 }) |near| {
        try check_integer(std.fmt.bufPrint(&buffer, "{d}", .{near}) catch unreachable);
    }
}

test "integers read as the reference reads them, at each type's bounds and on each side" {
    try check_around(0);
    inline for (integer_types) |V| {
        try check_around(std.math.minInt(V));
        try check_around(std.math.maxInt(V));
        try check_around(-@as(i128, std.math.maxInt(V)));
    }
    // Each power of ten that a u64 holds, where the count of digits changes.
    var power: i128 = 1;
    for (0..digits_len_max) |_| {
        try check_around(power);
        try check_around(-power);
        power *= decimal_base;
    }
}

/// Texts beside a number that a JSON writer does not give, which the general path reads or
/// refuses: signs, separators, exponents, fractions, bases and spaces.
const unusual_integers = [_][]const u8{
    "",             "-",           "+",         "--1",       "-+1",          "+1",
    "+0",           "-0",          "00",        "-00",       "007",          "1_000",
    "_1",           "1_",          "1e2",       "-1e2",      "1E2",          "1e-2",
    "1.0",          "1.5",         "-0.0",      ".5",        "1.",           "0x10",
    "0b1",          "inf",         "-inf",      "nan",       "Infinity",     " 1",
    "1 ",           "1a",          "a1",        "9e18",      "-9.3e18",      "1.8e19",
    "٣",            "1\x00",       "\xff",      "4294967295.0", "2147483647e0", "-2147483648e0",
};

test "integers read as the reference reads them, from texts a JSON writer does not give" {
    for (unusual_integers) |text| try check_integer(text);
}

test "integers read as the reference reads them, at every length of digits" {
    var text: [integer_text_len_max]u8 = undefined;
    // Each sign, then each run of digits: all nines, a one and zeros, and leading zeros.
    for ([_][]const u8{ "", "-", "+" }) |sign| {
        @memcpy(text[0..sign.len], sign);
        for (1..digits_len_max + 1) |len| {
            const digits = text[sign.len..][0..len];
            for ([_]u8{ '9', '0', '5' }) |fill| {
                @memset(digits, fill);
                try check_integer(text[0 .. sign.len + len]);
                digits[0] = '1';
                try check_integer(text[0 .. sign.len + len]);
                digits[len - 1] = 'x';
                try check_integer(text[0 .. sign.len + len]);
            }
        }
    }
}

fn fuzz_integer(_: void, smith: *testing.Smith) anyerror!void {
    var input: [fuzz_input_len_max]u8 = @splat(0);
    const len = smith.slice(&input);
    try check_integer(input[0..len]);
    var buffer: [integer_text_len_max]u8 = undefined;
    try check_integer(std.fmt.bufPrint(&buffer, "{d}", .{smith.value(i64)}) catch unreachable);
    try check_integer(std.fmt.bufPrint(&buffer, "{d}", .{smith.value(u64)}) catch unreachable);
}

test "fuzz: an integer reads as the reference reads it, from any text" {
    try testing.fuzz({}, fuzz_integer, .{ .corpus = &.{
        "0",
        "-9223372036854775808",
        "18446744073709551615",
        "4294967296",
        "-2147483649",
        "1e2",
        "+1_0",
    } });
}
