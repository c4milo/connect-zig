//! The proof harness of the JSON number fast paths (pepegrillo's performance method, step 5),
//! beside protobuf_fast_path_test.zig's harness of the binary values. Each path gives what a
//! reference gives, and the references share no code with the paths they check.
//!
//! - Integers: each 32- and 64-bit type reads every text as a reference of the proto3 JSON mapping
//!   reads it: a JSON number (RFC 8259 §6) whose digits, the point moved by the exponent, make an
//!   integer, read exactly, as Go's protojson reads it. The sweeps cover each type's bounds and
//!   one on each side, every length to 21 digits, signs, leading zeros, separators, exponents and
//!   fractions.
//! - Floats: each float and double writes the text the standard library's Ryu writes, the code
//!   `write_float` ran before its exact-decimal path. The sweeps cover every binary fraction of
//!   up to 24 bits with each numerator to 1024, the bounds of the digits the path takes and one
//!   on each side, powers of two and ten, and values spread over every bit pattern.
//! - Float texts: each float and double reads every text as the standard library's parser reads
//!   it, the code `parse_float` ran before its exact-quotient path. The sweeps place a point at
//!   each place of numerators at the bounds of an exact significand, and of 19 and 20 digits,
//!   with signs, leading zeros and malformed points.
//! - A fuzz property over every check, which `zig build test` runs over its corpus.
const std = @import("std");
const assert = std.debug.assert;
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
/// The digits the integer reference reads: any text a sweep or a fuzz input holds, and the zeros
/// an exponent adds up to `reference_u128_digits_max`.
const reference_digits_len_max = 64;
/// The most decimal digits a u128 holds whatever they are: maxInt(u128) has 39.
const reference_u128_digits_max = 38;
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
/// The most digits after the point the float text sweep writes, past a double's 22.
const fraction_len_max = 24;

/// Reads an integer as the proto3 JSON mapping and Go's protojson read it, with no code of
/// `parse_integer`'s: the text must be a JSON number (RFC 8259 §6), and its digits, the point
/// moved by the exponent, may leave none but 0 after the point. The value is read exactly
/// through a u128, which holds each digit string the sweeps and the fuzz inputs build.
fn reference_integer(comptime V: type, octets: []const u8) json_scalar.DecodeError!V {
    assert(octets.len <= reference_digits_len_max);
    if (!reference_is_number(octets)) return error.InvalidNumber;
    const exponent_at = std.mem.indexOfAny(u8, octets, "eE") orelse octets.len;
    const negative = octets[0] == '-';
    const mantissa = octets[@intFromBool(negative)..exponent_at];
    const point = std.mem.indexOfScalar(u8, mantissa, '.') orelse mantissa.len;
    const fraction = if (point == mantissa.len) "" else mantissa[point + 1 ..];
    var digits_room: [reference_digits_len_max]u8 = @splat('0');
    @memcpy(digits_room[0..point], mantissa[0..point]);
    @memcpy(digits_room[point..][0..fraction.len], fraction);
    const shift = reference_exponent(octets, exponent_at) - @as(i64, @intCast(fraction.len));
    const magnitude = try reference_magnitude(&digits_room, point + fraction.len, shift);
    if (magnitude > @as(u128, std.math.maxInt(u64)) + 1) return error.NumberOutOfRange;
    const value: i128 = if (negative) -@as(i128, @intCast(magnitude)) else @intCast(magnitude);
    return std.math.cast(V, value) orelse error.NumberOutOfRange;
}

/// The exponent after the "e" at `exponent_at`, or 0 with none. One past an i32 leaves no
/// integer in range but 0, as an i32's bound does.
fn reference_exponent(octets: []const u8, exponent_at: usize) i64 {
    if (exponent_at == octets.len) return 0;
    const text = octets[exponent_at + 1 ..];
    return std.fmt.parseInt(i32, text, decimal_base) catch |failure| switch (failure) {
        error.Overflow => if (text[0] == '-') std.math.minInt(i32) else std.math.maxInt(i32),
        error.InvalidCharacter => unreachable,
    };
}

/// The value of the first `len` digits of `room` with `shift` places of the point applied:
/// dropped digits must be 0, and added ones are 0.
fn reference_magnitude(room: *[reference_digits_len_max]u8, len: usize, shift: i64) json_scalar.DecodeError!u128 {
    const dropped: usize = if (shift < 0) @intCast(@min(-shift, @as(i64, @intCast(len)))) else 0;
    const kept = room[0 .. len - dropped];
    if (std.mem.indexOfNone(u8, room[kept.len..len], "0") != null) return error.InvalidNumber;
    if (std.mem.indexOfNone(u8, kept, "0") == null) return 0;
    const zeros: usize = if (shift > 0) @intCast(@min(shift, reference_digits_len_max)) else 0;
    // A u128 holds 38 digits, far past any 64-bit value.
    if (kept.len + zeros > reference_u128_digits_max) return error.NumberOutOfRange;
    @memset(room[kept.len..][0..zeros], '0');
    return std.fmt.parseInt(u128, room[0 .. kept.len + zeros], decimal_base) catch unreachable;
}

/// The states of a walk through RFC 8259 §6's number grammar, and the classes of octet it reads.
const Grammar = enum { start, sign, zero, integer, point, fraction, e, exponent_sign, exponent };
const Octet = enum { minus, plus, zero, digit, point, e, other };

/// The state each class of octet leads to from each state, or null where the grammar stops.
const transitions = table: {
    var next: [@typeInfo(Grammar).@"enum".fields.len][@typeInfo(Octet).@"enum".fields.len]?Grammar = @splat(@splat(null));
    next[@intFromEnum(Grammar.start)][@intFromEnum(Octet.minus)] = .sign;
    for ([_]Grammar{ .start, .sign }) |from| {
        next[@intFromEnum(from)][@intFromEnum(Octet.zero)] = .zero;
        next[@intFromEnum(from)][@intFromEnum(Octet.digit)] = .integer;
    }
    for ([_]Octet{ .zero, .digit }) |octet| {
        next[@intFromEnum(Grammar.integer)][@intFromEnum(octet)] = .integer;
        next[@intFromEnum(Grammar.point)][@intFromEnum(octet)] = .fraction;
        next[@intFromEnum(Grammar.fraction)][@intFromEnum(octet)] = .fraction;
        for ([_]Grammar{ .e, .exponent_sign, .exponent }) |from| next[@intFromEnum(from)][@intFromEnum(octet)] = .exponent;
    }
    for ([_]Grammar{ .zero, .integer }) |from| next[@intFromEnum(from)][@intFromEnum(Octet.point)] = .point;
    for ([_]Grammar{ .zero, .integer, .fraction }) |from| next[@intFromEnum(from)][@intFromEnum(Octet.e)] = .e;
    next[@intFromEnum(Grammar.e)][@intFromEnum(Octet.minus)] = .exponent_sign;
    next[@intFromEnum(Grammar.e)][@intFromEnum(Octet.plus)] = .exponent_sign;
    break :table next;
};

fn class_of(octet: u8) Octet {
    return switch (octet) {
        '-' => .minus,
        '+' => .plus,
        '0' => .zero,
        '1'...'9' => .digit,
        '.' => .point,
        'e', 'E' => .e,
        else => .other,
    };
}

/// Whether `octets` is a JSON number (RFC 8259 §6), as a walk through its grammar's states.
fn reference_is_number(octets: []const u8) bool {
    var state: Grammar = .start;
    for (octets) |octet| {
        state = transitions[@intFromEnum(state)][@intFromEnum(class_of(octet))] orelse return false;
    }
    return state == .zero or state == .integer or state == .fraction or state == .exponent;
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
    "",                         "-",                       "+",                        "--1",                      "-+1",                     "+1",
    "+0",                       "-0",                      "00",                       "-00",                      "007",                     "1_000",
    "_1",                       "1_",                      "1e2",                      "-1e2",                     "1E2",                     "1e-2",
    "1.0",                      "1.5",                     "-0.0",                     ".5",                       "1.",                      "0x10",
    "0b1",                      "inf",                     "-inf",                     "nan",                      "Infinity",                " 1",
    "1 ",                       "1a",                      "a1",                       "9e18",                     "-9.3e18",                 "1.8e19",
    "٣",
    "1\x00",                    "\xff",                    "4294967295.0",             "2147483647e0",             "-2147483648e0",           "01.0",
    "00.5",                     "1e",                      "1e+",                      "1ee2",                     "e2",                      "1.e2",
    "-.5",                      "1e+2",                    "10e-1",                    "100e-2",                   "0e5",                     "1.00e2",
    "-0.5",                     "0e99999999999",           "1e99999999999",            "1e-99999999999",           "9007199254740993e0",      "1.8446744073709551615e19",
    "1.8446744073709551616e19", "9.223372036854775807e18", "-9.223372036854775808e18", "-9.223372036854775809e18", "18446744073709551616e-1",
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

/// Reads a float as `parse_float` read a number before its exact-quotient path.
fn reference_float_text(comptime V: type, octets: []const u8) json_scalar.DecodeError!V {
    const value = std.fmt.parseFloat(V, octets) catch return error.InvalidNumber;
    if (std.math.isInf(value)) return error.NumberOutOfRange;
    return value;
}

fn check_float_text_as(comptime V: type, octets: []const u8) !void {
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(V));
    const want = reference_float_text(V, octets);
    const got = json_scalar.parse_float(V, octets, false);
    if (want) |value| {
        testing.expectEqual(@as(Bits, @bitCast(value)), @as(Bits, @bitCast(try got))) catch |failure| {
            std.debug.print("{s} as {s}\n", .{ octets, @typeName(V) });
            return failure;
        };
    } else |refusal| try testing.expectError(refusal, got);
}

fn check_float_text(octets: []const u8) !void {
    try check_float_text_as(f64, octets);
    try check_float_text_as(f32, octets);
}

/// Checks the digits of `numerator`, with "-" and without, with a point at each place from none
/// to `fraction_len_max` digits before the end, padded with leading zeros.
fn check_point_places(numerator: u64) !void {
    var digits_room: [integer_text_len_max]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_room, "{d}", .{numerator}) catch unreachable;
    var text: [float_room_len]u8 = undefined;
    for (0..fraction_len_max + 1) |fraction_len| {
        const padded_len = @max(digits.len, fraction_len + 1);
        const zeros = padded_len - digits.len;
        for ([_][]const u8{ "", "-" }) |sign| {
            @memcpy(text[0..sign.len], sign);
            @memset(text[sign.len..][0..zeros], '0');
            @memcpy(text[sign.len + zeros ..][0..digits.len], digits);
            const point = sign.len + padded_len - fraction_len;
            if (fraction_len == 0) {
                try check_float_text(text[0 .. sign.len + padded_len]);
                continue;
            }
            std.mem.copyBackwards(u8, text[point + 1 ..][0..fraction_len], text[point..][0..fraction_len]);
            text[point] = '.';
            try check_float_text(text[0 .. sign.len + padded_len + 1]);
        }
    }
}

test "float texts read as the reference reads them, with a point at each place" {
    const significand32: u64 = 1 << (std.math.floatMantissaBits(f32) + 1);
    const significand64: u64 = 1 << (std.math.floatMantissaBits(f64) + 1);
    for ([_]u64{ significand32, significand64 }) |bound| {
        for (0..bound_neighbours + bound_neighbours + 1) |offset| try check_point_places(bound + offset - bound_neighbours);
    }
    for (0..numerator_max) |numerator| try check_point_places(numerator);
    // Each power of ten a u64 holds, 10^0 to 10^19, and the run of nines below it.
    for (0..digits_len_max - 1) |exponent| {
        const power = std.math.pow(u64, decimal_base, exponent);
        try check_point_places(power);
        try check_point_places(power - 1);
    }
    try check_point_places(std.math.maxInt(u64));
}

/// Float texts beside the short decimals a JSON writer gives, which the general path reads or
/// refuses.
const unusual_floats = [_][]const u8{
    "",      "-",            ".",            "-.",                                      ".5",                       "-.5",              "1.",                 "-1.",        "1.2.3",                "1..2",
    "+1",    "+1.5",         "1e5",          "1.5e-3",                                  "1E+2",                     "0x1p3",            "inf",                "nan",        "1_0.5",                "1.5_0",
    "1-",    "1.-5",         "--1",          "-0",                                      "-0.0",                     "00.250",           "0.000000",           " 1.5",       "1.5 ",                 "1,5",
    "1e400", "3.4028235e38", "3.4028236e38", "340282356779733661637539395458142568448", "0.0000000000000000000001", "9007199254740993", "9007199254740993.0", "16777217.0",
    // Past maxInt(u64), where 20 digits wrap to 0 and 1.
    "18446744073709551616", "18446744073709551617",
};

test "float texts read as the reference reads them, from texts a JSON writer does not give" {
    for (unusual_floats) |text| try check_float_text(text);
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
    try check_float_text(input[0..len]);
    try check_point_places(smith.value(u64));
}

test "fuzz: each number path gives what its reference gives, on any input" {
    try testing.fuzz({}, fuzz_integer, .{ .corpus = &.{
        "0",
        "-9223372036854775808",
        "18446744073709551615",
        "4294967296",
        "-2147483649",
        "1e2",
        "+1_0",
        "98.625",
        "-0.000000059604644775390625",
    } });
}
