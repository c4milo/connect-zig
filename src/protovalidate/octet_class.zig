//! Sets of octets as tables the compiler builds, for the checks of a string's form that read
//! each octet: whether it is a letter, a digit or one of a few signs. A table read is one load,
//! where `std.mem.indexOfScalar` over the signs runs a search of its own for each octet.
const std = @import("std");

/// The octets of a table: each value of a `u8`.
const octet_count = std.math.maxInt(u8) + 1;

/// ASCII's letters and digits.
pub const alphanumeric = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// A table of the octets `members` holds: true at each of them.
fn table_of(comptime members: []const u8) [octet_count]bool {
    comptime {
        var table = [_]bool{false} ** octet_count;
        for (members) |member| table[member] = true;
        return table;
    }
}

/// Whether `octet` is one of `members`. The compiler builds one table for each set.
pub fn has(comptime members: []const u8, octet: u8) bool {
    const table = comptime table_of(members);
    return table[octet];
}

const testing = std.testing;

test "an octet is in a set when the set names it, and in no other" {
    const signs = "-._~";
    for (0..octet_count) |value| {
        const octet: u8 = @intCast(value);
        try testing.expectEqual(std.mem.indexOfScalar(u8, signs, octet) != null, has(signs, octet));
        try testing.expectEqual(std.ascii.isAlphanumeric(octet), has(alphanumeric, octet));
        try testing.expectEqual(std.ascii.isAlphanumeric(octet) or octet == '+', has(alphanumeric ++ "+", octet));
    }
    try testing.expect(!has("", 0) and has("\x00", 0) and has("\xff", 0xff) and !has("\xfe", 0xff));
}
