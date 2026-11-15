//! The examples' harness (decision 41): what the in-memory examples share, and what is not an
//! example. It stands where a program's sockets, certificate and clock would be: colibri's
//! in-memory links, a client and a server that run a round of calls over them in h11, h2 and h3,
//! the test identity of `tls/`, and chapulin's hook.
//!
//! A program allocates its `Rounds` once, with the rest of its state (decision 42):
//!
//! ```zig
//! const Rounds = harness.Rounds(App, Router);
//! try state.rounds.init(&state.app);
//! try state.rounds.begin(.{ .h11 = false, .h3 = false });
//! try state.rounds.request(&call.request, &call.response);
//! try state.rounds.finish(.h2);
//! ```
pub const Rounds = @import("rounds.zig").Rounds;
pub const Call = @import("call.zig").Call;
/// An example's routes on a real socket, which `zig build serve` runs.
pub const Served = @import("serve.zig").Served;
pub const Link = @import("link.zig").Link;
pub const DatagramLink = @import("link_datagram.zig").DatagramLink;

const client_side = @import("client_side.zig");
pub const CallBuffers = client_side.CallBuffers;
pub const ReadBuffers = client_side.ReadBuffers;
pub const Listener = client_side.Listener;
pub const Pool = client_side.Pool;
pub const expect_end = client_side.expect_end;
pub const expect_trailer = client_side.expect_trailer;

const server_side = @import("server_side.zig");
/// The CPU the harness's TLS sessions run on, which probes nothing.
pub const cpu = server_side.cpu;
/// The instant the harness judges certificates at, in Unix seconds.
pub const now_seconds = server_side.now_seconds;

/// chapulin's hook, which a program that links colibri's `tls` defines. A program exports it with
/// `comptime { _ = harness.hooks; }`.
pub const hooks = @import("hooks.zig");

pub const constants = @import("constants.zig");

// Each declaration but `hooks`: `connect_colibri` defines chapulin's hook in a test binary
// itself, so a second definition would collide.
test {
    _ = Rounds;
    _ = Call;
    _ = Served;
    _ = Link;
    _ = DatagramLink;
    _ = CallBuffers;
    _ = ReadBuffers;
    _ = Listener;
    _ = expect_end;
    _ = expect_trailer;
    _ = cpu;
    _ = now_seconds;
    _ = constants;
}
