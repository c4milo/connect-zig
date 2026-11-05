//! An HTTP server on Rotor's loop, which the example socket server and the conformance server
//! share (decision 26). It speaks h11 and h2 with prior knowledge on a TCP port, in cleartext.
//! With `quic_connections` set it also speaks h3 on the UDP port of the same number, under the
//! TLS identity the program puts in `config.tls` (decision 28).
//!
//! colibri does no I/O, so the program owns the sockets: it accepts, reads and writes through
//! Rotor, passes what each socket read to one `server.Endpoint`, and hands each event to the
//! router that connect_colibri's routes fill (design §8 step 5). It reads the clock once a turn,
//! through the loop, and passes the instant on.
//!
//! A program places one `SocketServer(App, Router, options)` in a container-level `var`, since it
//! holds every socket's buffers and must not move once it listens, and calls `serve`.
const std = @import("std");
const assert = std.debug.assert;
const rotor = @import("rotor");
const server = @import("server");
const Datagrams = @import("socket_datagram.zig").Datagrams;
const datagram_operations = @import("socket_datagram.zig").operations;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (decision 13).
    _ = @import("hooks.zig");
}

pub const Options = struct {
    /// The sockets the server holds at once.
    sockets_max: u32,
    /// The octets one socket reads, and writes, before the endpoint takes them.
    socket_buffer_len: usize,
    /// Whether each request's method and target go to stderr.
    log_requests: bool = true,
    /// colibri's deadlines for each connection: how long one may wait idle, among others.
    timeouts: server.Timeouts = .{},
    /// The QUIC connections the server holds at once: 0 serves no h3, and opens no UDP socket.
    quic_connections: u32 = 0,
};

/// The turns the server runs before it stops: as many as a `usize` counts.
const turns_max = std.math.maxInt(usize);
/// Events one input yields to the program, at most.
const events_per_input_max = 256;
/// The connections the kernel queues while every socket is taken.
const backlog = 64;
/// The instant, in seconds since the epoch, a cleartext endpoint starts at. It draws no secret,
/// so neither the instant nor the generator below needs to be real.
const now_seconds = 1_800_000_000;
const prng_seed = 0x656c697a61;
/// The operations each socket holds at once: a receive, a send, a shutdown and a close.
const operations_per_socket = 4;
/// How long a socket the server ends reads and drops what the peer still sends, after it shut
/// its own side, before it closes (RFC 9112 §9.6). A close with unread input sends a reset, which
/// can reach the peer before the response it is still reading.
const linger_ns = 2 * std.time.ns_per_s;

/// The low bits of an operation's user data name its kind, the next its socket, and the rest the
/// socket's generation, so the completion of an operation on a closed socket is dropped.
const Kind = enum(u2) { receive, send, shutdown, close };
const kind_bits = 2;
const index_bits = 8;
const accept_user_data: u64 = std.math.maxInt(u64);

pub fn SocketServer(comptime App: type, comptime Router: type, comptime options: Options) type {
    comptime assert(options.sockets_max > 0 and options.sockets_max <= 1 << index_bits);
    const quic = options.quic_connections > 0;
    const udp_operations = if (quic) datagram_operations else 0;
    const loop_options: rotor.Loop.Options = .{ .operations = options.sockets_max * operations_per_socket + 1 + udp_operations };
    const Endpoint = server.EndpointOf(.{ .tcp_connections = options.sockets_max, .quic_connections = options.quic_connections });

    const Socket = struct {
        live: bool = false,
        generation: u32 = 0,
        descriptor: rotor.Descriptor = undefined,
        connection: server.ConnectionHandle = undefined,
        receiving: bool = false,
        sending: bool = false,
        closing: bool = false,
        /// The endpoint said to close, or the peer closed: the socket closes once it sent its
        /// octets.
        close_wanted: bool = false,
        /// The server shut its side and drops what the peer still sends, until the peer closes
        /// or `linger_until_ns`.
        lingering: bool = false,
        linger_until_ns: u64 = 0,
        /// The peer closed its side, so nothing is left to drop.
        peer_done: bool = false,
        input: [options.socket_buffer_len]u8 = undefined,
        input_len: usize = 0,
        output: [options.socket_buffer_len]u8 = undefined,
        output_len: usize = 0,
        output_sent: usize = 0,
    };

    return struct {
        const Self = @This();
        /// Whether each request's method and target go to stderr.
        pub const log_requests = options.log_requests;
        /// Whether the server speaks h3 on a UDP socket.
        pub const speaks_h3 = quic;

        loop_memory: [rotor.Loop.memory_bytes(loop_options)]u8 align(rotor.memory_alignment) = undefined,
        loop: rotor.Loop = undefined,
        listener: rotor.Descriptor = undefined,
        accepting: bool = false,
        sockets: [options.sockets_max]Socket = @splat(.{}),
        events: [loop_options.operations]rotor.Event = undefined,
        config: server.Config = .{ .timeouts = options.timeouts },
        endpoint: Endpoint = undefined,
        router: Router = .{},
        prng: std.Random.DefaultPrng = .init(prng_seed),
        /// The source of the endpoint's connection IDs and of each TLS session's secrets. A
        /// cleartext server may leave it null: the seeded `prng` stands in, since it draws no
        /// secret. A server with `config.tls` set gives it the operating system's entropy.
        random: ?std.Random = null,
        /// The instant the endpoint starts at, in Unix seconds, which TLS tickets count from.
        now_seconds: u64 = now_seconds,
        datagrams: if (quic) Datagrams else void = if (quic) .{} else {},
        app: *App = undefined,

        /// Listens on 127.0.0.1 at `port`, 0 for one the kernel chooses, tells `listening` the
        /// port it bound with `listening.on_listening(port)`, and serves until the process ends.
        pub fn serve(self: *Self, app: *App, port: u16, listening: anytype) !void {
            self.app = app;
            self.listener = try rotor.sync.listen(&rotor.Address.ipv4(.{ 127, 0, 0, 1 }, port), .{ .backlog = backlog, .reuse_port = false });
            defer rotor.sync.close_now(self.listener);
            const bound = try rotor.sync.local_address(self.listener);
            try self.loop.init(&self.loop_memory, loop_options);
            defer self.loop.deinit();
            // RFC 9114 §3.1 finds an h3 endpoint on the UDP port of the TCP one.
            if (quic) try self.datagrams.open(&self.loop, rotor.Address.ipv4(.{ 127, 0, 0, 1 }, bound.port));
            try self.endpoint.init(&self.config, self.random orelse self.prng.random(), self.now_seconds, self.loop.now_ns());
            try listening.on_listening(bound.port);
            for (0..turns_max) |_| try turn(self);
        }
    };
}

fn turn(self: anytype) !void {
    arm(self, self.loop.now_ns());
    const wait = wait_ns(self, self.loop.now_ns());
    const count = try self.loop.tick(&self.events, wait);
    const now_ns = self.loop.now_ns();
    for (self.events[0..count]) |event| try take_event(self, event, now_ns);
    self.endpoint.on_instant(now_ns);
    for (&self.sockets) |*socket| {
        if (socket.live and !socket.closing and !socket.close_wanted) try serve_input(self, socket, now_ns);
    }
    try serve_events(self, .none, now_ns);
    // A response longer than a socket's output waits for the send before it; once that
    // send is done, the socket takes the rest.
    for (&self.sockets) |*socket| {
        if (socket.live and !socket.closing and !socket.close_wanted) flush(self, socket, now_ns);
    }
    if (comptime @TypeOf(self.*).speaks_h3) self.datagrams.send_owed(&self.loop, &self.endpoint, now_ns);
}

/// Passes a datagram the UDP socket read to the endpoint, in Rotor's own buffer, which QUIC
/// opens in place; every other event goes to `on_event`.
fn take_event(self: anytype, event: rotor.Event, now_ns: u64) !void {
    if (comptime !@TypeOf(self.*).speaks_h3) return on_event(self, event, now_ns);
    if (!Datagrams.owns(event.user_data)) return on_event(self, event, now_ns);
    defer self.datagrams.finish(&self.loop, event);
    const datagram = self.datagrams.arrived(&self.loop, event) orelse return;
    try serve_events(self, .{ .datagram = datagram }, now_ns);
}

/// How long the loop may wait: until the endpoint's next deadline or a lingering
/// socket's, at most.
fn wait_ns(self: anytype, now_ns: u64) u64 {
    var at: ?u64 = self.endpoint.deadline_ns();
    for (&self.sockets) |*socket| {
        if (!socket.live or !socket.lingering) continue;
        at = @min(at orelse socket.linger_until_ns, socket.linger_until_ns);
    }
    return @min(rotor.constants.wait_ns_max, (at orelse return rotor.constants.wait_ns_max) -| now_ns);
}

fn user_data(self: anytype, index: usize, kind: Kind) u64 {
    const socket = &self.sockets[index];
    return (@as(u64, socket.generation) << (kind_bits + index_bits)) | (@as(u64, index) << kind_bits) | @intFromEnum(kind);
}

fn submit(self: anytype, operation: rotor.Operation) void {
    const taken = self.loop.submit(&.{operation}, &.{});
    assert(taken == 1);
}

/// Starts each operation a socket waits for: an accept while a socket is free, a read
/// while a socket has room, a write of what the endpoint wrote, and a close once nothing
/// is owed.
fn arm(self: anytype, now_ns: u64) void {
    if (!self.accepting and free_index(
        self,
    ) != null) {
        submit(self, rotor.Operation.accept(accept_user_data, self.listener, false));
        self.accepting = true;
    }
    for (&self.sockets, 0..) |*socket, index| {
        if (socket.live and !socket.closing) arm_socket(self, socket, index, now_ns);
    }
}

fn arm_socket(self: anytype, socket: anytype, index: usize, now_ns: u64) void {
    const owes = socket.output_sent < socket.output_len;
    if (owes and !socket.sending) {
        submit(self, rotor.Operation.send(user_data(self, index, .send), socket.descriptor, socket.output[socket.output_sent..socket.output_len]));
        socket.sending = true;
    }
    if (socket.close_wanted and !owes and !socket.sending) return arm_close(self, socket, index, now_ns);
    if (!socket.receiving and !socket.close_wanted and socket.input_len < socket.input.len) {
        submit(self, rotor.Operation.receive(user_data(self, index, .receive), socket.descriptor, socket.input[socket.input_len..]));
        socket.receiving = true;
    }
}

/// Ends a socket that owes nothing: it shuts its side and drops what the peer sends for
/// `linger_ns`, then closes. A socket whose peer closed closes at once.
fn arm_close(self: anytype, socket: anytype, index: usize, now_ns: u64) void {
    if (!socket.peer_done and !socket.lingering) {
        submit(self, rotor.Operation.shutdown(user_data(self, index, .shutdown), socket.descriptor, .send));
        socket.lingering = true;
        socket.linger_until_ns = now_ns + linger_ns;
    }
    if (socket.peer_done or now_ns >= socket.linger_until_ns) {
        submit(self, rotor.Operation.close(user_data(self, index, .close), socket.descriptor));
        socket.closing = true;
        return;
    }
    if (!socket.receiving) {
        socket.input_len = 0;
        submit(self, rotor.Operation.receive(user_data(self, index, .receive), socket.descriptor, &socket.input));
        socket.receiving = true;
    }
}

fn free_index(self: anytype) ?usize {
    for (&self.sockets, 0..) |*socket, index| {
        if (!socket.live) return index;
    }
    return null;
}

fn on_event(self: anytype, event: rotor.Event, now_ns: u64) void {
    if (event.user_data == accept_user_data) return on_accept(self, event, now_ns);
    const index: usize = @intCast((event.user_data >> kind_bits) & ((1 << index_bits) - 1));
    const generation: u32 = @intCast(event.user_data >> (kind_bits + index_bits));
    const socket = &self.sockets[index];
    if (!socket.live or socket.generation != generation) return;
    switch (@as(Kind, @enumFromInt(@as(u2, @truncate(event.user_data))))) {
        .receive => {
            socket.receiving = false;
            const read = event.outcome() catch 0;
            // A read of 0 octets is the peer's close, and a failed read ends the socket too.
            if (read == 0) return peer_closed(self, socket);
            // A socket the server ends drops what it reads.
            if (!socket.close_wanted) socket.input_len += read;
        },
        .send => {
            socket.sending = false;
            const sent = event.outcome() catch return peer_closed(self, socket);
            socket.output_sent += sent;
            if (socket.output_sent == socket.output_len) {
                socket.output_sent = 0;
                socket.output_len = 0;
            }
        },
        // A shutdown that fails leaves the socket to close when its linger ends.
        .shutdown => {},
        .close => {
            socket.live = false;
            socket.generation +%= 1;
        },
    }
}

fn peer_closed(self: anytype, socket: anytype) void {
    socket.peer_done = true;
    if (socket.close_wanted) return;
    socket.close_wanted = true;
    socket.output_len = 0;
    socket.output_sent = 0;
    self.endpoint.transport_closed(socket.connection);
}

fn on_accept(self: anytype, event: rotor.Event, now_ns: u64) void {
    self.accepting = false;
    const descriptor: rotor.Descriptor = @intCast(event.outcome() catch return);
    const index = free_index(
        self,
    ) orelse return rotor.sync.close_now(descriptor);
    const connection = self.endpoint.accept(.{ .tls = false }, now_ns) orelse return rotor.sync.close_now(descriptor);
    rotor.sync.set_no_delay(descriptor, true) catch {};
    const socket = &self.sockets[index];
    socket.live = true;
    socket.descriptor = descriptor;
    socket.connection = connection;
    socket.receiving = false;
    socket.sending = false;
    socket.closing = false;
    socket.close_wanted = false;
    socket.lingering = false;
    socket.peer_done = false;
    socket.input_len = 0;
    socket.output_len = 0;
    socket.output_sent = 0;
}

/// Passes the endpoint what a socket read, and keeps what it did not take.
fn serve_input(self: anytype, socket: anytype, now_ns: u64) !void {
    if (socket.input_len == 0) return;
    var consumed: usize = 0;
    for (0..events_per_input_max) |_| {
        const read: server.StreamBytes = .{ .connection = socket.connection, .bytes = socket.input[consumed..socket.input_len] };
        const received = self.endpoint.receive(.{ .stream = read }, now_ns);
        consumed += received.consumed;
        const event = received.event orelse {
            if (received.consumed == 0) break;
            continue;
        };
        try serve_event(self, event, now_ns);
    }
    // What an event carried points into the input, so the input moves only now.
    std.mem.copyForwards(u8, socket.input[0 .. socket.input_len - consumed], socket.input[consumed..socket.input_len]);
    socket.input_len -= consumed;
}

fn serve_events(self: anytype, input: server.Input, now_ns: u64) !void {
    var rest = input;
    for (0..events_per_input_max) |_| {
        const received = self.endpoint.receive(rest, now_ns);
        rest = .none;
        try serve_event(self, received.event orelse return, now_ns);
    }
}

fn serve_event(self: anytype, event: server.Event, now_ns: u64) !void {
    if (@TypeOf(self.*).log_requests and event == .request) std.debug.print("{s} {s}\n", .{ event.request.method, event.request.target });
    switch (self.router.handle(self.app, &self.endpoint, event)) {
        .taken => {},
        .event => |other| switch (other) {
            .send => |connection| flush(self, socket_of(self, connection) orelse return, now_ns),
            .close => |connection| if (socket_of(self, connection)) |socket| {
                socket.close_wanted = true;
            },
            .ended => |over| if (socket_of(self, over.connection)) |socket| {
                socket.close_wanted = true;
            },
            else => {},
        },
    }
}

fn socket_of(self: anytype, connection: server.ConnectionHandle) ?*@TypeOf(self.sockets[0]) {
    for (&self.sockets) |*socket| {
        if (socket.live and std.meta.eql(socket.connection, connection)) return socket;
    }
    return null;
}

/// Writes what the endpoint owes a connection into its socket's output, as room allows. A
/// connection that owes more writes it at a later `send` event.
fn flush(self: anytype, socket: anytype, now_ns: u64) void {
    if (socket.sending) return;
    const room = socket.output[socket.output_len..];
    const written = self.endpoint.send_stream(socket.connection, room, now_ns);
    socket.output_len += written;
}
