//! The calculator service, errors.v1.CalculatorService, on a socket, to play with:
//! `zig build serve -- [port]`, 8443 by default. It serves h11 and h2 over TLS on a TCP port, and
//! h3 on the UDP socket of the same port, under the test identity of the harness (decision 25).
//!
//! Divide answers the quotient and the remainder. A divisor of 0 fails with invalid_argument and
//! a `DivisionByZero` detail, which the Connect error body holds in base64. From the project's
//! folder:
//!
//! ```sh
//! curl --cacert ../harness/tls/ca.pem --json '{"dividend":7,"divisor":0}' \
//!   https://127.0.0.1:8443/errors.v1.CalculatorService/Divide
//! ```
const std = @import("std");
const harness = @import("harness");
const app_file = @import("app.zig");

/// All the program holds, which `main` allocates once (decision 42).
const State = struct {
    app: app_file.App,
    served: harness.Served(app_file.App, app_file.Router),
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    // The program detects the CPU's features once, as it starts.
    state.app = .{ .cpu_features = .detect() };
    try state.served.run(init, &state.app);
}
