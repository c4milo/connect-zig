//! The server side of the in-memory rounds: colibri's `server.Engine` over the links of `link.zig`
//! and `link_datagram.zig`, with the example's route table. A program with sockets does the same
//! with its own: it accepts a socket, passes what the socket read and each datagram to the
//! endpoint, hands each event to the router, and writes what the endpoint owes.
//!
//! One endpoint serves every round. A TCP connection runs in cleartext, h2 with prior knowledge
//! or h11 (decision 13). A QUIC connection speaks h3 under the test identity of `tls/` (decision
//! 25).
const std = @import("std");
const server = @import("connect_zig").server;
const tls = @import("connect_zig").tls;
const identity = @import("test_identity");
const constants = @import("constants.zig");
const Link = @import("link.zig").Link;
const datagram_module = @import("link_datagram.zig");
const DatagramLink = datagram_module.DatagramLink;

/// Room for the DER of the chain.
const chain_der_len = constants.der_len_max(identity.chain_pem.len);
/// Unix seconds, which a program reads from its clock; colibri reads no clock. The certificates
/// are valid at this instant.
pub const now_seconds = identity.now_seconds;

const client_address: server.Address = .init(&constants.loopback, constants.client_port);

/// What a program probes once and passes every TLS configuration: here no CPU feature is known
/// and the thread's timing mode is not stated, so each session runs ChaCha20 alone.
pub const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .sve2 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known, .midr = null },
    .timing = .not_stated,
};

pub const Error = error{ CallWrong, SendUnfinished };

/// A program's route table and the `App` its routes take, as the server sees them: two pointers
/// and the function that joins them, so the server's type does not name the program's types, as
/// colibri's own `erased.Router` does.
pub const RouterRef = struct {
    router: *anyopaque,
    app: *anyopaque,
    handle_fn: *const fn (router: *anyopaque, app: *anyopaque, endpoint: *Endpoint, event: *const server.Event) server.Handled,

    /// Keeps `router`, a pointer to the program's `server.Router`, and `app`, a pointer to the
    /// state its routes take.
    pub fn of(router: anytype, app: anytype) RouterRef {
        const Router = @typeInfo(@TypeOf(router)).pointer.child;
        const App = @typeInfo(@TypeOf(app)).pointer.child;
        const Calls = struct {
            fn handle(erased_router: *anyopaque, erased_app: *anyopaque, endpoint: *Endpoint, event: *const server.Event) server.Handled {
                const typed: *Router = @ptrCast(@alignCast(erased_router));
                const typed_app: *App = @ptrCast(@alignCast(erased_app));
                return typed.handle(typed_app, endpoint, event);
            }
        };
        return .{ .router = @ptrCast(router), .app = @ptrCast(app), .handle_fn = Calls.handle };
    }

    pub fn handle(self: RouterRef, endpoint: *Endpoint, event: *const server.Event) server.Handled {
        return self.handle_fn(self.router, self.app, endpoint, event);
    }
};

/// One TCP connection and one QUIC connection at a time: each round opens one.
pub const Endpoint = server.Engine(.{ .tcp_connections = 1, .quic_connections = 1, .receive_pool_len = constants.receive_pool_len });

/// The server of one program's rounds. It holds hundreds of kilobytes, so the program places it
/// where it allocates its state.
pub const ServerSide = struct {
    const Self = @This();

    link: *Link,
    datagram_link: *DatagramLink,
    output: [constants.server_output_len]u8,
    datagram_output: [datagram_module.datagram_len_max]u8,
    chain_der: [chain_der_len]u8,
    chain_room: [tls.constants.limits.certificate_chain_len_max][]const u8,
    key: tls.Key,
    identities: [1]tls.Identity,
    cookie_key: [tls.constants.protocol.server_key_len]u8,
    ticket_key: [tls.constants.protocol.server_key_len]u8,
    config: server.Config,
    endpoint: Endpoint,
    /// What each `receive` reports, kept beside the endpoint so no event is copied out of a
    /// returned value (colibri decision 165).
    received: server.ReceiveResult,
    router: RouterRef,
    accepted: ?server.ConnectionHandle,
    /// The connections that ended, TCP and QUIC alike: a round is over once one more ended.
    ended_count: u32,
    prng: std.Random.DefaultPrng,

    /// Starts the endpoint. `cpu_features` are the program's, which its App holds: the engine's
    /// codecs run on them (colibri decision 169).
    pub fn init(self: *Self, link: *Link, datagram_link: *DatagramLink, router: RouterRef, cpu_features: server.CpuFeatures) !void {
        self.* = .{
            .link = link,
            .datagram_link = datagram_link,
            .output = undefined,
            .datagram_output = undefined,
            .chain_der = undefined,
            .chain_room = undefined,
            .key = .{},
            .identities = undefined,
            .cookie_key = undefined,
            .ticket_key = undefined,
            .config = .{ .cpu_features = cpu_features },
            .endpoint = undefined,
            .received = undefined,
            .router = router,
            .accepted = null,
            .ended_count = 0,
            .prng = .init(constants.server_seed),
        };
        self.prng.random().bytes(&self.cookie_key);
        self.prng.random().bytes(&self.ticket_key);
        // The chain, the end-entity first, and the P-256 key the end-entity certificate carries.
        const chain = try tls.pem.chain(identity.chain_pem, &self.chain_der, &self.chain_room);
        try tls.pem.key(cpu, identity.key_pem, chain[0], &self.key);
        self.identities[0] = .{ .chain = chain, .key = &self.key };
        // The identity serves QUIC, which names h3. A TCP socket the program accepts with `.tls =
        // false` stays in cleartext.
        self.config = .{ .cpu_features = cpu_features, .tls = .{
            .identities = &self.identities,
            .cookie_key = &self.cookie_key,
            .ticket_key = &self.ticket_key,
            .cpu = cpu,
        } };
        try self.endpoint.init(&self.config, self.prng.random(), .{ .unix_seconds = now_seconds, .monotonic_ns = link.now_ns(.server) });
    }

    /// Wipes the key's scalar, which no session uses any more.
    pub fn deinit(self: *Self) void {
        self.key.wipe();
    }

    /// Accepts the socket the client connected, in cleartext.
    pub fn accept(self: *Self) !void {
        self.accepted = self.endpoint.accept(.{ .tls = false }, self.link.now_ns(.server)) orelse return error.CallWrong;
    }

    /// One turn of the server: fire its deadlines, pass the endpoint what the socket read and
    /// each datagram, act on every event, and send every datagram it owes.
    pub fn turn(self: *Self) !void {
        const input = try self.link.receive(.server);
        const now_ns = self.link.now_ns(.server);
        self.endpoint.on_instant(now_ns);
        try self.read_stream(input, now_ns);
        try self.read_datagrams(now_ns);
        try self.serve_all(.none, now_ns);
        for (0..constants.datagrams_per_turn_max) |_| {
            const sent = self.endpoint.send_datagram(&self.datagram_output, now_ns) orelse break;
            try self.datagram_link.send(.server, sent.bytes);
        }
    }

    fn read_stream(self: *Self, input: []u8, now_ns: u64) !void {
        const connection = self.accepted orelse return;
        var consumed: usize = 0;
        for (0..constants.server_events_per_turn_max) |_| {
            const read: server.StreamBytes = .{ .connection = connection, .bytes = input[consumed..] };
            self.endpoint.receive(.{ .stream = read }, now_ns, &self.received);
            consumed += self.received.consumed;
            const event = if (self.received.event) |*reported| reported else {
                if (self.received.consumed == 0) break;
                continue;
            };
            try self.serve(event, now_ns);
        }
        self.link.consume(.server, consumed);
    }

    /// Passes the endpoint each datagram the UDP socket read, with the address it came from.
    fn read_datagrams(self: *Self, now_ns: u64) !void {
        for (0..constants.datagrams_per_turn_max) |_| {
            const datagram = try self.datagram_link.receive(.server) orelse break;
            try self.serve_all(.{ .datagram = .{ .bytes = datagram, .from = client_address } }, now_ns);
            self.datagram_link.consume(.server);
        }
    }

    /// Passes `input` to the endpoint, then takes every event it reports until it reports none.
    fn serve_all(self: *Self, input: server.Input, now_ns: u64) !void {
        var rest = input;
        for (0..constants.server_events_per_turn_max) |_| {
            self.endpoint.receive(rest, now_ns, &self.received);
            rest = .none;
            try self.serve(if (self.received.event) |*event| event else return, now_ns);
        }
    }

    fn serve(self: *Self, event: *const server.Event, now_ns: u64) !void {
        switch (self.router.handle(&self.endpoint, event)) {
            .taken => {},
            .event => |other| switch (other.*) {
                .send => |connection| try self.flush(connection, now_ns),
                .close => {},
                .ended => |over| {
                    if (over.failed) return error.CallWrong;
                    if (self.accepted == over.connection) self.accepted = null;
                    self.ended_count += 1;
                },
                else => return error.CallWrong,
            },
        }
    }

    fn flush(self: *Self, connection: server.ConnectionHandle, now_ns: u64) !void {
        for (0..constants.server_sends_per_event_max) |_| {
            const written = self.endpoint.send_stream(connection, &self.output, now_ns);
            try self.link.send(.server, self.output[0..written]);
            if (written < self.output.len) return;
        }
        return error.SendUnfinished;
    }

    /// The client closed its socket. A program learns it from a read of 0 octets, and the link
    /// has no such read, so the client's side says it here. The endpoint then ends the
    /// connection.
    pub fn peer_closed(self: *Self) void {
        const connection = self.accepted orelse return;
        self.endpoint.transport_closed(connection);
    }

    /// The connections that ended so far, over TCP and QUIC.
    pub fn ended(self: *const Self) u32 {
        return self.ended_count;
    }

    pub fn deadline_ns(self: *Self) ?u64 {
        return self.endpoint.deadline_ns();
    }
};
