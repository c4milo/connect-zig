//! The Whoami service, interceptors.v1.WhoamiService, on a socket, to play with:
//! `zig build serve -- [port]`, 8443 by default. It serves h11 and h2 over TLS on a TCP port, and
//! h3 on the UDP socket of the same port, under the test identity of the harness (decision 25).
//!
//! Whoami answers with the name in the bearer token, and `Auth` refuses a call with no token. The
//! answer's `callsBefore` gives the calls that `Logging` counted before it. From the project's
//! folder:
//!
//! ```sh
//! curl --cacert ../harness/tls/ca.pem -H 'authorization: Bearer Ada' --json '{}' \
//!   https://127.0.0.1:8443/interceptors.v1.WhoamiService/Whoami
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
