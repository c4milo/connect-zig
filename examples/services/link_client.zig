//! The example client's loop over the in-memory links: one `client.ConnectionPool` that carries a
//! round of calls to the server of `link_server.zig`, as colibri's examples do. A round over h11
//! or h2 runs in cleartext over the stream link (decision 13). A round over h3 runs QUIC over the
//! datagram link, and judges the server by the CA of `examples/testdata/tls` (decision 25).
//!
//! A program calls `init` once, then for each round:
//!
//! 1. `begin` with the protocols the pool may speak: h3 alone, or h11 and h2 without h3;
//! 2. `request` for each call, with the colibri request and response of an `ClientCall`;
//! 3. `finish` with the protocol the round must speak, which runs client and server until every
//!    call finished and the connection closed;
//! 4. `read` on each client call, with `storage()`, to check what arrived.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const tls = @import("tls");
const identity = @import("test_identity");
const rpc = @import("connect_colibri");
const link_server = @import("link_server.zig");
const Link = @import("link.zig").Link;
const datagram_module = @import("link_datagram.zig");
const DatagramLink = datagram_module.DatagramLink;

/// Turns of the client and the server in one round before the example gives up.
const turns_max = 512;
const sends_per_event_max = 16;
const receive_calls_max = 4096;
const datagrams_per_turn_max = 32;
/// The longest the program sleeps when no octet waits: 100 ms.
const wait_ns_max: u64 = 100_000_000;
/// Unix seconds, which a program reads from its clock; colibri reads no clock. The server's
/// certificates are valid at this instant.
const now_seconds = identity.now_seconds;
/// The port the server listens on, for TCP and for UDP: the port of an "https" origin (RFC 9110
/// §4.2.2).
const server_port = 443;
/// Octets a QUIC connection holds unread, at most: what colibri's examples hold.
const receive_pool_len = 64 * 1024;
/// Room for the DER of the CA bundle, and the anchors it holds, at most.
const anchor_der_len = identity.ca_pem.len / 4 * 3;
const anchors_max = 1;
/// The server's address, and the address each of its datagrams comes from.
const loopback = [_]u8{ 127, 0, 0, 1 };
const server_address: client.Address = .of(&loopback, server_port);
/// What DNS knows of the server. The pool keeps the slice, and QUIC checks each datagram's address
/// against it, so it lives as long as the program.
const server_addresses = [_]client.Address{.of(&loopback, 0)};
/// Octets of each buffer `storage` lends a response, and the details and metadata it reads.
const read_len = 4096;
const entries_max = 8;

pub const Error = error{ CallUnfinished, CallWrong };

/// Octets of each buffer one call writes its request into and reads its response into.
pub const call_buffer_len = 4096;
/// The buffers of one call: its request's body, scratch and header values, and its response's
/// headers, trailers and body.
pub const CallBuffers = [7][call_buffer_len]u8;

/// The `ClientCall` buffers that `set` holds.
pub fn buffers(set: *CallBuffers) rpc.ClientCallBuffers {
    return .{
        .request = .{ .body = &set[0], .scratch = .{ .message = &set[1], .work = &set[2], .tokens = &.{} }, .values = &set[3] },
        .headers = &set[4],
        .trailers = &set[5],
        .body = &set[6],
    };
}

comptime {
    _ = @import("hooks.zig");
}

var link: Link align(@alignOf(Link)) = undefined;
var datagram_link: DatagramLink align(@alignOf(DatagramLink)) = undefined;
var datagram_output: [datagram_module.datagram_len_max]u8 = undefined;
const ReceivePool = client.ReceivePool(receive_pool_len);
var receive_pool: ReceivePool align(@alignOf(ReceivePool)) = undefined;
var anchor_der: [anchor_der_len]u8 = undefined;
var anchor_room: [anchors_max]tls.Anchor align(@alignOf(tls.Anchor)) = undefined;
var anchors: []const tls.Anchor = &.{};
var output: [client.constants.limits.stream_output_len_min]u8 = undefined;
var client_config: client.Config align(@alignOf(client.Config)) = undefined;
var pool: client.ConnectionPool align(@alignOf(client.ConnectionPool)) = undefined;
var pool_memory: [client.ConnectionPool.memory_bytes(.{})]u8 align(client.ConnectionPool.memory_alignment) = undefined;
var prng: std.Random.DefaultPrng align(@alignOf(std.Random.DefaultPrng)) = .init(0x636c69656e74);
var tcp: client.ConnectionHandle align(@alignOf(client.ConnectionHandle)) = .{ .slot = 0, .generation = 0 };
/// Whether the round runs QUIC, which speaks h3, rather than TCP.
var quic: bool = false;
/// The connections the server saw end before the round began: the round ends after one more.
var ended_before: u32 = 0;
var requested: u32 = 0;
var finished: u32 = 0;
var pool_closed: bool = false;
var spoken: ?client.Protocol align(@alignOf(client.Protocol)) = null;
var read_buffers: [4][read_len]u8 = undefined;
var details: [entries_max]connect.Detail align(@alignOf(connect.Detail)) = undefined;
var metadata: [entries_max]connect.Header align(@alignOf(connect.Header)) = undefined;

/// The server's state, which a program may check after a round.
pub const app = &link_server.app;

pub fn init() !void {
    try link.init();
    // The datagram link runs on the stream link's loops, so each side reads one clock.
    datagram_link.init(&link.loops);
    try link_server.init(&link, &datagram_link);
    // The CA the client trusts: its subject Name and SubjectPublicKeyInfo.
    anchors = try tls.pem.anchors(identity.ca_pem, &anchor_der, &anchor_room);
}

pub fn deinit() void {
    link_server.deinit();
    link.deinit();
}

/// Starts a round whose pool speaks `protocols`: h3 alone over QUIC, or h11 and h2 over TCP.
pub fn begin(protocols: client.Protocols) !void {
    // A pool that offers h3 and a TCP protocol too may open both, and this harness runs one.
    std.debug.assert(!protocols.h3 or (!protocols.h2 and !protocols.h11));
    quic = protocols.h3;
    const destination: client.Destination = .{ .addresses = &server_addresses, .port = server_port };
    if (quic) {
        // QUIC always runs TLS. The receive pool is what makes the pool offer QUIC.
        const trust: tls.Trust = .{ .web_pki = .{ .anchors = anchors, .server_name = identity.server_name } };
        client_config = .{ .tls = .{ .trust = trust, .cpu = link_server.cpu }, .authority = identity.server_name, .protocols = protocols };
        try pool.init(&pool_memory, &client_config, destination, receive_pool.storage());
    } else {
        client_config = .{ .authority = identity.server_name, .protocols = protocols };
        try pool.init(&pool_memory, &client_config, destination, null);
    }
    ended_before = link_server.ended();
    requested = 0;
    finished = 0;
    pool_closed = false;
    spoken = null;
}

/// Adds a call to the round. Both stay in place until `finish` returns.
pub fn request(call_request: *client.Request, call_response: *client.Response) !void {
    _ = try pool.request(call_request, call_response);
    requested += 1;
}

/// Runs the round until every call finished and the connection closed, and checks it spoke
/// `expected`.
pub fn finish(expected: client.Protocol) !void {
    for (0..turns_max) |_| {
        try client_turn();
        try link_server.turn();
        // The round is over once the pool closed and the server's connection ended, so the next
        // round's connection takes the server's one slot.
        if (pool_closed and link_server.ended() > ended_before) {
            if (spoken != expected) return error.CallWrong;
            return;
        }
        if (!link.pending() and !datagram_link.pending()) try link.wait(.client, sleep_ns());
    }
    return error.CallUnfinished;
}

/// Room for one response's strings, details and metadata. Each `read` reuses it, so a program
/// checks one response before it reads the next.
pub fn storage() connect.client.Storage {
    return .{
        .scratch = .{ .message = &read_buffers[0], .work = &read_buffers[1], .tokens = &read_buffers[2] },
        .octets = &read_buffers[3],
        .details = &details,
        .metadata = &metadata,
    };
}

fn client_turn() !void {
    const now_ns = link.now_ns(.client);
    try read_datagrams(now_ns);
    pool.on_instant(now_ns);
    try drain(now_ns);
    for (0..datagrams_per_turn_max) |_| {
        const sent = pool.send_datagram(&datagram_output, now_ns) orelse break;
        try datagram_link.send(.client, sent.bytes);
    }
    try drain(now_ns);
}

/// Passes the pool each datagram the UDP socket read, with the address it came from. A datagram
/// is consumed whole.
fn read_datagrams(now_ns: u64) !void {
    for (0..datagrams_per_turn_max) |_| {
        const datagram = try datagram_link.receive(.client) orelse break;
        var rest: client.Input = .{ .datagram = .{ .bytes = datagram, .from = server_address } };
        for (0..receive_calls_max) |_| {
            const received = pool.receive(rest, now_ns);
            if (received.consumed > 0) rest = .none;
            const event = received.event orelse {
                if (received.consumed == 0) break;
                continue;
            };
            try report(event, now_ns);
        }
        datagram_link.consume(.client);
    }
}

/// Passes the pool the octets the TCP socket read, or `.none` when it holds none, until it
/// consumes nothing and reports nothing.
fn drain(now_ns: u64) !void {
    const input = try link.receive(.client);
    var consumed: usize align(@alignOf(usize)) = 0;
    for (0..receive_calls_max) |_| {
        const held = input[consumed..];
        const read: client.Input = if (held.len > 0) .{ .stream = .{ .connection = tcp, .bytes = held } } else .none;
        const received = pool.receive(read, now_ns);
        consumed += received.consumed;
        const event = received.event orelse {
            if (received.consumed == 0) break;
            continue;
        };
        try report(event, now_ns);
        if (event == .close and !quic) consumed = input.len;
    }
    link.consume(.client, consumed);
}

fn report(event: client.Event, now_ns: u64) !void {
    switch (event) {
        .open => |open| try open_transport(open, now_ns),
        .send => |connection| try send_owed(connection, now_ns),
        .connected => |connected| spoken = connected.protocol,
        .finished => {
            finished += 1;
            if (finished == requested) pool.shutdown();
        },
        // The pool closed the socket, after the GOAWAY: the server reads its end. A QUIC
        // connection told the server itself, with CONNECTION_CLOSE.
        .close => if (!quic) link_server.peer_closed(),
        .closed => pool_closed = true,
        // The pool opens no second connection to resume, so it wipes the server's ticket.
        .ticket => |connection| if (pool.take_ticket(connection)) |ticket| {
            var held = ticket;
            held.wipe();
        },
    }
}

/// Starts the connection an `open` named, over the transport the round runs. The link stands
/// where a socket would be: the server accepts what the client connects.
fn open_transport(open: client.Open, now_ns: u64) !void {
    // The round checks the protocol it spoke when it ends, so a transport it did not ask for
    // fails there.
    switch (open.transport) {
        .quic => try pool.start_quic(prng.random(), now_seconds, now_ns, null),
        .tcp => {
            tcp = open.connection;
            try link_server.accept();
            try pool.start_tcp(open.connection, prng.random(), now_seconds, null);
        },
    }
}

fn send_owed(connection: client.ConnectionHandle, now_ns: u64) !void {
    for (0..sends_per_event_max) |_| {
        const written = pool.send_stream(connection, &output, now_ns);
        try link.send(.client, output[0..written]);
        if (written < output.len) return;
    }
    return error.CallWrong;
}

fn sleep_ns() u64 {
    var wait_ns: u64 align(@alignOf(u64)) = wait_ns_max;
    if (pool.deadline_ns()) |deadline_ns| wait_ns = @min(wait_ns, deadline_ns -| link.now_ns(.client));
    if (link_server.deadline_ns()) |deadline_ns| wait_ns = @min(wait_ns, deadline_ns -| link.now_ns(.server));
    return @max(wait_ns, 1);
}

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
