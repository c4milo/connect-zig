//! Request timeouts as nanoseconds: Connect's `Connect-Timeout-Ms` and gRPC's `grpc-timeout`.
//! The caller turns a timeout into a deadline with the instant it read from its own clock.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const protocol = constants.protocol;

pub const Error = error{InvalidTimeout};

/// Reads `Connect-Timeout-Ms`: a positive integer of at most 10 digits, in milliseconds (Connect
/// protocol, "Timeout").
pub fn parse_connect(value: []const u8) Error!u64 {
    // Connect protocol, "Timeout": at most 10 ASCII digits.
    if (value.len == 0 or value.len > constants.protocol.connect_timeout_digits_max) return error.InvalidTimeout;
    const millis = parse_digits(value) orelse return error.InvalidTimeout;
    return millis * protocol.nanos_per_milli;
}

/// Writes `Connect-Timeout-Ms` for a timeout of `nanos`, rounded up to a whole millisecond.
pub fn format_connect(nanos: u64, buffer: *[constants.protocol.connect_timeout_digits_max]u8) []const u8 {
    const millis = @min(std.math.divCeil(u64, nanos, protocol.nanos_per_milli) catch unreachable, protocol.connect_timeout_millis_max);
    return std.fmt.bufPrint(buffer, "{d}", .{millis}) catch unreachable;
}

const Unit = struct { suffix: u8, nanos: u64 };

/// The units of PROTOCOL-HTTP2.md's TimeoutUnit, from the finest.
const units = [_]Unit{
    .{ .suffix = 'n', .nanos = 1 },
    .{ .suffix = 'u', .nanos = protocol.nanos_per_micro },
    .{ .suffix = 'm', .nanos = protocol.nanos_per_milli },
    .{ .suffix = 'S', .nanos = protocol.nanos_per_second },
    .{ .suffix = 'M', .nanos = protocol.nanos_per_minute },
    .{ .suffix = 'H', .nanos = protocol.nanos_per_hour },
};

/// Reads `grpc-timeout`: at most 8 digits, then one unit of H, M, S, m, u or n.
pub fn parse_grpc(value: []const u8) Error!u64 {
    // PROTOCOL-HTTP2.md, "Timeout": TimeoutValue is a positive integer of at most 8 digits.
    // One digit and the unit at least.
    if (value.len <= 1 or value.len - 1 > protocol.grpc_timeout_digits_max) return error.InvalidTimeout;
    const amount = parse_digits(value[0 .. value.len - 1]) orelse return error.InvalidTimeout;
    for (units) |unit| {
        if (unit.suffix == value[value.len - 1]) return std.math.mul(u64, amount, unit.nanos) catch std.math.maxInt(u64);
    }
    return error.InvalidTimeout;
}

/// Writes `grpc-timeout` with the finest unit whose amount fits in 8 digits, rounded up.
pub fn format_grpc(nanos: u64, buffer: *[constants.protocol.grpc_timeout_digits_max + 1]u8) []const u8 {
    const digits_limit = protocol.grpc_timeout_amount_max;
    for (units) |unit| {
        const amount = std.math.divCeil(u64, nanos, unit.nanos) catch unreachable;
        if (amount <= digits_limit) return std.fmt.bufPrint(buffer, "{d}{c}", .{ amount, unit.suffix }) catch unreachable;
    }
    return std.fmt.bufPrint(buffer, "{d}H", .{digits_limit}) catch unreachable;
}

fn parse_digits(text: []const u8) ?u64 {
    assert(text.len <= constants.protocol.connect_timeout_digits_max);
    var value: u64 = 0;
    for (text) |octet| {
        if (octet < '0' or octet > '9') return null;
        value = value * protocol.decimal_base + (octet - '0');
    }
    return value;
}

const testing = std.testing;

test "Connect-Timeout-Ms is milliseconds of at most 10 digits" {
    try testing.expectEqual(@as(u64, 1_500_000_000), try parse_connect("1500"));
    try testing.expectError(error.InvalidTimeout, parse_connect("12345678901"));
    try testing.expectError(error.InvalidTimeout, parse_connect("-1"));
    var buffer: [10]u8 = undefined;
    try testing.expectEqualStrings("2", format_connect(1_000_001, &buffer));
}

test "grpc-timeout takes 8 digits and a unit, and writes the finest unit that fits" {
    try testing.expectEqual(@as(u64, 3_000_000_000), try parse_grpc("3S"));
    try testing.expectEqual(@as(u64, 7_200_000_000_000), try parse_grpc("2H"));
    try testing.expectError(error.InvalidTimeout, parse_grpc("123456789n"));
    try testing.expectError(error.InvalidTimeout, parse_grpc("10s"));
    var buffer: [9]u8 = undefined;
    try testing.expectEqualStrings("1500000u", format_grpc(1_500_000_000, &buffer));
    try testing.expectEqualStrings("250n", format_grpc(250, &buffer));
}
