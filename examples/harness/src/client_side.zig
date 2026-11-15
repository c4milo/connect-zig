//! The client side of the in-memory rounds: one `client.ConnectionPool` that carries a round of
//! calls to the server side, as colibri's examples do. A round over h11 or h2 runs in cleartext
//! over the stream link (decision 13). A round over h3 runs QUIC over the datagram link, and
//! judges the server by the CA of `tls/` (decision 25).
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const tls = @import("tls");
const identity = @import("test_identity");
const rpc = @import("connect_colibri");
const constants = @import("constants.zig");
const Link = @import("link.zig").Link;
const datagram_module = @import("link_datagram.zig");
const DatagramLink = datagram_module.DatagramLink;
const server_side = @import("server_side.zig");

/// Room for the DER of the CA bundle, and its one anchor.
const anchor_der_len = constants.der_len_max(identity.ca_pem.len);
const anchors_max = 1;
/// The server's address, and the address each of its datagrams comes from.
const server_address: client.Address = .of(&constants.loopback, constants.server_port);
/// What DNS knows of the server. The pool keeps the slice, and QUIC checks each datagram's address
/// against it, so it lives as long as the program.
const server_addresses = [_]client.Address{.of(&constants.loopback, 0)};

pub const Error = error{ CallUnfinished, CallWrong };

/// The buffers of one call: its request's body, scratch and header values, and its response's
/// headers, trailers and body, and its pieces when it streams.
pub const CallBuffers = struct {
    request_body: [constants.call_buffer_len]u8,
    message: [constants.call_buffer_len]u8,
    work: [constants.call_buffer_len]u8,
    values: [constants.call_buffer_len]u8,
    headers: [constants.call_buffer_len]u8,
    trailers: [constants.call_buffer_len]u8,
    body: [constants.call_buffer_len]u8,
    piece: [constants.piece_len]u8,

    /// The `ClientCall` buffers that `set` holds.
    pub fn of(set: *CallBuffers) rpc.ClientCallBuffers {
        return .{
            .request = .{ .body = &set.request_body, .scratch = .{ .message = &set.message, .work = &set.work, .tokens = &.{} }, .values = &set.values },
            .headers = &set.headers,
            .trailers = &set.trailers,
            .body = &set.body,
            .piece = &set.piece,
        };
    }
};

/// Room for one response's reading: its strings, details and metadata. A streamed call keeps one
/// from its `headers` event to its end.
pub const ReadBuffers = struct {
    message: [constants.read_len]u8,
    work: [constants.read_len]u8,
    tokens: [constants.read_len]u8,
    octets: [constants.read_len]u8,
    details: [constants.entries_max]connect.Detail,
    metadata: [constants.entries_max]connect.Header,

    pub fn storage(room: *ReadBuffers) connect.client.Storage {
        return .{
            .scratch = .{ .message = &room.message, .work = &room.work, .tokens = &room.tokens },
            .octets = &room.octets,
            .details = &room.details,
            .metadata = &room.metadata,
        };
    }
};

/// A streamed call of the round, which gets the `headers`, `body`, `body_taken` and `finished`
/// events of its exchange.
pub const Listener = struct {
    id: client.RequestId,
    context: *anyopaque,
    on_event: *const fn (context: *anyopaque, event: client.Event) anyerror!void,
};

const ReceivePool = client.ReceivePool(.{ .capacity = constants.receive_pool_len });
pub const Pool = client.ConnectionPool(.{});

/// The client of one program's rounds, which drives the server side in the same process.
pub const ClientSide = struct {
    const Self = @This();

    server: *server_side.ServerSide,
    link: *Link,
    datagram_link: *DatagramLink,
    datagram_output: [datagram_module.datagram_len_max]u8,
    receive_pool: ReceivePool,
    anchor_der: [anchor_der_len]u8,
    anchor_room: [anchors_max]tls.Anchor,
    anchors: []const tls.Anchor,
    output: [client.constants.limits.stream_output_len_min]u8,
    config: client.Config,
    pool: Pool,
    pool_memory: [Pool.memory_bytes(.{})]u8 align(Pool.memory_alignment),
    prng: std.Random.DefaultPrng,
    tcp: client.ConnectionHandle,
    /// Whether the round runs QUIC, which speaks h3, rather than TCP.
    quic: bool,
    /// The connections the server saw end before the round began: the round ends after one more.
    ended_before: u32,
    requested: u32,
    finished: u32,
    pool_closed: bool,
    spoken: ?client.Protocol,
    listeners: [constants.listeners_max]Listener,
    listener_count: usize,
    read_buffers: ReadBuffers,

    pub fn init(self: *Self, server: *server_side.ServerSide, link: *Link, datagram_link: *DatagramLink) !void {
        self.server = server;
        self.link = link;
        self.datagram_link = datagram_link;
        self.prng = .init(constants.client_seed);
        self.tcp = .{ .slot = 0, .generation = 0 };
        self.listener_count = 0;
        // The CA the client trusts: its subject Name and SubjectPublicKeyInfo.
        self.anchors = try tls.pem.anchors(identity.ca_pem, &self.anchor_der, &self.anchor_room);
    }

    /// Starts a round whose pool speaks `protocols`: h3 alone over QUIC, or h11 and h2 over TCP.
    pub fn begin(self: *Self, protocols: client.Protocols) !void {
        // A pool that offers h3 and a TCP protocol too may open both, and this harness runs one.
        std.debug.assert(!protocols.h3 or (!protocols.h2 and !protocols.h11));
        self.quic = protocols.h3;
        const destination: client.Destination = .{ .addresses = &server_addresses, .port = constants.server_port };
        if (self.quic) {
            // QUIC always runs TLS. The receive pool is what makes the pool offer QUIC.
            const trust: tls.Trust = .{ .web_pki = .{ .anchors = self.anchors, .server_name = identity.server_name } };
            self.config = .{ .tls = .{ .trust = trust, .cpu = server_side.cpu }, .authority = identity.server_name, .protocols = protocols };
            try self.pool.init(&self.pool_memory, &self.config, &destination, self.receive_pool.storage());
        } else {
            self.config = .{ .authority = identity.server_name, .protocols = protocols };
            try self.pool.init(&self.pool_memory, &self.config, &destination, null);
        }
        self.ended_before = self.server.ended();
        self.requested = 0;
        self.finished = 0;
        self.pool_closed = false;
        self.spoken = null;
        self.listener_count = 0;
    }

    /// Adds a streamed call the program started on `pool`: its events go to `listener`.
    pub fn listen(self: *Self, listener: Listener) !void {
        if (self.listener_count == constants.listeners_max) return error.CallWrong;
        self.listeners[self.listener_count] = listener;
        self.listener_count += 1;
        self.requested += 1;
    }

    /// Adds a call to the round. Both stay in place until `finish` returns.
    pub fn request(self: *Self, call_request: *client.Request, call_response: *client.Response) !void {
        _ = try self.pool.request(call_request, call_response);
        self.requested += 1;
    }

    /// Runs the round until every call finished and the connection closed, and checks it
    /// spoke `expected`.
    pub fn finish(self: *Self, expected: client.Protocol) !void {
        for (0..constants.turns_max) |_| {
            try self.turn();
            try self.server.turn();
            // The round is over once the pool closed and the server's connection ended, so the
            // next round's connection takes the server's one slot.
            if (self.pool_closed and self.server.ended() > self.ended_before) {
                if (self.spoken != expected) return error.CallWrong;
                return;
            }
            if (!self.link.pending() and !self.datagram_link.pending()) try self.link.wait(.client, self.sleep_ns());
        }
        return error.CallUnfinished;
    }

    fn turn(self: *Self) !void {
        const now_ns = self.link.now_ns(.client);
        try self.read_datagrams(now_ns);
        self.pool.on_instant(now_ns);
        try self.drain(now_ns);
        for (0..constants.datagrams_per_turn_max) |_| {
            const sent = self.pool.send_datagram(&self.datagram_output, now_ns) orelse break;
            try self.datagram_link.send(.client, sent.bytes);
        }
        try self.drain(now_ns);
    }

    /// Passes the pool each datagram the UDP socket read, with the address it came from. A
    /// datagram is consumed whole.
    fn read_datagrams(self: *Self, now_ns: u64) !void {
        for (0..constants.datagrams_per_turn_max) |_| {
            const datagram = try self.datagram_link.receive(.client) orelse break;
            var rest: client.Input = .{ .datagram = .{ .bytes = datagram, .from = server_address } };
            for (0..constants.receive_calls_max) |_| {
                const received = self.pool.receive(rest, now_ns);
                if (received.consumed > 0) rest = .none;
                const event = received.event orelse {
                    if (received.consumed == 0) break;
                    continue;
                };
                try self.report(event, now_ns);
            }
            self.datagram_link.consume(.client);
        }
    }

    /// Passes the pool the octets the TCP socket read, or `.none` when it holds none, until it
    /// consumes nothing and reports nothing.
    fn drain(self: *Self, now_ns: u64) !void {
        const input = try self.link.receive(.client);
        var consumed: usize = 0;
        for (0..constants.receive_calls_max) |_| {
            const held = input[consumed..];
            const read: client.Input = if (held.len > 0) .{ .stream = .{ .connection = self.tcp, .bytes = held } } else .none;
            const received = self.pool.receive(read, now_ns);
            consumed += received.consumed;
            const event = received.event orelse {
                if (received.consumed == 0) break;
                continue;
            };
            try self.report(event, now_ns);
            if (event == .close and !self.quic) consumed = input.len;
        }
        self.link.consume(.client, consumed);
    }

    fn report(self: *Self, event: client.Event, now_ns: u64) !void {
        switch (event) {
            .open => |open| try self.open_transport(open, now_ns),
            .send => |connection| try self.send_owed(connection, now_ns),
            .connected => |connected| self.spoken = connected.protocol,
            .finished => |ended| {
                if (self.find(ended.id)) |listener| try listener.on_event(listener.context, event);
                self.finished += 1;
                if (self.finished == self.requested) self.pool.shutdown();
            },
            // The pool closed the socket, after the GOAWAY: the server reads its end. A QUIC
            // connection told the server itself, with CONNECTION_CLOSE.
            .close => if (!self.quic) self.server.peer_closed(),
            .closed => self.pool_closed = true,
            // A streamed exchange alone reports these (colibri decision 153).
            .headers => |id| try self.pass(id, event),
            .body => |piece| try self.pass(piece.id, event),
            .body_taken => |id| try self.pass(id, event),
            // The pool opens no second connection to resume, so it wipes the server's ticket.
            .ticket => |connection| if (self.pool.take_ticket(connection)) |ticket| {
                var held = ticket;
                held.wipe();
            },
        }
    }

    fn find(self: *const Self, id: client.RequestId) ?*const Listener {
        for (self.listeners[0..self.listener_count]) |*listener| {
            if (listener.id == id) return listener;
        }
        return null;
    }

    /// Passes a streamed exchange's event to its call.
    fn pass(self: *const Self, id: client.RequestId, event: client.Event) !void {
        const listener = self.find(id) orelse return error.CallWrong;
        try listener.on_event(listener.context, event);
    }

    /// Starts the connection an `open` named, over the transport the round runs. The link
    /// stands where a socket would be: the server accepts what the client connects.
    fn open_transport(self: *Self, open: client.Open, now_ns: u64) !void {
        // The round checks the protocol it spoke when it ends, so a transport it did not ask
        // for fails there.
        switch (open.transport) {
            .quic => try self.pool.start_quic(self.prng.random(), server_side.now_seconds, now_ns, null),
            .tcp => {
                self.tcp = open.connection;
                try self.server.accept();
                try self.pool.start_tcp(open.connection, self.prng.random(), server_side.now_seconds, null);
            },
        }
    }

    fn send_owed(self: *Self, connection: client.ConnectionHandle, now_ns: u64) !void {
        for (0..constants.client_sends_per_event_max) |_| {
            const written = self.pool.send_stream(connection, &self.output, now_ns);
            try self.link.send(.client, self.output[0..written]);
            if (written < self.output.len) return;
        }
        return error.CallWrong;
    }

    fn sleep_ns(self: *Self) u64 {
        var wait_ns: u64 = constants.wait_ns_max;
        if (self.pool.deadline_ns()) |deadline_ns| wait_ns = @min(wait_ns, deadline_ns -| self.link.now_ns(.client));
        if (self.server.deadline_ns()) |deadline_ns| wait_ns = @min(wait_ns, deadline_ns -| self.link.now_ns(.server));
        return @max(wait_ns, 1);
    }
};

/// Checks a response holds no message more, and ended in success.
pub fn expect_end(response: *connect.client.Response, comptime T: type) !void {
    if (try response.next(T) != null) return error.CallWrong;
    if (response.failure) |failure| {
        std.debug.print("example: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.CallWrong;
    }
}

/// Checks `trailers` holds a trailer `name` with `value`.
pub fn expect_trailer(trailers: []const connect.Header, name: []const u8, value: []const u8) !void {
    for (trailers) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            if (std.mem.eql(u8, entry.value, value)) return;
            std.debug.print("example: trailer {s} is {s}, wanted {s}\n", .{ name, entry.value, value });
            return error.CallWrong;
        }
    }
    std.debug.print("example: no trailer {s}\n", .{name});
    return error.CallWrong;
}
