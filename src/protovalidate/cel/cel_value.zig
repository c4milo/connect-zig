//! CEL's equality and order of two values (CEL language definition, "Equality" and "Ordering"),
//! and which pairs of types have them.
const std = @import("std");
const proto = @import("protobuf");
const type_file = @import("cel_type.zig");
const number = @import("cel_number.zig");
const Bytes = type_file.Bytes;
const Null = type_file.Null;
const Timestamp = proto.wkt.Timestamp;
const Duration = proto.wkt.Duration;

/// Whether `==` and `!=` take a `L` and a `R`: two values of one type, or a wrapper with null
/// or with the type it wraps. Two numbers of different types are not of one type:
/// "Type-checking asserts that arguments to equality operators must be the same type" (CEL
/// language definition, "Equality"), and "A == A -> bool" ("Comparison Operators").
pub fn equatable(comptime L: type, comptime R: type) bool {
    if (type_file.is_number(L) and type_file.is_number(R)) return L == R;
    if (@typeInfo(L) == .optional) return R == Null or equatable(@typeInfo(L).optional.child, R);
    if (@typeInfo(R) == .optional) return equatable(R, L);
    if (L != R) return false;
    return L == bool or L == []const u8 or L == Bytes or L == Null or L == Timestamp or L == Duration;
}

/// Whether a `L` and a `R` may be equal as an expression runs, which `dyn` leaves to the run:
/// "if at least one argument is dynamically typed, the type-checker considers all arguments
/// dynamic and defers type-agreement checks to the interpreter" (CEL language definition,
/// "Equality"). Two values that `==` takes may be equal, and two numbers of any numeric types
/// ("Numbers"). Any other pair is not equal: the section's last arm is `false`.
pub fn equal_as_they_run(comptime L: type, comptime R: type) bool {
    if (type_file.is_number(L) and type_file.is_number(R)) return true;
    if (@typeInfo(L) == .optional) return R == Null or equal_as_they_run(@typeInfo(L).optional.child, R);
    if (@typeInfo(R) == .optional) return equal_as_they_run(R, L);
    return equatable(L, R);
}

/// Whether `<`, `<=`, `>` and `>=` take a `L` and a `R`: two values of one ordered type (CEL
/// language definition, "Ordering" and "Comparison Operators"), and two numbers of any numeric
/// types. The definition orders numbers of two types as an expression runs. protovalidate's
/// CEL environment declares those overloads for the checker too (cel-go's
/// `CrossTypeNumericComparisons`), so `1 < 2u` is typed.
pub fn ordered(comptime L: type, comptime R: type) bool {
    if (type_file.is_number(L) and type_file.is_number(R)) return true;
    if (L != R) return false;
    return L == bool or L == []const u8 or L == Bytes or L == Timestamp or L == Duration;
}

pub fn equal(left: anytype, right: anytype) bool {
    const L = @TypeOf(left);
    const R = @TypeOf(right);
    if (comptime type_file.is_number(L) and type_file.is_number(R)) return number.order(left, right) == .eq;
    if (comptime @typeInfo(L) == .optional) return equal_wrapper(left, right);
    if (comptime @typeInfo(R) == .optional) return equal_wrapper(right, left);
    return switch (L) {
        bool => left == right,
        []const u8 => std.mem.eql(u8, left, right),
        Bytes => std.mem.eql(u8, left.octets, right.octets),
        Null => true,
        Timestamp, Duration => left.seconds == right.seconds and left.nanos == right.nanos,
        else => comptime unreachable,
    };
}

/// A wrapper that is not set equals null and another wrapper that is not set, and no value.
fn equal_wrapper(wrapper: anytype, other: anytype) bool {
    const Other = @TypeOf(other);
    if (comptime Other == Null) return wrapper == null;
    if (comptime @typeInfo(Other) != .optional) return equal(wrapper orelse return false, other);
    const set = wrapper orelse return other == null;
    return equal(set, other orelse return false);
}

/// How `left` stands to `right`, or null when a double is not a number.
pub fn order(left: anytype, right: anytype) ?std.math.Order {
    const L = @TypeOf(left);
    if (comptime type_file.is_number(L)) return number.order(left, right);
    return switch (L) {
        bool => std.math.order(@intFromBool(left), @intFromBool(right)),
        // A string's order is by code point, which UTF-8 keeps in its octets.
        []const u8 => std.mem.order(u8, left, right),
        Bytes => std.mem.order(u8, left.octets, right.octets),
        Timestamp, Duration => order_time(left, right),
        else => comptime unreachable,
    };
}

fn order_time(left: anytype, right: anytype) std.math.Order {
    const by_seconds = std.math.order(left.seconds, right.seconds);
    if (by_seconds != .eq) return by_seconds;
    return std.math.order(left.nanos, right.nanos);
}

const testing = std.testing;

fn text(comptime literal: []const u8) []const u8 {
    return literal;
}

test "values of one type are equal by value, and numbers across their types" {
    try testing.expect(equal(@as(i64, 1), @as(u64, 1)) and equal(@as(u64, 1), @as(f64, 1)));
    try testing.expect(!equal(@as(i64, -1), @as(u64, std.math.maxInt(u64))));
    try testing.expect(!equal(std.math.nan(f64), std.math.nan(f64)));
    try testing.expect(equal(true, true) and !equal(true, false));
    try testing.expect(equal(text("a"), text("a")) and !equal(text("a"), text("b")));
    try testing.expect(equal(Bytes{ .octets = "a" }, Bytes{ .octets = "a" }) and !equal(Bytes{ .octets = "a" }, Bytes{ .octets = "" }));
    try testing.expect(!equal(Bytes{ .octets = "a" }, Bytes{ .octets = "b" }));
    try testing.expect(equal(Null{}, Null{}));
    try testing.expect(equal(Timestamp{ .seconds = 1, .nanos = 2 }, Timestamp{ .seconds = 1, .nanos = 2 }));
    try testing.expect(!equal(Duration{ .seconds = 1, .nanos = 2 }, Duration{ .seconds = 1 }));
    try testing.expect(!equal(Duration{ .seconds = 1 }, Duration{ .seconds = 2 }));
}

test "a wrapper equals null when it is not set, and its value when it is" {
    const unset: ?i64 = null;
    const one: ?i64 = 1;
    try testing.expect(equal(unset, Null{}) and equal(Null{}, unset) and !equal(one, Null{}));
    try testing.expect(equal(one, @as(i64, 1)) and equal(@as(u64, 1), one) and !equal(one, @as(i64, 2)));
    try testing.expect(!equal(unset, @as(i64, 0)));
    try testing.expect(equal(unset, unset) and equal(one, one) and !equal(one, unset) and !equal(unset, one));
    try testing.expect(!equal(one, @as(?i64, 2)));
}

test "the pairs of types that compare" {
    try testing.expect(equatable(i64, i64) and equatable(bool, bool) and equatable(?i64, Null) and equatable(Null, ?i64));
    try testing.expect(equatable(?i64, i64) and equatable([]const u8, ?[]const u8) and equatable(?bool, ?bool));
    // Two numbers of different types are equal or not as they run, behind `dyn` alone.
    try testing.expect(!equatable(i64, f64) and !equatable(u64, i64) and !equatable(?i64, u64) and !equatable(f64, ?u64));
    try testing.expect(equal_as_they_run(i64, f64) and equal_as_they_run(?i64, u64) and equal_as_they_run(f64, ?u64) and equal_as_they_run(bool, bool));
    try testing.expect(!equal_as_they_run(i64, []const u8) and !equal_as_they_run(?i64, bool) and !equal_as_they_run(Null, bool));
    try testing.expect(!equatable(i64, []const u8) and !equatable(bool, Null) and !equatable(?i64, bool) and !equatable(*const u8, *const u8));
    try testing.expect(ordered(i64, u64) and ordered([]const u8, []const u8) and ordered(Duration, Duration));
    try testing.expect(!ordered(i64, bool) and !ordered(Null, Null) and !ordered(?i64, i64) and !ordered(Timestamp, Duration));
}

test "values of one type stand in their type's order" {
    const Order = std.math.Order;
    try testing.expectEqual(@as(?Order, .lt), order(@as(i64, 1), @as(f64, 1.5)));
    try testing.expectEqual(@as(?Order, .lt), order(false, true));
    try testing.expectEqual(@as(?Order, .gt), order(text("b"), text("a")));
    try testing.expectEqual(@as(?Order, .lt), order(text("a"), text("ab")));
    try testing.expectEqual(@as(?Order, .eq), order(Bytes{ .octets = "a" }, Bytes{ .octets = "a" }));
    try testing.expectEqual(@as(?Order, .lt), order(Bytes{ .octets = "a" }, Bytes{ .octets = "b" }));
    try testing.expectEqual(@as(?Order, .lt), order(Timestamp{ .seconds = 1 }, Timestamp{ .seconds = 2 }));
    try testing.expectEqual(@as(?Order, .gt), order(Duration{ .seconds = 1, .nanos = 2 }, Duration{ .seconds = 1, .nanos = 1 }));
    try testing.expectEqual(@as(?Order, .eq), order(Duration{ .seconds = 1 }, Duration{ .seconds = 1 }));
    try testing.expectEqual(@as(?Order, null), order(std.math.nan(f64), @as(i64, 1)));
}
