//! The proof harness of the JSON number fast paths (pepegrillo's performance method, step 5),
//! beside protobuf_fast_path_test.zig's harness of the binary values. Each path gives what a
//! reference gives, and the references share no code with the paths they check.
//!
//! - Integers: each 32- and 64-bit type reads every text as the standard library's parsers read
//!   it, the code `parse_integer` ran before its decimal path. The sweeps cover each type's
//!   bounds and one on each side, every length to 21 digits, signs, leading zeros, separators,
//!   exponents and fractions.
//! - Floats: each float and double writes the text the standard library's Ryu writes, the code
//!   `write_float` ran before its exact-decimal path. The sweeps cover every binary fraction of
//!   up to 24 bits with each numerator to 1024, the bounds of the digits the path takes and one
//!   on each side, powers of two and ten, and values spread over every bit pattern.
//! - A fuzz property over both checks, which `zig build test` runs over its corpus.
const std = @import("std");
const testing = std.testing;
const json = @import("json");
const codec = @import("codec");
const json_scalar = @import("json_scalar.zig");
const json_float = @import("json_float.zig");
const constants = @import("constants.zig");

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
/// Room for any float's JSON text.
const float_room_len = 64;
/// The bits of a binary fraction the float sweep divides by, and the numerators it divides.
const fraction_bits_max = 24;
const numerator_max = 1024;
/// The powers of two and of ten the float sweep writes, past the range the path takes.
const power_two_max = 80;
const power_ten_max = 24;
/// The values the bit-pattern sweep writes of each type, spread evenly over its patterns.
const pattern_count = 65_536;
/// The proto3 JSON writers' bounds of the plain form, as `write_float` keeps them.
const float_exponent_below = 1e-6;
const float_exponent_above = 1e21;
/// The numerators the bound sweep writes on each side of each bound.
const bound_neighbours = 2;
/// 1 / 2^k = 5^k / 10^k.
const binary_to_decimal = 5;

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

/// Writes a float as `write_float` wrote it before its exact-decimal path: Ryu's decimal mode in
/// the plain range, its scientific mode outside it, and the names of NaN and the infinities.
fn reference_float(comptime V: type, value: V, text: *json.TextWriter) !void {
    if (std.math.isNan(value)) return text.string("NaN");
    if (std.math.isInf(value)) return text.string(if (value > 0) "Infinity" else "-Infinity");
    var buffer: [float_room_len]u8 = undefined;
    const magnitude = @abs(value);
    const plain = magnitude == 0 or (magnitude >= float_exponent_below and magnitude < float_exponent_above);
    const digits = if (plain)
        std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable
    else
        std.fmt.bufPrint(&buffer, "{e}", .{value}) catch unreachable;
    try text.number(digits);
}

fn check_float_as(comptime V: type, value: V) !void {
    var want_room: [float_room_len]u8 = undefined;
    var want = json.TextWriter.init(&want_room, .text, codec.Features.target());
    try reference_float(V, value, &want);
    var got_room: [float_room_len]u8 = undefined;
    var got = json.TextWriter.init(&got_room, .text, codec.Features.target());
    try json_scalar.write_float(V, value, &got);
    testing.expectEqualStrings(want.written(), got.written()) catch |failure| {
        std.debug.print("{s} {e}\n", .{ @typeName(V), value });
        return failure;
    };
}

/// Checks `value` as a double and as a float, and its negation.
fn check_float(value: f64) !void {
    for ([_]f64{ value, -value }) |signed| {
        try check_float_as(f64, signed);
        try check_float_as(f32, @floatCast(signed));
    }
}

test "floats write as Ryu writes them, at every binary fraction of short numerators" {
    for (0..fraction_bits_max + 1) |bits| {
        const scale = std.math.ldexp(@as(f64, 1), -@as(i32, @intCast(bits)));
        for (0..numerator_max + 1) |numerator| try check_float(@as(f64, @floatFromInt(numerator)) * scale);
    }
}

/// Checks the odd numerators m / 2^k nearest below the bound 10^p of the path's digits, with
/// m * 5^k on each side of 10^p, and the integers on each side of 10^p.
fn check_digit_bound(comptime V: type, digits: u6) !void {
    const bound = std.math.pow(u64, decimal_base, digits);
    var five_power: u64 = 1;
    for (0..fraction_bits_max) |bits| {
        const numerator = bound / five_power;
        for (0..bound_neighbours + bound_neighbours + 1) |offset| {
            const near = (numerator + offset) -| bound_neighbours;
            const value = std.math.ldexp(@as(f64, @floatFromInt(near)), -@as(i32, @intCast(bits)));
            try check_float_as(V, @floatCast(value));
            try check_float_as(V, @floatCast(-value));
        }
        five_power *= binary_to_decimal;
        if (five_power > bound) break;
    }
}

test "floats write as Ryu writes them, at the bounds of the digits the fast path takes" {
    for (1..constants.limits.json_double_exact_digits_max + 3) |digits| try check_digit_bound(f64, @intCast(digits));
    for (1..constants.limits.json_float_exact_digits_max + 3) |digits| try check_digit_bound(f32, @intCast(digits));
    for (0..power_two_max) |power| {
        const value = std.math.ldexp(@as(f64, 1), @as(i32, @intCast(power)));
        for ([_]f64{ value - 1, value, value + 1, 1 / value }) |near| try check_float(near);
    }
    var power_ten: f64 = 1;
    for (0..power_ten_max) |_| {
        for ([_]f64{ power_ten - 1, power_ten, power_ten + 1, 1 / power_ten }) |near| try check_float(near);
        power_ten *= decimal_base;
    }
    for ([_]f64{ 0, 98.625, 0.75, 0.1, 1.0 / 3.0, std.math.floatMin(f64), std.math.floatMax(f64) }) |value| try check_float(value);
    try check_float(std.math.nan(f64));
    try check_float(std.math.inf(f64));
}

test "the exact-decimal path refuses zero, subnormals, NaN and the infinities" {
    var buffer: [float_room_len]u8 = undefined;
    inline for (.{ f32, f64 }) |V| {
        const refused = [_]V{ 0, -0.0, std.math.floatTrueMin(V), std.math.floatMin(V) / 2, std.math.nan(V), std.math.inf(V), -std.math.inf(V) };
        for (refused) |value| try testing.expectEqual(null, json_float.exact_text(V, value, &buffer));
    }
    try testing.expectEqualStrings("-98.625", json_float.exact_text(f64, -98.625, &buffer).?);
}

test "floats write as Ryu writes them, over values spread across every bit pattern" {
    const stride32 = std.math.maxInt(u32) / pattern_count;
    const stride64 = std.math.maxInt(u64) / pattern_count;
    for (0..pattern_count) |index| {
        try check_float_as(f32, @bitCast(@as(u32, @intCast(index)) *% stride32));
        try check_float_as(f64, @bitCast(@as(u64, index) *% stride64));
    }
}

fn fuzz_integer(_: void, smith: *testing.Smith) anyerror!void {
    var input: [fuzz_input_len_max]u8 = @splat(0);
    const len = smith.slice(&input);
    try check_integer(input[0..len]);
    var buffer: [integer_text_len_max]u8 = undefined;
    try check_integer(std.fmt.bufPrint(&buffer, "{d}", .{smith.value(i64)}) catch unreachable);
    try check_integer(std.fmt.bufPrint(&buffer, "{d}", .{smith.value(u64)}) catch unreachable);
    try check_float_as(f64, @bitCast(smith.value(u64)));
    try check_float_as(f32, @bitCast(smith.value(u32)));
}

test "fuzz: an integer reads and a float writes as the references do, from any input" {
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
