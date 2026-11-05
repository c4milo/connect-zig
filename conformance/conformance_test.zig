//! The conformance server's unit tests, which `zig build test-conformance` runs. The runner's
//! report in `tools/conformance_check.sh` tests the server as a whole (design §8 step 7).
const std = @import("std");

/// The types an Any in a JSON message may name, as the server's root declares them.
pub const protobuf_any_types = @import("server.zig").protobuf_any_types;

test {
    _ = @import("echo.zig");
    _ = @import("streams.zig");
}
