//! chapulin's one hook, which a program that links colibri's `tls` defines (colibri decision 94).
//! A program exports it by referencing this file: `comptime { _ = @import("hooks.zig"); }`.
const std = @import("std");

fn assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) callconv(.c) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}

comptime {
    @export(&assert_fail, .{ .name = "ch_assert_fail", .linkage = .strong });
}
