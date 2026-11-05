const std = @import("std");
const builtin = @import("builtin");

/// chapulin's one hook, which a program that links colibri's `tls` defines (colibri decision
/// 94). The module's own test binary defines it here; a program defines its own.
fn test_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) callconv(.c) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}

comptime {
    if (builtin.is_test) @export(&test_assert_fail, .{ .name = "ch_assert_fail", .linkage = .strong });
}

test {}
