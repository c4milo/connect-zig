//! The root of the service's unit tests.

test {
    _ = @import("service.zig");
    // The tests reach no colibri type, yet the binary links chapulin's objects. Naming colibri runs
    // its root, which keeps chapulin's hook, `ch_assert_fail`, beside them (colibri decision 172).
    _ = @import("connect_zig").colibri;
}
