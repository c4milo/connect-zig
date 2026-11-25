//! The root of the service's unit tests.

test {
    _ = @import("service.zig");
    // The tests reach no part of connect-zig, yet the binary links chapulin's objects through
    // stdx. Naming connect-zig reads its root, which reads stdx's, and stdx's root keeps chapulin's
    // hook, `ch_assert_fail`, beside them (decision 34 as amended).
    _ = @import("connect_zig");
}
