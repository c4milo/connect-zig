//! The functions protovalidate adds to CEL (validate.proto's "Protovalidate functions", and the
//! library each implementation holds): the checks of a string's form, over the format files
//! that the standard rules call too.
const std = @import("std");
const format_name = @import("../format_name.zig");
const format_ip = @import("../format_ip.zig");
const format_uri = @import("../format_uri.zig");
const type_file = @import("cel_type.zig");
const Error = type_file.Error;

const text = []const u8;

/// One function for one list of operand types. Each gives a bool.
const Overload = struct { name: []const u8, operands: []const type };

const overloads = [_]Overload{
    .{ .name = "isEmail", .operands = &.{text} },
    .{ .name = "isHostname", .operands = &.{text} },
    .{ .name = "isUri", .operands = &.{text} },
    .{ .name = "isUriRef", .operands = &.{text} },
    .{ .name = "isHostAndPort", .operands = &.{ text, bool } },
    .{ .name = "isIp", .operands = &.{text} },
    .{ .name = "isIp", .operands = &.{ text, i64 } },
    .{ .name = "isIpPrefix", .operands = &.{text} },
    .{ .name = "isIpPrefix", .operands = &.{ text, i64 } },
    .{ .name = "isIpPrefix", .operands = &.{ text, bool } },
    .{ .name = "isIpPrefix", .operands = &.{ text, i64, bool } },
    .{ .name = "isNan", .operands = &.{f64} },
    .{ .name = "isInf", .operands = &.{f64} },
    .{ .name = "isInf", .operands = &.{ f64, i64 } },
};

/// Whether the library holds `name` for operands of these types.
pub fn holds(comptime name: []const u8, comptime operands: []const type) bool {
    for (overloads) |overload| {
        if (std.mem.eql(u8, overload.name, name) and same_types(overload.operands, operands)) return true;
    }
    return false;
}

fn same_types(comptime left: []const type, comptime right: []const type) bool {
    if (left.len != right.len) return false;
    for (left, right) |L, R| {
        if (L != R) return false;
    }
    return true;
}

fn named(comptime name: []const u8, comptime other: []const u8) bool {
    return std.mem.eql(u8, name, other);
}

/// The result of `name` for `operands`, a tuple of the types `holds` took.
pub fn run(comptime name: []const u8, operands: anytype) bool {
    const first = operands[0];
    if (comptime named(name, "isEmail")) return format_name.is_email(first);
    if (comptime named(name, "isHostname")) return format_name.is_hostname(first);
    if (comptime named(name, "isUri")) return format_uri.is_uri(first);
    if (comptime named(name, "isUriRef")) return format_uri.is_uri_ref(first);
    if (comptime named(name, "isHostAndPort")) return format_name.is_host_and_port(first, operands[1]);
    if (comptime named(name, "isNan")) return std.math.isNan(first);
    if (comptime named(name, "isInf")) return is_inf(first, if (comptime operands.len == 1) 0 else operands[1]);
    return is_address(name, operands);
}

/// `isIp` and `isIpPrefix`. A version is 4 or 6, or 0 for either, and an address of any other
/// version is none. A prefix that is `strict` has no bit set after its length.
fn is_address(comptime name: []const u8, operands: anytype) bool {
    const Operands = @TypeOf(operands);
    const has_version = comptime operands.len > 1 and @TypeOf(operands[1]) == i64;
    const version = version_of(if (has_version) operands[1] else 0) orelse return false;
    if (comptime named(name, "isIp")) return format_ip.is_ip(operands[0], version);
    const strict = if (comptime @TypeOf(operands[operands.len - 1]) == bool) operands[operands.len - 1] else false;
    comptime std.debug.assert(named(name, "isIpPrefix") and @typeInfo(Operands).@"struct".fields.len <= 3);
    return format_ip.is_ip_prefix(operands[0], version, strict);
}

fn version_of(number: i64) ?format_ip.Version {
    return switch (number) {
        0 => .any,
        ip_version_4 => .v4,
        ip_version_6 => .v6,
        else => null,
    };
}

/// The versions of the Internet Protocol, as `isIp` takes them.
const ip_version_4 = 4;
const ip_version_6 = 6;

/// `isInf(sign)`: positive infinity for a sign above 0, negative for one below, either for 0.
fn is_inf(value: f64, sign: i64) bool {
    if (sign == 0) return std.math.isInf(value);
    return if (sign > 0) std.math.isPositiveInf(value) else std.math.isNegativeInf(value);
}

const testing = std.testing;

fn str(comptime literal: []const u8) []const u8 {
    return literal;
}

test "a string's form is checked by the function of its name" {
    try testing.expect(run("isEmail", .{str("ada@example.com")}) and !run("isEmail", .{str("ada")}));
    try testing.expect(run("isHostname", .{str("example.com")}) and !run("isHostname", .{str("-a")}));
    try testing.expect(run("isUri", .{str("https://example.com/a")}) and !run("isUri", .{str("/a")}));
    try testing.expect(run("isUriRef", .{str("/a")}) and !run("isUriRef", .{str("a b")}));
    try testing.expect(run("isHostAndPort", .{ str("example.com:80"), true }) and !run("isHostAndPort", .{ str("example.com"), true }));
    try testing.expect(run("isHostAndPort", .{ str("example.com"), false }));
}

test "an address is of the version asked for, and a number that is no version finds none" {
    const v4: i64 = ip_version_4;
    const v6: i64 = ip_version_6;
    const other: i64 = 5;
    const any: i64 = 0;
    try testing.expect(run("isIp", .{str("1.2.3.4")}) and run("isIp", .{str("::1")}) and !run("isIp", .{str("1.2.3")}));
    try testing.expect(run("isIp", .{ str("1.2.3.4"), v4 }) and !run("isIp", .{ str("1.2.3.4"), v6 }));
    try testing.expect(run("isIp", .{ str("::1"), v6 }) and !run("isIp", .{ str("::1"), v4 }));
    try testing.expect(run("isIp", .{ str("::1"), any }) and !run("isIp", .{ str("::1"), other }));
    try testing.expect(run("isIpPrefix", .{str("10.0.0.1/8")}) and !run("isIpPrefix", .{str("10.0.0.1")}));
    try testing.expect(run("isIpPrefix", .{ str("10.0.0.0/8"), v4 }) and !run("isIpPrefix", .{ str("10.0.0.0/8"), v6 }));
    try testing.expect(!run("isIpPrefix", .{ str("10.0.0.0/8"), other }));
    // A strict prefix has no bit set after its length.
    try testing.expect(run("isIpPrefix", .{ str("10.0.0.0/8"), true }) and !run("isIpPrefix", .{ str("10.0.0.1/8"), true }));
    try testing.expect(run("isIpPrefix", .{ str("10.0.0.1/8"), false }));
    try testing.expect(run("isIpPrefix", .{ str("::/64"), v6, true }) and !run("isIpPrefix", .{ str("::1/64"), v6, true }));
    try testing.expect(run("isIpPrefix", .{ str("::1/64"), v6, false }) and !run("isIpPrefix", .{ str("::/64"), v4, true }));
}

test "a double is not a number, or is an infinity of a sign" {
    const nan = std.math.nan(f64);
    const up = std.math.inf(f64);
    const one: i64 = 1;
    try testing.expect(run("isNan", .{nan}) and !run("isNan", .{up}) and !run("isNan", .{@as(f64, 0)}));
    try testing.expect(run("isInf", .{up}) and run("isInf", .{-up}) and !run("isInf", .{nan}) and !run("isInf", .{@as(f64, 1)}));
    try testing.expect(run("isInf", .{ up, one }) and !run("isInf", .{ -up, one }));
    try testing.expect(run("isInf", .{ -up, -one }) and !run("isInf", .{ up, -one }));
    try testing.expect(run("isInf", .{ up, @as(i64, 0) }) and run("isInf", .{ -up, @as(i64, 0) }));
}

test "the library takes each function with the operands it has" {
    try testing.expect(comptime holds("isEmail", &.{text}) and holds("isIp", &.{ text, i64 }) and holds("isIpPrefix", &.{ text, i64, bool }));
    try testing.expect(comptime !holds("isEmail", &.{i64}) and !holds("isEmail", &.{ text, text }) and !holds("isIp", &.{ text, bool }));
    try testing.expect(comptime !holds("isHostAndPort", &.{text}) and !holds("isNothing", &.{text}) and !holds("isIpPrefix", &.{ text, bool, i64 }));
}
