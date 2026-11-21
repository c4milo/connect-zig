//! CEL's functions over values (CEL language definition, "List of Standard Definitions"): the
//! conversions and the functions of strings. Each has a result type for the operand types it
//! takes, and the code that gives its result. A function called on a target, `x.size()`, takes
//! the target as its first operand.
const std = @import("std");
const proto = @import("protobuf");
const constants = @import("../constants.zig");
const type_file = @import("cel_type.zig");
const Bytes = type_file.Bytes;
const Error = type_file.Error;
const Timestamp = proto.wkt.Timestamp;

/// One function for one list of operand types.
const Overload = struct { name: []const u8, operands: []const type, result: type };

const text = []const u8;

const overloads = [_]Overload{
    .{ .name = "size", .operands = &.{text}, .result = i64 },
    .{ .name = "size", .operands = &.{Bytes}, .result = i64 },
    .{ .name = "int", .operands = &.{i64}, .result = i64 },
    .{ .name = "int", .operands = &.{u64}, .result = i64 },
    .{ .name = "int", .operands = &.{f64}, .result = i64 },
    .{ .name = "int", .operands = &.{text}, .result = i64 },
    .{ .name = "int", .operands = &.{Timestamp}, .result = i64 },
    .{ .name = "uint", .operands = &.{i64}, .result = u64 },
    .{ .name = "uint", .operands = &.{u64}, .result = u64 },
    .{ .name = "uint", .operands = &.{f64}, .result = u64 },
    .{ .name = "uint", .operands = &.{text}, .result = u64 },
    .{ .name = "double", .operands = &.{i64}, .result = f64 },
    .{ .name = "double", .operands = &.{u64}, .result = f64 },
    .{ .name = "double", .operands = &.{f64}, .result = f64 },
    .{ .name = "double", .operands = &.{text}, .result = f64 },
    .{ .name = "string", .operands = &.{text}, .result = text },
    .{ .name = "string", .operands = &.{Bytes}, .result = text },
    .{ .name = "bytes", .operands = &.{text}, .result = Bytes },
    .{ .name = "bytes", .operands = &.{Bytes}, .result = Bytes },
    .{ .name = "bool", .operands = &.{bool}, .result = bool },
    .{ .name = "bool", .operands = &.{text}, .result = bool },
    .{ .name = "startsWith", .operands = &.{ text, text }, .result = bool },
    .{ .name = "endsWith", .operands = &.{ text, text }, .result = bool },
    .{ .name = "contains", .operands = &.{ text, text }, .result = bool },
};

/// The type `name` gives for operands of these types, or null when the module holds no such
/// function for them.
pub fn Result(comptime name: []const u8, comptime operands: []const type) ?type {
    for (overloads) |overload| {
        if (std.mem.eql(u8, overload.name, name) and same_types(overload.operands, operands)) return overload.result;
    }
    return null;
}

fn same_types(comptime left: []const type, comptime right: []const type) bool {
    if (left.len != right.len) return false;
    for (left, right) |L, R| {
        if (L != R) return false;
    }
    return true;
}

/// The result of `name` for `operands`, a tuple of the types `Result` took.
pub fn run(comptime name: []const u8, comptime R: type, operands: anytype) Error!R {
    const first = operands[0];
    if (comptime named(name, "size")) return size(first);
    if (comptime named(name, "int")) return to_int(first);
    if (comptime named(name, "uint")) return to_uint(first);
    if (comptime named(name, "double")) return to_double(first);
    if (comptime named(name, "string")) return to_string(first);
    if (comptime named(name, "bytes")) return .{ .octets = octets_of(first) };
    if (comptime named(name, "bool")) return to_bool(first);
    if (comptime named(name, "startsWith")) return std.mem.startsWith(u8, first, operands[1]);
    if (comptime named(name, "endsWith")) return std.mem.endsWith(u8, first, operands[1]);
    if (comptime named(name, "contains")) return std.mem.indexOf(u8, first, operands[1]) != null;
    comptime unreachable;
}

fn named(comptime name: []const u8, comptime other: []const u8) bool {
    return std.mem.eql(u8, name, other);
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

/// The whole part of a double as an `I`, when `I` holds it.
fn whole(comptime I: type, value: f64) Error!I {
    if (std.math.isNan(value)) return error.Unevaluable;
    const truncated = @trunc(value);
    // The type's least value is a power of two, which a double holds, and the first value
    // past its greatest one is too.
    const least: f64 = @floatFromInt(std.math.minInt(I));
    const past: f64 = @floatFromInt(@as(u128, std.math.maxInt(I)) + 1);
    if (truncated < least or truncated >= past) return error.Unevaluable;
    return @intFromFloat(truncated);
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

fn call(comptime name: []const u8, operands: anytype) Error!Result(name, &types_of(@TypeOf(operands))).? {
    return run(name, comptime Result(name, &types_of(@TypeOf(operands))).?, operands);
}

fn types_of(comptime Operands: type) [@typeInfo(Operands).@"struct".fields.len]type {
    var types: [@typeInfo(Operands).@"struct".fields.len]type = undefined;
    for (@typeInfo(Operands).@"struct".fields, 0..) |field, index| types[index] = field.type;
    return types;
}

fn str(comptime literal: []const u8) []const u8 {
    return literal;
}

test "size counts a string's code points and a bytes value's octets" {
    const two = 2;
    try testing.expectEqual(@as(i64, two), try call("size", .{str("\u{e9}a")}));
    try testing.expectEqual(@as(i64, 0), try call("size", .{str("")}));
    try testing.expectEqual(@as(i64, two + 1), try call("size", .{Bytes{ .octets = "\u{e9}a" }}));
    try testing.expectError(error.Unevaluable, call("size", .{str("\xff")}));
    try testing.expect(comptime Result("size", &.{i64}) == null);
    try testing.expect(comptime Result("size", &.{ []const u8, []const u8 }) == null);
}

test "a conversion to an integer fails for a value the type does not hold" {
    const seven = 7;
    try testing.expectEqual(@as(i64, seven), try call("int", .{@as(u64, seven)}));
    try testing.expectError(error.Unevaluable, call("int", .{@as(u64, std.math.maxInt(u64))}));
    try testing.expectEqual(@as(i64, -seven), try call("int", .{@as(f64, -7.9)}));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try call("int", .{@as(f64, -0x1p63)}));
    try testing.expectError(error.Unevaluable, call("int", .{@as(f64, 0x1p63)}));
    try testing.expectError(error.Unevaluable, call("int", .{std.math.nan(f64)}));
    try testing.expectEqual(@as(i64, -seven), try call("int", .{str("-7")}));
    try testing.expectError(error.Unevaluable, call("int", .{str("7.5")}));
    try testing.expectEqual(@as(i64, seven), try call("int", .{Timestamp{ .seconds = seven, .nanos = 1 }}));
    try testing.expectEqual(@as(i64, seven), try call("int", .{@as(i64, seven)}));
    try testing.expectEqual(@as(u64, seven), try call("uint", .{@as(i64, seven)}));
    try testing.expectError(error.Unevaluable, call("uint", .{@as(i64, -1)}));
    try testing.expectEqual(@as(u64, seven), try call("uint", .{@as(f64, 7.9)}));
    try testing.expectError(error.Unevaluable, call("uint", .{@as(f64, -1)}));
    try testing.expectError(error.Unevaluable, call("uint", .{@as(f64, 0x1p64)}));
    try testing.expectEqual(@as(u64, seven), try call("uint", .{str("7")}));
    try testing.expectError(error.Unevaluable, call("uint", .{str("-7")}));
    try testing.expectEqual(@as(u64, seven), try call("uint", .{@as(u64, seven)}));
}

test "a conversion to a double, a string, bytes or a bool reads each type it takes" {
    try testing.expectEqual(@as(f64, -1), try call("double", .{@as(i64, -1)}));
    try testing.expectEqual(@as(f64, 1), try call("double", .{@as(u64, 1)}));
    try testing.expectEqual(@as(f64, 1.5), try call("double", .{str("1.5")}));
    try testing.expectEqual(@as(f64, 1.5), try call("double", .{@as(f64, 1.5)}));
    try testing.expectError(error.Unevaluable, call("double", .{str("one")}));
    try testing.expectEqualStrings("ab", try call("string", .{Bytes{ .octets = "ab" }}));
    try testing.expectEqualStrings("ab", try call("string", .{str("ab")}));
    try testing.expectError(error.Unevaluable, call("string", .{Bytes{ .octets = "\xff" }}));
    try testing.expectEqualStrings("ab", (try call("bytes", .{str("ab")})).octets);
    try testing.expectEqualStrings("ab", (try call("bytes", .{Bytes{ .octets = "ab" }})).octets);
    try testing.expect(try call("bool", .{str("true")}) and try call("bool", .{str("T")}) and try call("bool", .{true}));
    try testing.expect(!try call("bool", .{str("false")}) and !try call("bool", .{str("0")}));
    try testing.expectError(error.Unevaluable, call("bool", .{str("yes")}));
    try testing.expect(comptime Result("bool", &.{i64}) == null and Result("string", &.{i64}) == null);
    try testing.expect(comptime Result("int", &.{bool}) == null and Result("uint", &.{Timestamp}) == null);
}

test "a string starts with, ends with and contains another" {
    try testing.expect(try call("startsWith", .{ str("foobar"), str("foo") }));
    try testing.expect(!try call("startsWith", .{ str("foobar"), str("bar") }));
    try testing.expect(try call("endsWith", .{ str("foobar"), str("bar") }));
    try testing.expect(!try call("endsWith", .{ str("foobar"), str("foo") }));
    try testing.expect(try call("contains", .{ str("foobar"), str("oba") }));
    try testing.expect(!try call("contains", .{ str("foobar"), str("abo") }));
    try testing.expect(comptime Result("startsWith", &.{ i64, []const u8 }) == null);
    try testing.expect(comptime Result("contains", &.{[]const u8}) == null);
    try testing.expect(comptime Result("nothing", &.{[]const u8}) == null);
}
