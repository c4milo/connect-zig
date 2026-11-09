//! The fast path of a float's JSON text: a value that equals a decimal of few significant digits,
//! such as 0.25 or 98.625, written without the standard library's Ryu (proto3 JSON mapping,
//! "JSON Mapping": a float is a number, in the shortest text that reads back as the same value).
//!
//! Such a decimal is the shortest text of the value, and the only one of its length. Two
//! decimals of at most p significant digits lie at least x / 10^p apart near x, and every text
//! that reads back as x lies within one unit in the last place of x: 2^-52 x for a double and
//! 2^-23 x for a float. So when 10^-p is larger, at most one such decimal reads back as x, and
//! the decimal equal to x is it. That bounds p at 15 for a double and 6 for a float.
//!
//! The reading side has a fast path too: a text "-int.frac" whose digits m and fraction length k
//! are small reads as m / 10^k in one division. Both operands are exact in `V` when m is at most
//! 2^53 (2^24 for a float) and 10^k at most 10^22 (10^10), so the quotient rounds once, as a
//! correct parser rounds (Clinger, "How to read floating point numbers accurately", 1990).
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const decimal_base = 10;
/// 1 / 2^k = 5^k / 10^k: the factor that turns a binary fraction's digits into decimal ones.
const binary_to_decimal = 5;
/// The longest text the fast path writes: "-0." and a double's longest fraction, 21 digits, as
/// 5^21 < 10^15 < 5^22.
pub const text_len_max = 24;

comptime {
    assert(text_len_max >= "-0.".len + powers_of_five(f64).len - 1);
}

/// The most digits the reading fast path accumulates: any 19 fit in a u64.
const read_digits_len_max = constants.limits.json_integer_digits_len_max;

/// The most significant digits of a decimal the fast path writes for `V`.
fn digits_max(comptime V: type) comptime_int {
    return switch (V) {
        f64 => constants.limits.json_double_exact_digits_max,
        f32 => constants.limits.json_float_exact_digits_max,
        else => @compileError("a float of 32 or 64 bits"),
    };
}

/// The powers 5^k whose product with an odd significand can stay below 10^p: the digits of
/// m / 2^k are those of m * 5^k, with k of them after the point.
fn powers_of_five(comptime V: type) []const u64 {
    const bound = std.math.pow(u64, decimal_base, digits_max(V));
    comptime var powers: []const u64 = &.{};
    comptime var power: u64 = 1;
    inline while (power < bound) : (power *= binary_to_decimal) powers = powers ++ .{power};
    return powers;
}

/// Writes `value` into `buffer` as the decimal it equals, when that decimal is short enough to be
/// its shortest text. Gives null for zero, a subnormal, a value with more digits, and NaN or an
/// infinity, which the caller writes otherwise.
pub fn exact_text(comptime V: type, value: V, buffer: []u8) ?[]const u8 {
    comptime assert(V == f32 or V == f64);
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(V));
    const mantissa_bits = std.math.floatMantissaBits(V);
    const exponent_mask = (1 << std.math.floatExponentBits(V)) - 1;
    const bits: Bits = @bitCast(value);
    // Zero and a subnormal take an exponent below -1000, and NaN and an infinity one above 900,
    // so the bounds on the digits below refuse them all.
    const biased: i32 = @intCast((bits >> mantissa_bits) & exponent_mask);
    const mantissa: u64 = bits & ((1 << mantissa_bits) - 1);
    var significand: u64 = mantissa | (1 << mantissa_bits);
    // value = significand * 2^exponent, with the significand odd once its trailing zeros go.
    var exponent: i32 = biased - std.math.floatExponentMax(V) - mantissa_bits;
    const zeros = @ctz(significand);
    significand >>= @intCast(zeros);
    exponent += zeros;
    const negative = bits >> (@bitSizeOf(V) - 1) != 0;
    if (exponent >= 0) return write_integer(V, significand, exponent, negative, buffer);
    const powers = comptime powers_of_five(V);
    const fraction_len: u32 = @intCast(-exponent);
    if (fraction_len >= powers.len) return null;
    const scaled = @mulWithOverflow(significand, powers[fraction_len]);
    if (scaled[1] != 0 or scaled[0] >= comptime std.math.pow(u64, decimal_base, digits_max(V))) return null;
    return write_decimal(scaled[0], fraction_len, negative, buffer);
}

/// Writes significand * 2^exponent, an integer, when it has few enough digits.
fn write_integer(comptime V: type, significand: u64, exponent: i32, negative: bool, buffer: []u8) ?[]const u8 {
    const bound = comptime std.math.pow(u64, decimal_base, digits_max(V));
    if (exponent >= std.math.log2_int(u64, bound) + 1) return null;
    const shifted = @shlWithOverflow(significand, @as(u6, @intCast(exponent)));
    if (shifted[1] != 0 or shifted[0] >= bound) return null;
    return write_decimal(shifted[0], 0, negative, buffer);
}

/// Writes digits / 10^fraction_len in positional notation at the end of `buffer`: "-", the
/// integer part or "0", then "." and the `fraction_len` digits after the point, as Ryu's decimal
/// mode writes them. It writes from the last digit back, so it needs no staging array.
fn write_decimal(digits: u64, fraction_len: u32, negative: bool, buffer: []u8) []const u8 {
    assert(buffer.len >= text_len_max);
    var start = buffer.len;
    var count: u32 = 0;
    var rest = digits;
    // The integer part has at least one digit, and the fraction's leading zeros come before it.
    for (0..text_len_max) |_| {
        if (rest == 0 and count > fraction_len) break;
        if (count == fraction_len and count != 0) {
            start -= 1;
            buffer[start] = '.';
        }
        start -= 1;
        buffer[start] = '0' + @as(u8, @intCast(rest % decimal_base));
        rest /= decimal_base;
        count += 1;
    }
    assert(rest == 0);
    if (negative) {
        start -= 1;
        buffer[start] = '-';
    }
    return buffer[start..];
}

/// The powers 10^k that `V` holds exactly: 5^k fits in its significand.
fn exact_powers_of_ten(comptime V: type) []const V {
    const significand_max = 1 << (std.math.floatMantissaBits(V) + 1);
    comptime var powers: []const V = &.{};
    comptime var five_power: u64 = 1;
    comptime var power: V = 1;
    inline while (five_power <= significand_max) : (five_power *= binary_to_decimal) {
        powers = powers ++ .{power};
        power *= decimal_base;
    }
    return powers;
}

/// The digits of a decimal text as one integer, and how many of them follow its point.
const Decimal = struct { magnitude: u64, fraction_len: usize };

/// Reads "int", "int.frac" or ".frac", with a digit after any point, of at most
/// `read_digits_len_max` digits in all. Gives null for any other text. The standard library's
/// parser reads ".frac" as the same value.
fn scan_decimal(digits: []const u8) ?Decimal {
    if (digits.len == 0 or digits.len > read_digits_len_max + 1) return null;
    var magnitude: u64 = 0;
    var point: ?usize = null;
    for (digits, 0..) |character, index| {
        const digit = character -% '0';
        if (digit < decimal_base) {
            // 20 digits with no point wrap, and the count check below refuses them.
            magnitude = magnitude *% decimal_base +% digit;
        } else if (character == '.' and point == null) {
            point = index;
        } else return null;
    }
    const fraction_len = if (point) |index| digits.len - index - 1 else 0;
    if (point != null and fraction_len == 0) return null;
    if (digits.len - @intFromBool(point != null) > read_digits_len_max) return null;
    return .{ .magnitude = magnitude, .fraction_len = fraction_len };
}

/// Reads `octets` as m / 10^k when it is "-int.frac" with m and 10^k exact in `V`, the form JSON
/// writers give a short decimal. Gives null for any other text, which the caller reads with the
/// standard library's parser, so the two agree.
pub fn parse_exact(comptime V: type, octets: []const u8) ?V {
    comptime assert(V == f32 or V == f64);
    const negative = octets.len != 0 and octets[0] == '-';
    const decimal = scan_decimal(octets[@intFromBool(negative)..]) orelse return null;
    const powers = comptime exact_powers_of_ten(V);
    const significand_max = 1 << (std.math.floatMantissaBits(V) + 1);
    if (decimal.magnitude > significand_max or decimal.fraction_len >= powers.len) return null;
    const value = @as(V, @floatFromInt(decimal.magnitude)) / powers[decimal.fraction_len];
    return if (negative) -value else value;
}
