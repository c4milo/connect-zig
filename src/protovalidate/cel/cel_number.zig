//! CEL's arithmetic and its order of numbers (CEL language definition, "Numeric Values" and
//! "Overflow"). An int or a uint operation whose result its type does not hold fails the run,
//! as a division by zero does. A double follows IEEE 754.
const std = @import("std");
const type_file = @import("cel_type.zig");
const Error = type_file.Error;

pub const Arithmetic = enum { add, subtract, multiply, divide, modulo };

/// `left op right` for two values of one numeric type.
pub fn compute(comptime T: type, comptime op: Arithmetic, left: T, right: T) Error!T {
    if (comptime T == f64) return compute_double(op, left, right);
    return switch (op) {
        .add => std.math.add(T, left, right) catch error.Unevaluable,
        .subtract => std.math.sub(T, left, right) catch error.Unevaluable,
        .multiply => std.math.mul(T, left, right) catch error.Unevaluable,
        .divide => divide(T, left, right),
        .modulo => modulo(T, left, right),
    };
}

fn compute_double(comptime op: Arithmetic, left: f64, right: f64) f64 {
    return switch (op) {
        .add => left + right,
        .subtract => left - right,
        .multiply => left * right,
        .divide => left / right,
        .modulo => unreachable,
    };
}

/// An integer division, which truncates toward zero.
fn divide(comptime T: type, left: T, right: T) Error!T {
    if (right == 0) return error.Unevaluable;
    // The least int divided by -1 is one more than the greatest int.
    return std.math.divTrunc(T, left, right) catch error.Unevaluable;
}

/// The remainder of the truncated division, with the sign of `left`.
fn modulo(comptime T: type, left: T, right: T) Error!T {
    if (right == 0) return error.Unevaluable;
    // The least int's remainder by -1 fails, as cel-go fails it, because the division it would
    // take overflows (docs/specs/README.md). Any other int's remainder by -1 is 0.
    if (comptime T == i64) {
        if (right == -1) return if (left == std.math.minInt(i64)) error.Unevaluable else 0;
    }
    return @rem(left, right);
}

/// `-value`. The least int has no negation.
pub fn negate(comptime T: type, value: T) Error!T {
    if (comptime T == f64) return -value;
    return std.math.negate(value) catch error.Unevaluable;
}

/// How `left` stands to `right`, by value across int, uint and double, or null when one is not
/// a number: NaN stands in no order to any value (CEL language definition, "Numbers").
pub fn order(left: anytype, right: anytype) ?std.math.Order {
    const L = @TypeOf(left);
    const R = @TypeOf(right);
    if (comptime L == f64 or R == f64) return order_double(left, right);
    if (comptime L == R) return std.math.order(left, right);
    // An int and a uint: 128 bits hold both.
    return std.math.order(@as(i128, left), @as(i128, right));
}

fn order_double(left: anytype, right: anytype) ?std.math.Order {
    const L = @TypeOf(left);
    const R = @TypeOf(right);
    if (comptime L == f64 and R == f64) {
        if (std.math.isNan(left) or std.math.isNan(right)) return null;
        return std.math.order(left, right);
    }
    if (comptime L == f64) return double_to_integer(left, R, right);
    const reversed = double_to_integer(right, L, left) orelse return null;
    return reversed.invert();
}

/// How a double stands to an integer, as cel-go orders them: a double past the integer type's
/// range by its sign, and one within it against the integer made a double, which rounds an
/// integer past 2^53. So `dyn(9223372036854775807) >= 9223372036854775808.0` holds, where a
/// continuous number line would put the integer below (docs/specs/README.md).
fn double_to_integer(double: f64, comptime I: type, integer: I) ?std.math.Order {
    if (std.math.isNan(double)) return null;
    const lowest: f64 = @floatFromInt(std.math.minInt(I));
    const highest: f64 = @floatFromInt(std.math.maxInt(I));
    if (double < lowest) return .lt;
    if (double > highest) return .gt;
    return std.math.order(double, @as(f64, @floatFromInt(integer)));
}

const testing = std.testing;
const least = std.math.minInt(i64);
const greatest = std.math.maxInt(i64);

test "an int operation fails when its result leaves the type, and by zero" {
    const seven = 7;
    const two = 2;
    try testing.expectEqual(@as(i64, seven + two), try compute(i64, .add, seven, two));
    try testing.expectEqual(@as(i64, seven - two), try compute(i64, .subtract, seven, two));
    try testing.expectEqual(@as(i64, seven * two), try compute(i64, .multiply, seven, two));
    try testing.expectEqual(@as(i64, seven / two), try compute(i64, .divide, seven, two));
    try testing.expectEqual(@as(i64, seven % two), try compute(i64, .modulo, seven, two));
    try testing.expectError(error.Unevaluable, compute(i64, .add, greatest, 1));
    try testing.expectError(error.Unevaluable, compute(i64, .subtract, least, 1));
    try testing.expectError(error.Unevaluable, compute(i64, .multiply, greatest, two));
    try testing.expectError(error.Unevaluable, compute(i64, .divide, seven, 0));
    try testing.expectError(error.Unevaluable, compute(i64, .modulo, seven, 0));
    try testing.expectError(error.Unevaluable, compute(i64, .divide, least, -1));
    try testing.expectError(error.Unevaluable, compute(i64, .modulo, least, -1));
    try testing.expectEqual(@as(i64, 0), try compute(i64, .modulo, least + 1, -1));
    try testing.expectEqual(@as(i64, 0), try compute(i64, .modulo, -seven, -1));
    // A division truncates toward zero, and a remainder takes the sign of its left side.
    try testing.expectEqual(@as(i64, -(seven / two)), try compute(i64, .divide, -seven, two));
    try testing.expectEqual(@as(i64, -(seven % two)), try compute(i64, .modulo, -seven, two));
    try testing.expectEqual(@as(i64, seven % two), try compute(i64, .modulo, seven, -two));
}

test "a uint does not go under zero, and a double follows IEEE 754" {
    try testing.expectError(error.Unevaluable, compute(u64, .subtract, 1, 2));
    try testing.expectError(error.Unevaluable, compute(u64, .add, std.math.maxInt(u64), 1));
    try testing.expectError(error.Unevaluable, compute(u64, .divide, 1, 0));
    try testing.expectError(error.Unevaluable, compute(u64, .modulo, 1, 0));
    try testing.expectEqual(@as(u64, 1), try compute(u64, .modulo, 3, 2));
    try testing.expect(std.math.isInf(try compute(f64, .divide, 1, 0)));
    try testing.expectEqual(@as(f64, 0.75), try compute(f64, .multiply, 1.5, 0.5));
    try testing.expectEqual(@as(f64, 1), try compute(f64, .subtract, 1.5, 0.5));
    try testing.expectEqual(@as(f64, 2), try compute(f64, .add, 1.5, 0.5));
}

test "a negation fails for the least int alone" {
    try testing.expectEqual(@as(i64, -1), try negate(i64, 1));
    try testing.expectEqual(@as(i64, greatest), try negate(i64, least + 1));
    try testing.expectError(error.Unevaluable, negate(i64, least));
    try testing.expectEqual(@as(f64, -0.5), try negate(f64, 0.5));
}

test "numbers of different types compare by value" {
    const Order = std.math.Order;
    try testing.expectEqual(@as(?Order, .lt), order(@as(i64, -1), @as(u64, 0)));
    try testing.expectEqual(@as(?Order, .gt), order(@as(u64, std.math.maxInt(u64)), @as(i64, greatest)));
    try testing.expectEqual(@as(?Order, .eq), order(@as(i64, 1), @as(u64, 1)));
    try testing.expectEqual(@as(?Order, .eq), order(@as(i64, 1), @as(i64, 1)));
    try testing.expectEqual(@as(?Order, .lt), order(@as(f64, 0.5), @as(f64, 1.5)));
    try testing.expectEqual(@as(?Order, null), order(std.math.nan(f64), @as(f64, 1)));
    try testing.expectEqual(@as(?Order, null), order(@as(i64, 1), std.math.nan(f64)));
    // A fraction decides between a double and the integer of its whole part.
    try testing.expectEqual(@as(?Order, .gt), order(@as(f64, 1.5), @as(i64, 1)));
    try testing.expectEqual(@as(?Order, .lt), order(@as(i64, 1), @as(f64, 1.5)));
    try testing.expectEqual(@as(?Order, .lt), order(@as(f64, -1.5), @as(i64, -1)));
    try testing.expectEqual(@as(?Order, .eq), order(@as(f64, 2), @as(u64, 2)));
    // A double past every integer is decided by its sign.
    try testing.expectEqual(@as(?Order, .gt), order(std.math.inf(f64), @as(u64, std.math.maxInt(u64))));
    try testing.expectEqual(@as(?Order, .lt), order(-std.math.inf(f64), @as(i64, least)));
    try testing.expectEqual(@as(?Order, .gt), order(@as(u64, 0), -std.math.inf(f64)));
    try testing.expectEqual(@as(?Order, .lt), order(@as(f64, -0.5), @as(u64, 0)));
}

test "an integer past 2^53 compares with a double as the double it rounds to" {
    const Order = std.math.Order;
    const two_to_63: f64 = 9223372036854775808.0;
    const two_to_53 = 9007199254740992;
    try testing.expectEqual(@as(?Order, .eq), order(two_to_63, @as(i64, greatest)));
    try testing.expectEqual(@as(?Order, .eq), order(@as(i64, greatest), two_to_63));
    try testing.expectEqual(@as(?Order, .eq), order(@as(i64, two_to_53 + 1), @as(f64, two_to_53)));
    try testing.expectEqual(@as(?Order, .gt), order(two_to_63 * 2, @as(i64, greatest)));
    try testing.expectEqual(@as(?Order, .eq), order(two_to_63 * 2, @as(u64, std.math.maxInt(u64))));
    try testing.expectEqual(@as(?Order, .gt), order(two_to_63 * 4, @as(u64, std.math.maxInt(u64))));
    try testing.expectEqual(@as(?Order, .lt), order(-two_to_63 * 2, @as(i64, least)));
}
