//! The conformance client's transport: one `client.ConnectionPool` to the runner's reference
//! server, driven over a TCP socket with `poll` (decision 32: the library runs on any event
//! loop, and this program's loop is the plainest one). Each test case runs alone: `begin`
//! prepares the pool for the case's origin and HTTP version, the case's call starts on
//! `pool_of()` and `listen` passes the call's events on, and each `turn` reads the socket, writes
//! what the pool owes, and fires the pool's deadlines. `end` closes the socket.
//!
//! A program holds one `Transport` in its `State`, and `init` starts it in place (decision 42).
//! The program reads the clock and the socket; colibri reads neither (colibri non-negotiable 3).
const std = @import("std");
const assert = std.debug.assert;
const client = @import("colibri").client;
const tls = @import("colibri").tls;
const constants = @import("constants.zig");
const UdpSocket = @import("client_datagram.zig").UdpSocket;

/// The pool of the default capacity, which `rpc.ClientCall`'s options name by default. A case
/// over h3 gives it the receive pool, so it offers QUIC (RFC 9114 §3.1).
pub const Pool = client.ConnectionPool(.{});
/// The server's unread octets of the QUIC connection: the longest response a case reads.
const ReceivePool = client.ReceivePool(.{ .capacity = constants.client_body_bytes });

/// The call a case runs, which gets the `headers`, `body`, `body_taken` and `finished` events of
/// its exchange.
pub const Listener = struct {
    context: *anyopaque,
    on_event: *const fn (context: *anyopaque, event: client.Event) void,
};

/// What `begin` refuses: a host that is no IP literal, or a pool that does not start.
pub const BeginError = client.StartError || std.Io.net.IpAddress.BindError || error{ InvalidHost, AuthorityTooLong };

const pool_counts: Pool.Counts = .{ .tcp_connections = 1, .requests = 1 };

/// The sockets a turn polls: the TCP connection's and the UDP socket of QUIC's.
const Socket = enum { tcp, udp };

pub const Transport = struct {
    const Self = @This();

    pool: Pool,
    pool_memory: [Pool.memory_bytes(pool_counts)]u8 align(Pool.memory_alignment),
    pool_config: client.Config,
    receive_pool: ReceivePool,
    authority: [constants.client_authority_bytes]u8,
    addresses: [1]client.Address,
    peer: std.Io.net.IpAddress,
    stream: ?std.Io.net.Stream,
    tcp: client.ConnectionHandle,
    input: [constants.client_socket_input_bytes]u8,
    input_len: usize,
    output: [client.constants.limits.stream_output_len_min]u8,
    listener: ?Listener,
    udp: UdpSocket,
    io: std.Io,

    /// Starts the transport in place with the program's I/O. Each TLS session draws from the
    /// context its plan's TLS value holds (colibri decision 175).
    pub fn init(self: *Self, io: std.Io) void {
        self.io = io;
        self.stream = null;
        self.tcp = .{ .slot = 0, .generation = 0 };
        self.input_len = 0;
        self.listener = null;
        self.udp.init();
    }

    /// Prepares the pool for a case's origin, `host` and `port`, over `protocols`, over TLS when
    /// `trust` is given. A TCP connection in cleartext speaks h11 when `protocols` allows it, and
    /// h2 with prior knowledge when it does not (RFC 9113 §3.3); over TLS, ALPN names the version
    /// (RFC 7301 §3). `cpu_features` are the program's, which the pool's configuration states
    /// (colibri decision 169).
    pub fn begin(self: *Self, host: []const u8, port: u16, protocols: client.Protocols, trust: ?tls.Client, cpu_features: client.CpuFeatures) BeginError!void {
        assert(self.stream == null);
        self.peer = std.Io.net.IpAddress.parse(host, port) catch return error.InvalidHost;
        self.addresses = .{switch (self.peer) {
            .ip4 => |address| .init(&address.bytes, 0),
            .ip6 => |address| .init(&address.bytes, 0),
        }};
        // RFC 9110 §4.2.1 and RFC 3986 §3.2.2: an IPv6 literal goes in brackets in an authority.
        const written = switch (self.peer) {
            .ip4 => std.fmt.bufPrint(&self.authority, "{s}:{d}", .{ host, port }),
            .ip6 => std.fmt.bufPrint(&self.authority, "[{s}]:{d}", .{ host, port }),
        } catch return error.AuthorityTooLong;
        self.pool_config = .{ .cpu_features = cpu_features, .tls = trust, .authority = written, .protocols = protocols, .tcp_connections = pool_counts.tcp_connections, .requests = pool_counts.requests };
        const destination: client.Destination = .{ .addresses = &self.addresses, .port = port };
        if (protocols.h3) {
            try self.pool.init(&self.pool_memory, &self.pool_config, &destination, self.receive_pool.storage());
            try self.udp.open(self.io, &self.peer);
        } else {
            try self.pool.init(&self.pool_memory, &self.pool_config, &destination, null);
        }
        self.input_len = 0;
        self.listener = null;
    }

    /// The pool a case's call starts on.
    pub fn pool_of(self: *Self) *Pool {
        return &self.pool;
    }

    /// Passes the events of the case's exchange to `call`.
    pub fn listen(self: *Self, call: Listener) void {
        self.listener = call;
    }

    /// Ends the case: the socket closes, and the pool is prepared afresh for the next case.
    pub fn end(self: *Self) void {
        self.close_socket();
        self.udp.close(self.io);
        self.listener = null;
    }

    /// The instant of the program's monotonic clock, in nanoseconds.
    pub fn now_ns(self: *const Self) u64 {
        const instant = std.Io.Clock.awake.now(self.io);
        return @intCast(@max(instant.nanoseconds, 0));
    }

    /// One turn: what the pool owes goes out, then the socket is read until `until_ns`, or until
    /// the pool's next deadline when it comes first, and the pool reads what arrived.
    pub fn turn(self: *Self, until_ns: u64) void {
        const before_ns = self.now_ns();
        self.drain(before_ns);
        self.udp.flush(self.io, &self.pool, &self.peer, before_ns);
        self.read_sockets(wait_of(until_ns, self.pool.deadline_ns(), before_ns));
        const after_ns = self.now_ns();
        if (self.pool.deadline_ns()) |deadline_ns| {
            if (deadline_ns <= after_ns) self.pool.on_instant(after_ns);
        }
        self.drain(after_ns);
        self.udp.flush(self.io, &self.pool, &self.peer, after_ns);
    }

    /// Waits up to `wait_ns` for the TCP or the UDP socket to be readable, and reads what each
    /// holds.
    fn read_sockets(self: *Self, wait_ns: u64) void {
        const wait_ms: i32 = @intCast(std.math.divCeil(u64, wait_ns, constants.nanos_per_milli) catch unreachable);
        // An fd below 0 is one poll skips (POSIX poll()).
        const skipped: std.posix.fd_t = -1;
        const tcp_fd = if (self.stream) |open| (if (self.input_len < self.input.len) open.socket.handle else skipped) else skipped;
        var descriptors: [std.enums.values(Socket).len]std.posix.pollfd = @splat(.{ .fd = skipped, .events = std.posix.POLL.IN, .revents = 0 });
        descriptors[@intFromEnum(Socket.tcp)].fd = tcp_fd;
        descriptors[@intFromEnum(Socket.udp)].fd = self.udp.descriptor() orelse skipped;
        const ready = std.posix.poll(&descriptors, wait_ms) catch return;
        if (ready == 0) return;
        if (descriptors[@intFromEnum(Socket.tcp)].revents != 0) self.read_stream();
        if (descriptors[@intFromEnum(Socket.udp)].revents != 0) self.udp.read(self.io, &self.pool, self.now_ns(), self);
    }

    /// Reads what the TCP socket holds after the octets the pool has not consumed.
    fn read_stream(self: *Self) void {
        const open = self.stream orelse return;
        const read_len = std.posix.read(open.socket.handle, self.input[self.input_len..]) catch return self.failed();
        // The peer closed its end (RFC 9293 §3.6): the pool ends the connection.
        if (read_len == 0) return self.failed();
        self.input_len += read_len;
    }

    /// The socket failed or the peer closed it: the pool ends every exchange the connection held.
    fn failed(self: *Self) void {
        self.close_socket();
        self.pool.transport_closed(self.tcp);
    }

    fn close_socket(self: *Self) void {
        const open = self.stream orelse return;
        open.close(self.io);
        self.stream = null;
        self.input_len = 0;
    }

    /// Passes the pool the octets the socket read, or `.none` when it holds none, until it
    /// consumes nothing and reports nothing, and does what each event asks.
    fn drain(self: *Self, now: u64) void {
        for (0..constants.client_events_per_turn_max) |_| {
            const held = self.input[0..self.input_len];
            const read: client.Input = if (held.len > 0 and self.stream != null) .{ .stream = .{ .connection = self.tcp, .bytes = held } } else .none;
            const received = self.pool.receive(read, now);
            self.consume(received.consumed);
            const event = received.event orelse {
                if (received.consumed == 0) return;
                continue;
            };
            self.report(event, now);
        }
    }

    /// Drops the `len` octets the pool consumed from the start of the input.
    fn consume(self: *Self, len: usize) void {
        assert(len <= self.input_len);
        if (len == 0) return;
        std.mem.copyForwards(u8, self.input[0 .. self.input_len - len], self.input[len..self.input_len]);
        self.input_len -= len;
    }

    /// Does what one event of the pool asks. The UDP socket calls it too, for each event of a
    /// datagram.
    pub fn report(self: *Self, event: client.Event, now: u64) void {
        switch (event) {
            .open => |asked| switch (asked.transport) {
                .tcp => self.open_tcp(asked),
                .quic => self.pool.start_quic(self.unix_seconds(), now, null) catch {},
            },
            .send => |connection| self.send_owed(connection, now),
            // The pool is done with the connection: the octets still held are its, and go too.
            .close => |connection| if (std.meta.eql(connection, self.tcp)) self.close_socket(),
            .connected, .closed => {},
            // The client opens no second connection to resume, so it wipes the server's ticket.
            .ticket => |connection| if (self.pool.take_ticket(connection)) |ticket| {
                var held = ticket;
                held.wipe();
            },
            .headers, .body, .body_taken, .finished => if (self.listener) |call| call.on_event(call.context, event),
        }
    }

    /// Connects the TCP socket an `open` event asks for, with Nagle's algorithm off so a small
    /// message leaves at once, and starts the pool's connection on it. A connect that fails ends
    /// the attempt, as a refused connect does.
    fn open_tcp(self: *Self, asked: client.Open) void {
        assert(asked.transport == .tcp);
        self.close_socket();
        self.tcp = asked.connection;
        const connected = self.peer.connect(self.io, .{ .mode = .stream }) catch return self.pool.transport_closed(self.tcp);
        self.stream = connected;
        const on: c_int = 1;
        // A socket that refuses the option is used as it is.
        std.posix.setsockopt(connected.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&on)) catch {};
        self.pool.start_tcp(self.tcp, self.unix_seconds(), null) catch self.failed();
    }

    /// The seconds since 1970 by the system's clock, at which TLS judges the server's certificate
    /// (RFC 5280 §4.1.2.5).
    fn unix_seconds(self: *const Self) u64 {
        return @intCast(@max(std.Io.Clock.real.now(self.io).toSeconds(), 0));
    }

    /// Writes what the connection owes to its socket.
    fn send_owed(self: *Self, connection: client.ConnectionHandle, now: u64) void {
        const open = self.stream orelse return;
        if (!std.meta.eql(connection, self.tcp)) return;
        var writer = open.writer(self.io, &.{});
        for (0..constants.client_events_per_turn_max) |_| {
            const written = self.pool.send_stream(connection, &self.output, now);
            writer.interface.writeAll(self.output[0..written]) catch return self.failed();
            if (written < self.output.len) return;
        }
    }
};

/// How long a turn waits: until `until_ns` or the pool's deadline, and no longer than
/// `client_wait_ns_max`.
fn wait_of(until_ns: u64, deadline_ns: ?u64, now: u64) u64 {
    var at_ns = until_ns;
    if (deadline_ns) |pool_ns| at_ns = @min(at_ns, pool_ns);
    return @min(at_ns -| now, constants.client_wait_ns_max);
}

const testing = std.testing;

test "a turn waits until its instant or the pool's deadline, whichever comes first, and briefly" {
    const milli = constants.nanos_per_milli;
    try testing.expectEqual(@as(u64, 5 * milli), wait_of(15 * milli, null, 10 * milli));
    try testing.expectEqual(@as(u64, 2 * milli), wait_of(15 * milli, 12 * milli, 10 * milli));
    try testing.expectEqual(@as(u64, 0), wait_of(5 * milli, null, 10 * milli));
    try testing.expectEqual(constants.client_wait_ns_max, wait_of(std.math.maxInt(u64), null, 0));
}
