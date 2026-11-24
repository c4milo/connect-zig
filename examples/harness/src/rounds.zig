//! The in-memory rounds of an example: a client and a server in one process, over the links of
//! `link.zig` and `link_datagram.zig`, which stand where sockets would be.
//!
//! A program allocates one `Rounds` with its state (decision 42), calls `init` once, then for
//! each round:
//!
//! 1. `begin` with the protocols the pool may speak: h3 alone, or h11 and h2 without h3;
//! 2. `request` for each call, with the colibri request and response of a `ClientCall`, or, for a
//!    streamed call, its `start` on `pool()` and then `listen`, which passes the call's events on
//!    as they arrive;
//! 3. `finish` with the protocol the round must speak, which runs client and server until every
//!    call finished and the connection closed;
//! 4. `read` on each client call, with `storage()`, to check what arrived.
const connect = @import("connect");
const client = @import("client");
const Link = @import("link.zig").Link;
const DatagramLink = @import("link_datagram.zig").DatagramLink;
const server_side = @import("server_side.zig");
const client_side = @import("client_side.zig");

/// The rounds of a program whose route table `Router` serves calls with `*App`. It holds a
/// megabyte and more, and points into itself, so it stays where the program placed it.
pub fn Rounds(comptime App: type, comptime Router: type) type {
    return struct {
        const Self = @This();

        link: Link,
        datagram_link: DatagramLink,
        router: Router,
        server: server_side.ServerSide,
        client: client_side.ClientSide,

        /// Starts both sides. The server's routes take `app`, which the program owns.
        pub fn init(self: *Self, app: *App) !void {
            try self.link.init();
            // The datagram link runs on the stream link's loops, so each side reads one clock.
            self.datagram_link.init(&self.link.loops);
            self.router.init();
            // Both sides state the CPU features the program detected once, which its App holds.
            try self.server.init(&self.link, &self.datagram_link, .of(&self.router, app), app.cpu_features);
            try self.client.init(&self.server, &self.link, &self.datagram_link, app.cpu_features);
        }

        pub fn deinit(self: *Self) void {
            self.server.deinit();
            self.link.deinit();
        }

        pub fn begin(self: *Self, protocols: client.Protocols) !void {
            try self.client.begin(protocols);
        }

        pub fn request(self: *Self, call_request: *client.Request, call_response: *client.Response) !void {
            try self.client.request(call_request, call_response);
        }

        /// The round's pool, which a streamed call's `start` takes.
        pub fn pool(self: *Self) *client_side.Pool {
            return &self.client.pool;
        }

        pub fn listen(self: *Self, listener: client_side.Listener) !void {
            try self.client.listen(listener);
        }

        /// The protocol the round's connection speaks, once it connected.
        pub fn protocol(self: *const Self) ?client.Protocol {
            return self.client.spoken;
        }

        pub fn finish(self: *Self, expected: client.Protocol) !void {
            try self.client.finish(expected);
        }

        /// Room for one response's strings, details and metadata. Each `read` reuses it, so a
        /// program checks one response before it reads the next.
        pub fn storage(self: *Self) connect.client.Storage {
            return self.client.read_buffers.storage();
        }
    };
}
