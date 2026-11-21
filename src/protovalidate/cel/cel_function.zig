//! CEL's functions over values (CEL language definition, "Types and Conversions", "String
//! Functions" and "Bytes Functions"): the conversions and the functions of strings. Each has a result type for the operand types it
//! takes, and the code that gives its result. A function called on a target, `x.size()`, takes
//! the target as its first operand.
const std = @import("std");
const proto = @import("protobuf");
const constants = @import("../constants.zig");
const type_file = @import("cel_type.zig");
const library = @import("cel_library.zig");
const Function = @import("cel_node.zig").Function;
const Bytes = type_file.Bytes;
const Error = type_file.Error;
const Timestamp = proto.wkt.Timestamp;

/// One list of operand types a function takes, and the type it gives for them.
const Overload = struct { operands: []const type, result: type };

const text = []const u8;

/// The overloads of `function`. A switch finds a function's own in one step, so the compiler
/// compares the operands of a few overloads and no name.
fn overloads_of(comptime function: Function) []const Overload {
    return switch (function) {
        .size => &.{ .{ .operands = &.{text}, .result = i64 }, .{ .operands = &.{Bytes}, .result = i64 } },
        .int => &.{
            .{ .operands = &.{i64}, .result = i64 },       .{ .operands = &.{u64}, .result = i64 },
            .{ .operands = &.{f64}, .result = i64 },       .{ .operands = &.{text}, .result = i64 },
            .{ .operands = &.{Timestamp}, .result = i64 },
        },
        .uint => &.{
            .{ .operands = &.{i64}, .result = u64 }, .{ .operands = &.{u64}, .result = u64 },
            .{ .operands = &.{f64}, .result = u64 }, .{ .operands = &.{text}, .result = u64 },
        },
        .double => &.{
            .{ .operands = &.{i64}, .result = f64 }, .{ .operands = &.{u64}, .result = f64 },
            .{ .operands = &.{f64}, .result = f64 }, .{ .operands = &.{text}, .result = f64 },
        },
        .string => &.{ .{ .operands = &.{text}, .result = text }, .{ .operands = &.{Bytes}, .result = text } },
        .bytes => &.{ .{ .operands = &.{text}, .result = Bytes }, .{ .operands = &.{Bytes}, .result = Bytes } },
        .bool => &.{ .{ .operands = &.{bool}, .result = bool }, .{ .operands = &.{text}, .result = bool } },
        .startsWith, .endsWith, .contains => &.{.{ .operands = &.{ text, text }, .result = bool }},
        else => &.{},
    };
}

/// The type `function` gives for operands of these types, or null when the module holds no
/// such function for them.
pub fn Result(comptime function: Function, comptime operands: []const type) ?type {
    for (overloads_of(function)) |overload| {
        if (same_types(overload.operands, operands)) return overload.result;
    }
    // protovalidate's own functions, each of which gives a bool.
    return if (library.holds(function, operands)) bool else null;
}

fn same_types(comptime left: []const type, comptime right: []const type) bool {
    if (left.len != right.len) return false;
    for (left, right) |L, R| {
        if (L != R) return false;
    }
    return true;
}

/// The result of `function` for `operands`, a tuple of the types `Result` took.
pub fn run(comptime function: Function, comptime R: type, operands: anytype) Error!R {
    const first = operands[0];
    return switch (function) {
        .size => size(first),
        .int => to_int(first),
        .uint => to_uint(first),
        .double => to_double(first),
        .string => to_string(first),
        .bytes => .{ .octets = octets_of(first) },
        .bool => to_bool(first),
        .startsWith => std.mem.startsWith(u8, first, operands[1]),
        .endsWith => std.mem.endsWith(u8, first, operands[1]),
        .contains => std.mem.indexOf(u8, first, operands[1]) != null,
        else => library.run(function, operands),
    };
}

/// The types of a tuple's values.
fn types_of(comptime Operands: type) [@typeInfo(Operands).@"struct".fields.len]type {
    const fields = @typeInfo(Operands).@"struct".fields;
    var types = [_]type{void} ** fields.len;
    for (fields, 0..) |field, index| types[index] = field.type;
    return types;
}

fn octets_of(value: anytype) []const u8 {
    if (comptime @TypeOf(value) == Bytes) return value.octets;
    return value;
}

/// "size(string) -> int: string length" in code points, and "size(bytes)" in octets. A string
/// that is not UTF-8 has no count of code points.
fn size(value: anytype) Error!i64 {
    if (comptime @TypeOf(value) == Bytes) return @intCast(value.octets.len);
    const count = std.unicode.utf8CountCodepoints(value) catch return error.Unevaluable;
    return @intCast(count);
}

/// "int(...)": a uint or a double past the int range, and a string that is no int, fail. A
/// double loses its fraction ("rounds toward zero").
fn to_int(value: anytype) Error!i64 {
    return switch (@TypeOf(value)) {
        i64 => value,
        u64 => std.math.cast(i64, value) orelse error.Unevaluable,
        f64 => whole(i64, value),
        Timestamp => value.seconds,
        else => std.fmt.parseInt(i64, value, constants.decimal_base) catch error.Unevaluable,
    };
}

fn to_uint(value: anytype) Error!u64 {
    return switch (@TypeOf(value)) {
        u64 => value,
        i64 => std.math.cast(u64, value) orelse error.Unevaluable,
        f64 => whole(u64, value),
        else => std.fmt.parseInt(u64, value, constants.decimal_base) catch error.Unevaluable,
    };
}

/// The whole part of a double as an `I`: "rounds toward zero, errors if out of range" (CEL
/// language definition, "Types and Conversions"). An int takes no double at or below its
/// least value: "Double to int conversions are limited to (minInt, maxInt) non-inclusive"
/// ("Overflow"). The definition does not say whether -0.5 is in a uint's range. cel-go takes
/// no double below zero, and this module follows it.
fn whole(comptime I: type, value: f64) Error!I {
    if (std.math.isNan(value)) return error.Unevaluable;
    // The type's least value is a power of two, which a double holds, and the first value
    // past its greatest one is too.
    const least: f64 = @floatFromInt(std.math.minInt(I));
    const past: f64 = @floatFromInt(@as(u128, std.math.maxInt(I)) + 1);
    const below = if (I == u64) value < least else value <= least;
    if (below or value >= past) return error.Unevaluable;
    return @intFromFloat(@trunc(value));
}

fn to_double(value: anytype) Error!f64 {
    return switch (@TypeOf(value)) {
        f64 => value,
        i64, u64 => @floatFromInt(value),
        else => std.fmt.parseFloat(f64, value) catch error.Unevaluable,
    };
}

/// "string(bytes)": the octets, when they are UTF-8.
fn to_string(value: anytype) Error![]const u8 {
    if (comptime @TypeOf(value) != Bytes) return value;
    if (!std.unicode.utf8ValidateSlice(value.octets)) return error.Unevaluable;
    return value.octets;
}

/// "bool(string)": the words Go's strconv.ParseBool reads, as cel-go does.
fn to_bool(value: anytype) Error!bool {
    if (comptime @TypeOf(value) == bool) return value;
    for ([_][]const u8{ "1", "t", "T", "TRUE", "true", "True" }) |word| {
        if (std.mem.eql(u8, value, word)) return true;
    }
    for ([_][]const u8{ "0", "f", "F", "FALSE", "false", "False" }) |word| {
        if (std.mem.eql(u8, value, word)) return false;
    }
    return error.Unevaluable;
}

const testing = std.testing;

fn call(comptime function: Function, operands: anytype) Error!Result(function, &types_of(@TypeOf(operands))).? {
    return run(function, comptime Result(function, &types_of(@TypeOf(operands))).?, operands);
}

fn str(comptime literal: []const u8) []const u8 {
    return literal;
}

test "size counts a string's code points and a bytes value's octets" {
    const two = 2;
    try testing.expectEqual(@as(i64, two), try call(.size, .{str("\u{e9}a")}));
    try testing.expectEqual(@as(i64, 0), try call(.size, .{str("")}));
    try testing.expectEqual(@as(i64, two + 1), try call(.size, .{Bytes{ .octets = "\u{e9}a" }}));
    try testing.expectError(error.Unevaluable, call(.size, .{str("\xff")}));
    try testing.expect(comptime Result(.size, &.{i64}) == null);
    try testing.expect(comptime Result(.size, &.{ []const u8, []const u8 }) == null);
}

test "a conversion to an integer fails for a value the type does not hold" {
    const seven = 7;
    try testing.expectEqual(@as(i64, seven), try call(.int, .{@as(u64, seven)}));
    try testing.expectError(error.Unevaluable, call(.int, .{@as(u64, std.math.maxInt(u64))}));
    try testing.expectEqual(@as(i64, -seven), try call(.int, .{@as(f64, -7.9)}));
    // cel-go takes no double at or below the least int, and the next double above it is whole.
    try testing.expectError(error.Unevaluable, call(.int, .{@as(f64, -0x1p63)}));
    try testing.expectEqual(@as(i64, -0x7ffffffffffffc00), try call(.int, .{@as(f64, -0x1.fffffffffffffp62)}));
    try testing.expectError(error.Unevaluable, call(.int, .{-std.math.inf(f64)}));
    try testing.expectError(error.Unevaluable, call(.int, .{@as(f64, 0x1p63)}));
    try testing.expectError(error.Unevaluable, call(.int, .{std.math.nan(f64)}));
    try testing.expectEqual(@as(i64, -seven), try call(.int, .{str("-7")}));
    try testing.expectError(error.Unevaluable, call(.int, .{str("7.5")}));
    try testing.expectEqual(@as(i64, seven), try call(.int, .{Timestamp{ .seconds = seven, .nanos = 1 }}));
    try testing.expectEqual(@as(i64, seven), try call(.int, .{@as(i64, seven)}));
    try testing.expectEqual(@as(u64, seven), try call(.uint, .{@as(i64, seven)}));
    try testing.expectError(error.Unevaluable, call(.uint, .{@as(i64, -1)}));
    try testing.expectEqual(@as(u64, seven), try call(.uint, .{@as(f64, 7.9)}));
    try testing.expectError(error.Unevaluable, call(.uint, .{@as(f64, -1)}));
    // A uint takes no double below zero, whatever its whole part, and takes the zero below.
    try testing.expectError(error.Unevaluable, call(.uint, .{@as(f64, -0.5)}));
    try testing.expectEqual(@as(u64, 0), try call(.uint, .{@as(f64, -0.0)}));
    try testing.expectEqual(@as(u64, 0), try call(.uint, .{@as(f64, 0.5)}));
    try testing.expectError(error.Unevaluable, call(.uint, .{@as(f64, 0x1p64)}));
    try testing.expectEqual(@as(u64, seven), try call(.uint, .{str("7")}));
    try testing.expectError(error.Unevaluable, call(.uint, .{str("-7")}));
    try testing.expectEqual(@as(u64, seven), try call(.uint, .{@as(u64, seven)}));
}

test "a conversion to a double, a string, bytes or a bool reads each type it takes" {
    try testing.expectEqual(@as(f64, -1), try call(.double, .{@as(i64, -1)}));
    try testing.expectEqual(@as(f64, 1), try call(.double, .{@as(u64, 1)}));
    try testing.expectEqual(@as(f64, 1.5), try call(.double, .{str("1.5")}));
    try testing.expectEqual(@as(f64, 1.5), try call(.double, .{@as(f64, 1.5)}));
    try testing.expectError(error.Unevaluable, call(.double, .{str("one")}));
    try testing.expectEqualStrings("ab", try call(.string, .{Bytes{ .octets = "ab" }}));
    try testing.expectEqualStrings("ab", try call(.string, .{str("ab")}));
    try testing.expectError(error.Unevaluable, call(.string, .{Bytes{ .octets = "\xff" }}));
    try testing.expectEqualStrings("ab", (try call(.bytes, .{str("ab")})).octets);
    try testing.expectEqualStrings("ab", (try call(.bytes, .{Bytes{ .octets = "ab" }})).octets);
    try testing.expect(try call(.bool, .{str("true")}) and try call(.bool, .{str("T")}) and try call(.bool, .{true}));
    try testing.expect(!try call(.bool, .{str("false")}) and !try call(.bool, .{str("0")}));
    try testing.expectError(error.Unevaluable, call(.bool, .{str("yes")}));
    try testing.expect(comptime Result(.bool, &.{i64}) == null and Result(.string, &.{i64}) == null);
    try testing.expect(comptime Result(.int, &.{bool}) == null and Result(.uint, &.{Timestamp}) == null);
}

test "a string starts with, ends with and contains another" {
    try testing.expect(try call(.startsWith, .{ str("foobar"), str("foo") }));
    try testing.expect(!try call(.startsWith, .{ str("foobar"), str("bar") }));
    try testing.expect(try call(.endsWith, .{ str("foobar"), str("bar") }));
    try testing.expect(!try call(.endsWith, .{ str("foobar"), str("foo") }));
    try testing.expect(try call(.contains, .{ str("foobar"), str("oba") }));
    try testing.expect(!try call(.contains, .{ str("foobar"), str("abo") }));
    try testing.expect(comptime Result(.startsWith, &.{ i64, []const u8 }) == null);
    try testing.expect(comptime Result(.contains, &.{[]const u8}) == null);
    try testing.expect(comptime Result(.unknown, &.{[]const u8}) == null);
}
