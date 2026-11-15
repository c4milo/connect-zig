//! chapulin's one hook, which a program that links colibri's `tls` defines (README, "Add the
//! package").
const std = @import("std");

export fn ch_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}
