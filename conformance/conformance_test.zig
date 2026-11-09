//! The conformance server's and client's unit tests, which `zig build test-conformance` runs.
//! The runner's reports in `tools/conformance_check.sh` test each program as a whole (design §8
//! step 7).
const std = @import("std");

/// The types an Any in a JSON message may name, as the server's root declares them.
pub const protobuf_any_types = @import("any_types.zig").types;

test {
    _ = @import("echo.zig");
    _ = @import("streams.zig");
    _ = @import("client_transport.zig");
    _ = @import("client_plan.zig");
    _ = @import("client_invoke.zig");
    _ = @import("client_reading.zig");
    _ = @import("client_result.zig");
    _ = @import("client_buffers.zig");
}
