//! The signup service, signup.v1.SignupService, on a socket, to play with:
//! `zig build serve -- [port]`, 8443 by default. It serves h11 and h2 over TLS on a TCP port, and
//! h3 on the UDP socket of the same port, under the test identity of the harness (decision 25).
//!
//! `protovalidate.Interceptor` checks each request against the rules of signup.proto. From the
//! project's folder, an account that keeps them, and one that breaks two:
//!
//! ```sh
//! curl --cacert ../harness/tls/ca.pem --json '{"email":"ada@example.com","name":"Ada","age":36}' \
//!   https://127.0.0.1:8443/signup.v1.SignupService/Register
//! curl --cacert ../harness/tls/ca.pem --json '{"email":"ada","name":"Ada","age":7}' \
//!   https://127.0.0.1:8443/signup.v1.SignupService/Register
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
