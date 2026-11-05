//! The example server, over the in-memory link of `link.zig` in cleartext. A
//! program with sockets does the same with its own: it accepts a socket, passes what the socket
//! read to the endpoint, hands each event to the router, and writes what the endpoint owes.
const std = @import("std");
const server = @import("server");
const App = @import("app.zig").App;
const Router = @import("routes.zig").Router;
const link_module = @import("link.zig");
const Link = link_module.Link;

/// The octets the server writes for its connection before it sends them, at most.
const output_len = 16384;
/// Events the server takes after one input, and calls of `send_stream` for one `send`, at most.
const events_per_turn_max = 64;
const sends_per_event_max = 8;
/// Unix seconds, which a program reads from its clock; colibri reads no clock.
const now_seconds = 1_800_000_000;

pub const Error = error{ ExchangeWrong, SendUnfinished };

/// One TCP connection at a time, and no QUIC: the example opens one socket for each round.
const Endpoint = server.EndpointOf(.{ .tcp_connections = 1, .quic_connections = 0 });

// The endpoint holds hundreds of kilobytes, so it lives outside the stack.
var link: *Link align(@alignOf(*Link)) = undefined;
var output: [output_len]u8 = undefined;
/// No TLS: the endpoint speaks h2 when a connection opens with h2's preface, and h11 otherwise.
var config: server.Config align(@alignOf(server.Config)) = .{};
var endpoint: Endpoint align(@alignOf(Endpoint)) = undefined;
var router: Router align(@alignOf(Router)) = .{};
pub var app: App align(@alignOf(App)) = .{};
var accepted: ?server.ConnectionHandle align(@alignOf(server.ConnectionHandle)) = null;
/// A cleartext endpoint draws no secret, so a seeded generator stands in for entropy.
var prng: std.Random.DefaultPrng align(@alignOf(std.Random.DefaultPrng)) = .init(0x656c697a61);

pub fn init(stream: *Link) !void {
    link = stream;
    try endpoint.init(&config, prng.random(), now_seconds, link.now_ns(.server));
}

/// Accepts the socket the client connected.
pub fn accept() !void {
    accepted = endpoint.accept(.{ .tls = false }, link.now_ns(.server)) orelse return error.ExchangeWrong;
}

pub fn turn() !void {
    const input = try link.receive(.server);
    const now_ns = link.now_ns(.server);
    endpoint.on_instant(now_ns);
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

fn serve(event: server.Event, now_ns: u64) !void {
    switch (router.handle(&app, &endpoint, event)) {
        .taken => {},
        .event => |other| switch (other) {
            .send => |connection| try flush(connection, now_ns),
            .close => {},
            .ended => |over| {
                if (over.failed) return error.ExchangeWrong;
                accepted = null;
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

/// Whether the server holds no connection: the last one ended.
pub fn idle() bool {
    return accepted == null;
}

pub fn deadline_ns() ?u64 {
    return endpoint.deadline_ns();
}
