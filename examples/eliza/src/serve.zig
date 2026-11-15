//! ELIZA on a socket, to play with: `zig build serve -- [port]`, 8443 by default. It serves
//! h11 and h2 over TLS on a TCP port, and h3 on the UDP socket of the same port, under the test
//! identity of the harness (decision 25). README.md gives curl and buf curl commands.
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
