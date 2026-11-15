//! The root of the service's unit tests. colibri's `tls` links chapulin, so the test binary
//! defines chapulin's hook, as a program does (colibri decision 94).
const harness = @import("harness");

comptime {
    _ = harness.hooks;
}

test {
    _ = @import("service.zig");
}
