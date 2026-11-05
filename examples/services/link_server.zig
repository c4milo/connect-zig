//! The example server, over the in-memory links of `link.zig` and `link_datagram.zig`. A program
//! with sockets does the same with its own: it accepts a socket, passes what the socket read and
//! each datagram to the endpoint, hands each event to the router, and writes what the endpoint
//! owes.
//!
//! One endpoint serves every round. A TCP connection runs in cleartext, h2 with prior knowledge
//! or h11 (decision 13). A QUIC connection speaks h3 under the test identity of
//! `examples/testdata/tls` (decision 25).
const std = @import("std");
const server = @import("server");
const tls = @import("tls");
const identity = @import("test_identity");
const App = @import("app.zig").App;
const Router = @import("routes.zig").Router;
const Link = @import("link.zig").Link;
const datagram_module = @import("link_datagram.zig");
const DatagramLink = datagram_module.DatagramLink;

/// The octets the server writes for its TCP connection before it sends them, at most.
const output_len = 16384;
/// Events the server takes after one input, calls of `send_stream` for one `send`, and datagrams
/// it reads or writes in one turn, at most.
const events_per_turn_max = 64;
const sends_per_event_max = 8;
const datagrams_per_turn_max = 32;
/// Octets a QUIC connection holds unread, at most: what colibri's examples hold.
const receive_pool_len = 64 * 1024;
/// Room for the DER of the chain: a PEM file's DER is at most three quarters of its length.
const chain_der_len = identity.chain_pem.len / 4 * 3;
/// Unix seconds, which a program reads from its clock; colibri reads no clock. The certificates
/// are valid at this instant.
const now_seconds = identity.now_seconds;

/// The UDP port the client sends from, which a program's UDP socket reports with each datagram.
pub const client_port = 50_000;
const loopback = [_]u8{ 127, 0, 0, 1 };
const client_address: server.Address = .of(&loopback, client_port);

/// What a program probes once and passes every TLS configuration: here no CPU feature is known
/// and the thread's timing mode is not stated, so each session runs ChaCha20 alone.
pub const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known },
    .timing = .not_stated,
};

pub const Error = error{ ExchangeWrong, SendUnfinished };

/// One TCP connection and one QUIC connection at a time: each round opens one.
const Endpoint = server.EndpointOf(.{ .tcp_connections = 1, .quic_connections = 1, .receive_pool_len = receive_pool_len });

// The endpoint holds hundreds of kilobytes, so it lives outside the stack.
var link: *Link align(@alignOf(*Link)) = undefined;
var datagram_link: *DatagramLink align(@alignOf(*DatagramLink)) = undefined;
var output: [output_len]u8 = undefined;
var datagram_output: [datagram_module.datagram_len_max]u8 = undefined;
var chain_der: [chain_der_len]u8 = undefined;
var chain_room: [tls.constants.limits.certificate_chain_len_max][]const u8 = undefined;
var key: tls.Key align(@alignOf(tls.Key)) = .{};
var identities: [1]tls.Identity align(@alignOf(tls.Identity)) = undefined;
var cookie_key: [tls.constants.protocol.server_key_len]u8 = undefined;
var ticket_key: [tls.constants.protocol.server_key_len]u8 = undefined;
var config: server.Config align(@alignOf(server.Config)) = .{};
var endpoint: Endpoint align(@alignOf(Endpoint)) = undefined;
var router: Router align(@alignOf(Router)) = .{};
pub var app: App align(@alignOf(App)) = .{};
var accepted: ?server.ConnectionHandle align(@alignOf(server.ConnectionHandle)) = null;
/// The connections that ended, TCP and QUIC alike: a round is over once one more ended.
var ended_count: u32 = 0;
/// A test draws no secret, so a seeded generator stands in for entropy: each run replays.
var prng: std.Random.DefaultPrng align(@alignOf(std.Random.DefaultPrng)) = .init(0x656c697a61);

pub fn init(stream: *Link, datagrams: *DatagramLink) !void {
    link = stream;
    datagram_link = datagrams;
    prng.random().bytes(&cookie_key);
    prng.random().bytes(&ticket_key);
    // The chain, the end-entity first, and the P-256 key the end-entity certificate carries.
    const chain = try tls.pem.chain(identity.chain_pem, &chain_der, &chain_room);
    try tls.pem.key(cpu, identity.key_pem, chain[0], &key);
    identities[0] = .{ .chain = chain, .key = &key };
    // The identity serves QUIC, which names h3. A TCP socket the program accepts with `.tls =
    // false` stays in cleartext.
    config = .{ .tls = .{
        .identities = &identities,
        .cookie_key = &cookie_key,
        .ticket_key = &ticket_key,
        .cpu = cpu,
    } };
    try endpoint.init(&config, prng.random(), now_seconds, link.now_ns(.server));
}

/// Wipes the key's scalar, which no session uses any more.
pub fn deinit() void {
    key.wipe();
}

/// Accepts the socket the client connected, in cleartext.
pub fn accept() !void {
    accepted = endpoint.accept(.{ .tls = false }, link.now_ns(.server)) orelse return error.ExchangeWrong;
}

/// One turn of the server: fire its deadlines, pass the endpoint what the socket read and each
/// datagram, act on every event, and send every datagram it owes.
pub fn turn() !void {
    const input = try link.receive(.server);
    const now_ns = link.now_ns(.server);
    endpoint.on_instant(now_ns);
    try read_stream(input, now_ns);
    try read_datagrams(now_ns);
    try serve_all(.none, now_ns);
    for (0..datagrams_per_turn_max) |_| {
        const sent = endpoint.send_datagram(&datagram_output, now_ns) orelse break;
        try datagram_link.send(.server, sent.bytes);
    }
}

fn read_stream(input: []u8, now_ns: u64) !void {
    const connection = accepted orelse return;
    var consumed: usize align(@alignOf(usize)) = 0;
    for (0..events_per_turn_max) |_| {
        const read: server.StreamBytes = .{ .connection = connection, .bytes = input[consumed..] };
        const received = endpoint.receive(.{ .stream = read }, now_ns);
        consumed += received.consumed;
        const event = received.event orelse {
            if (received.consumed == 0) break;
            continue;
        };
        try serve(event, now_ns);
    }
    link.consume(.server, consumed);
}

/// Passes the endpoint each datagram the UDP socket read, with the address it came from.
fn read_datagrams(now_ns: u64) !void {
    for (0..datagrams_per_turn_max) |_| {
        const datagram = try datagram_link.receive(.server) orelse break;
        try serve_all(.{ .datagram = .{ .bytes = datagram, .from = client_address } }, now_ns);
        datagram_link.consume(.server);
    }
}

/// Passes `input` to the endpoint, then takes every event it reports until it reports none.
fn serve_all(input: server.Input, now_ns: u64) !void {
    var rest = input;
    for (0..events_per_turn_max) |_| {
        const received = endpoint.receive(rest, now_ns);
        rest = .none;
        try serve(received.event orelse return, now_ns);
    }
}

fn serve(event: server.Event, now_ns: u64) !void {
    switch (router.handle(&app, &endpoint, event)) {
        .taken => {},
        .event => |other| switch (other) {
            .send => |connection| try flush(connection, now_ns),
            .close => {},
            .ended => |over| {
                if (over.failed) return error.ExchangeWrong;
                if (accepted == over.connection) accepted = null;
                ended_count += 1;
            },
            else => return error.ExchangeWrong,
        },
    }
}

fn flush(connection: server.ConnectionHandle, now_ns: u64) !void {
    for (0..sends_per_event_max) |_| {
        const written = endpoint.send_stream(connection, &output, now_ns);
        try link.send(.server, output[0..written]);
        if (written < output.len) return;
    }
    return error.SendUnfinished;
}

/// The client closed its socket. A program learns it from a read of 0 octets, and the link has no
/// such read, so the client's side says it here. The endpoint then ends the connection.
pub fn peer_closed() void {
    const connection = accepted orelse return;
    endpoint.transport_closed(connection);
}

/// The connections that ended so far, over TCP and QUIC.
pub fn ended() u32 {
    return ended_count;
}

pub fn deadline_ns() ?u64 {
    return endpoint.deadline_ns();
}
