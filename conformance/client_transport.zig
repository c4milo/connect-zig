//! The conformance client's transport: one `client.ConnectionPool` to the runner's reference
//! server, driven over a TCP socket with `poll` (decision 32: the library runs on any event
//! loop, and this program's loop is the plainest one). Each test case runs alone: `begin`
//! prepares the pool for the case's origin and HTTP version, the case's call starts on
//! `pool_of()` and `listen` passes the call's events on, and each `turn` reads the socket, writes
//! what the pool owes, and fires the pool's deadlines. `end` closes the socket.
//!
//! The program reads the clock and the socket; colibri reads neither (colibri non-negotiable 3).
const std = @import("std");
const assert = std.debug.assert;
const client = @import("client");
const tls = @import("tls");
const constants = @import("constants.zig");
const datagram = @import("client_datagram.zig");

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
var pool: Pool align(@alignOf(Pool)) = undefined;
var pool_memory: [Pool.memory_bytes(pool_counts)]u8 align(Pool.memory_alignment) = undefined;
var pool_config: client.Config align(@alignOf(client.Config)) = undefined;
var receive_pool: ReceivePool align(@alignOf(ReceivePool)) = undefined;
var authority: [constants.client_authority_bytes]u8 = undefined;
var addresses: [1]client.Address align(@alignOf(client.Address)) = undefined;
var peer: std.Io.net.IpAddress align(@alignOf(std.Io.net.IpAddress)) = undefined;
var stream: ?std.Io.net.Stream align(@alignOf(std.Io.net.Stream)) = null;
var tcp: client.ConnectionHandle align(@alignOf(client.ConnectionHandle)) = .{ .slot = 0, .generation = 0 };
var input: [constants.client_socket_input_bytes]u8 = undefined;
var input_len: usize = 0;
var output: [client.constants.limits.stream_output_len_min]u8 = undefined;
var listener: ?Listener align(@alignOf(Listener)) = null;
var io: std.Io = undefined;
/// The source each TLS session draws from, seeded from the system once.
var csprng: std.Random.DefaultCsprng align(@alignOf(std.Random.DefaultCsprng)) = undefined;

/// Keeps the program's I/O, and seeds the random source from the system.
pub fn init(program_io: std.Io) void {
    io = program_io;
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    io.random(&seed);
    csprng = .init(seed);
}

/// Prepares the pool for a case's origin, `host` and `port`, over `protocols`, over TLS when
/// `trust` is given. A TCP connection in cleartext speaks h11 when `protocols` allows it, and h2
/// with prior knowledge when it does not (RFC 9113 §3.3); over TLS, ALPN names the version
/// (RFC 7301 §3).
pub fn begin(host: []const u8, port: u16, protocols: client.Protocols, trust: ?tls.Client) BeginError!void {
    assert(stream == null);
    peer = std.Io.net.IpAddress.parse(host, port) catch return error.InvalidHost;
    addresses = .{switch (peer) {
        .ip4 => |address| .of(&address.bytes, 0),
        .ip6 => |address| .of(&address.bytes, 0),
    }};
    // RFC 9110 §4.2.1 and RFC 3986 §3.2.2: an IPv6 literal goes in brackets in an authority.
    const written = switch (peer) {
        .ip4 => std.fmt.bufPrint(&authority, "{s}:{d}", .{ host, port }),
        .ip6 => std.fmt.bufPrint(&authority, "[{s}]:{d}", .{ host, port }),
    } catch return error.AuthorityTooLong;
    pool_config = .{ .tls = trust, .authority = written, .protocols = protocols, .tcp_connections = pool_counts.tcp_connections, .requests = pool_counts.requests };
    const destination: client.Destination = .{ .addresses = &addresses, .port = port };
    if (protocols.h3) {
        try pool.init(&pool_memory, &pool_config, destination, receive_pool.storage());
        try datagram.open(io, &peer);
    } else {
        try pool.init(&pool_memory, &pool_config, destination, null);
    }
    input_len = 0;
    listener = null;
}

/// The pool a case's call starts on.
pub fn pool_of() *Pool {
    return &pool;
}

/// Passes the events of the case's exchange to `call`.
pub fn listen(call: Listener) void {
    listener = call;
}

/// Ends the case: the socket closes, and the pool is prepared afresh for the next case.
pub fn end() void {
    close_socket();
    datagram.close(io);
    listener = null;
}

/// The instant of the program's monotonic clock, in nanoseconds.
pub fn now_ns() u64 {
    const instant = std.Io.Clock.awake.now(io);
    return @intCast(@max(instant.nanoseconds, 0));
}

/// One turn: what the pool owes goes out, then the socket is read until `until_ns`, or until the
/// pool's next deadline when it comes first, and the pool reads what arrived.
pub fn turn(until_ns: u64) void {
    const before_ns = now_ns();
    drain(before_ns);
    datagram.flush(io, &pool, &peer, before_ns);
    read_sockets(wait_of(until_ns, pool.deadline_ns(), before_ns));
    const after_ns = now_ns();
    if (pool.deadline_ns()) |deadline_ns| {
        if (deadline_ns <= after_ns) pool.on_instant(after_ns);
    }
    drain(after_ns);
    datagram.flush(io, &pool, &peer, after_ns);
}

/// How long a turn waits: until `until_ns` or the pool's deadline, and no longer than
/// `client_wait_ns_max`.
fn wait_of(until_ns: u64, deadline_ns: ?u64, now: u64) u64 {
    var at_ns = until_ns;
    if (deadline_ns) |pool_ns| at_ns = @min(at_ns, pool_ns);
    return @min(at_ns -| now, constants.client_wait_ns_max);
}

/// Waits up to `wait_ns` for the TCP or the UDP socket to be readable, and reads what each holds.
fn read_sockets(wait_ns: u64) void {
    const wait_ms: i32 = @intCast(std.math.divCeil(u64, wait_ns, constants.nanos_per_milli) catch unreachable);
    // An fd below 0 is one poll skips (POSIX poll()).
    const skipped: std.posix.fd_t = -1;
    const tcp_fd = if (stream) |open| (if (input_len < input.len) open.socket.handle else skipped) else skipped;
    var descriptors: [std.enums.values(Socket).len]std.posix.pollfd = undefined;
    descriptors[@intFromEnum(Socket.tcp)] = .{ .fd = tcp_fd, .events = std.posix.POLL.IN, .revents = 0 };
    descriptors[@intFromEnum(Socket.udp)] = .{ .fd = datagram.descriptor() orelse skipped, .events = std.posix.POLL.IN, .revents = 0 };
    const ready = std.posix.poll(&descriptors, wait_ms) catch return;
    if (ready == 0) return;
    if (descriptors[@intFromEnum(Socket.tcp)].revents != 0) read_stream();
    if (descriptors[@intFromEnum(Socket.udp)].revents != 0) datagram.read(io, &pool, now_ns(), report);
}

/// The sockets a turn polls: the TCP connection's and the UDP socket of QUIC's.
const Socket = enum { tcp, udp };

/// Reads what the TCP socket holds after the octets the pool has not consumed.
fn read_stream() void {
    const open = stream orelse return;
    const read_len = std.posix.read(open.socket.handle, input[input_len..]) catch return failed();
    // The peer closed its end (RFC 9293 §3.6): the pool ends the connection.
    if (read_len == 0) return failed();
    input_len += read_len;
}

/// The socket failed or the peer closed it: the pool ends every exchange the connection held.
fn failed() void {
    close_socket();
    pool.transport_closed(tcp);
}

fn close_socket() void {
    const open = stream orelse return;
    open.close(io);
    stream = null;
    input_len = 0;
}

/// Passes the pool the octets the socket read, or `.none` when it holds none, until it consumes
/// nothing and reports nothing, and does what each event asks.
fn drain(now: u64) void {
    for (0..constants.client_events_per_turn_max) |_| {
        const held = input[0..input_len];
        const read: client.Input = if (held.len > 0 and stream != null) .{ .stream = .{ .connection = tcp, .bytes = held } } else .none;
        const received = pool.receive(read, now);
        consume(received.consumed);
        const event = received.event orelse {
            if (received.consumed == 0) return;
            continue;
        };
        report(event, now);
    }
}

/// Drops the `len` octets the pool consumed from the start of the input.
fn consume(len: usize) void {
    assert(len <= input_len);
    if (len == 0) return;
    std.mem.copyForwards(u8, input[0 .. input_len - len], input[len..input_len]);
    input_len -= len;
}

fn report(event: client.Event, now: u64) void {
    switch (event) {
        .open => |asked| switch (asked.transport) {
            .tcp => open_tcp(asked),
            .quic => pool.start_quic(csprng.random(), unix_seconds(), now, null) catch {},
        },
        .send => |connection| send_owed(connection, now),
        // The pool is done with the connection: the octets still held are its, and go too.
        .close => |connection| if (std.meta.eql(connection, tcp)) close_socket(),
        .connected, .closed => {},
        // The client opens no second connection to resume, so it wipes the server's ticket.
        .ticket => |connection| if (pool.take_ticket(connection)) |ticket| {
            var held = ticket;
            held.wipe();
        },
        .headers, .body, .body_taken, .finished => if (listener) |call| call.on_event(call.context, event),
    }
}

/// Connects the TCP socket an `open` event asks for, with Nagle's algorithm off so a small
/// message leaves at once, and starts the pool's connection on it. A connect that fails ends the
/// attempt, as a refused connect does.
fn open_tcp(asked: client.Open) void {
    assert(asked.transport == .tcp);
    close_socket();
    tcp = asked.connection;
    const connected = peer.connect(io, .{ .mode = .stream }) catch return pool.transport_closed(tcp);
    stream = connected;
    const on: c_int = 1;
    // A socket that refuses the option is used as it is.
    std.posix.setsockopt(connected.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&on)) catch {};
    pool.start_tcp(tcp, csprng.random(), unix_seconds(), null) catch failed();
}

/// The seconds since 1970 by the system's clock, at which TLS judges the server's certificate
/// (RFC 5280 §4.1.2.5).
fn unix_seconds() u64 {
    return @intCast(@max(std.Io.Clock.real.now(io).toSeconds(), 0));
}

/// Writes what the connection owes to its socket.
fn send_owed(connection: client.ConnectionHandle, now: u64) void {
    const open = stream orelse return;
    if (!std.meta.eql(connection, tcp)) return;
    var writer = open.writer(io, &.{});
    for (0..constants.client_events_per_turn_max) |_| {
        const written = pool.send_stream(connection, &output, now);
        writer.interface.writeAll(output[0..written]) catch return failed();
        if (written < output.len) return;
    }
}

const testing = std.testing;

test "a turn waits until its instant or the pool's deadline, whichever comes first, and briefly" {
    const milli = constants.nanos_per_milli;
    try testing.expectEqual(@as(u64, 5 * milli), wait_of(15 * milli, null, 10 * milli));
    try testing.expectEqual(@as(u64, 2 * milli), wait_of(15 * milli, 12 * milli, 10 * milli));
    try testing.expectEqual(@as(u64, 0), wait_of(5 * milli, null, 10 * milli));
    try testing.expectEqual(constants.client_wait_ns_max, wait_of(std.math.maxInt(u64), null, 0));
}
