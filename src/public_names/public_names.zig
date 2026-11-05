//! A test-only check that a module's root exports exactly the names its list states, in the
//! pattern colibri's `core.public_names` follows (colibri decision 115). A name added to the root
//! and not to the list, or listed and missing, fails the test and prints the name.
const std = @import("std");

pub fn expect(comptime Root: type, comptime names: []const []const u8) !void {
    const difference = comptime first_difference(Root, names);
    const name = difference orelse return;
    std.debug.print("public names differ at: {s}\n", .{name});
    return error.PublicNamesDiffer;
}

/// The first name listed and missing from the root, or exported and not listed, or null.
pub fn first_difference(comptime Root: type, comptime names: []const []const u8) ?[]const u8 {
    @setEvalBranchQuota(names.len * names.len * name_len_max + branch_quota_base);
    inline for (names) |name| {
        if (!@hasDecl(Root, name)) return name;
    }
    inline for (comptime @typeInfo(Root).@"struct".decls) |decl| {
        if (!listed(names, decl.name)) return decl.name;
    }
    return null;
}

/// The longest public name the check compares, and the branches it needs beside the comparisons.
const name_len_max = 64;
const branch_quota_base = 10_000;

fn listed(comptime names: []const []const u8, comptime name: []const u8) bool {
    @setEvalBranchQuota(names.len * name_len_max + branch_quota_base);
    inline for (names) |each| {
        if (comptime std.mem.eql(u8, each, name)) return true;
    }
    return false;
}

test "the check passes on an exact list and names what differs otherwise" {
    const Root = struct {
        pub const a = 1;
        pub fn b() void {}
    };
    try expect(Root, &.{ "a", "b" });
    try std.testing.expectEqualStrings("b", comptime first_difference(Root, &.{"a"}).?);
    try std.testing.expectEqualStrings("c", comptime first_difference(Root, &.{ "a", "b", "c" }).?);
}
