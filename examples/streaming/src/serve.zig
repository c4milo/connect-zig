//! The streaming service, streaming.v1.StreamingService, on a socket, to play with:
//! `zig build serve -- [port]`, 8443 by default. It serves h11 and h2 over TLS on a TCP port, and
//! h3 on the UDP socket of the same port, under the test identity of the harness (decision 25).
//!
//! Each method is a stream, so each message of a Connect call goes in an envelope: one flags
//! octet, then the message's length in four octets, big-endian. buf curl writes the envelopes.
//! From the project's folder:
//!
//! ```sh
//! buf curl --schema proto --cacert ../harness/tls/ca.pem --data '{"from":3}' \
//!   https://127.0.0.1:8443/streaming.v1.StreamingService/Countdown
//! ```
const std = @import("std");
const harness = @import("harness");
const app_file = @import("app.zig");

comptime {
    _ = harness.hooks;
}

/// All the program holds, which `main` allocates once (decision 42).
const State = struct {
    app: app_file.App,
    served: harness.Served(app_file.App, app_file.Router),
};

pub fn main(init: std.process.Init) !void {
    const state = try init.arena.allocator().create(State);
    state.app = .{};
    try state.served.run(init, &state.app);
}
