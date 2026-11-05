//! Example: a client calls the ELIZA service over colibri, in each protocol its client speaks,
//! and checks every answer (design §8 step 5).
//!
//! Both sides run in one process over the in-memory link of `link.zig`, in cleartext, as
//! colibri's examples do. The run has two rounds: one over h2 with prior knowledge, one over h11.
//! In each, one `client.ConnectionPool` carries these calls at once:
//!
//! - Say over Connect with the proto codec, as a POST;
//! - Say over Connect with the JSON codec, as a GET, since Say has no side effects;
//! - Introduce, a server stream, over gRPC-Web;
//! - Converse, a bidirectional stream sent half-duplex, over Connect with JSON;
//! - Say with an empty sentence over gRPC, which fails with invalid_argument. The server sends
//!   that error Trailers-Only, which colibri's client reads; a gRPC success needs trailers it does
//!   not expose yet (decision 11).
//!
//! Anything other than the expected answers exits with an error, which is how `zig build
//! examples` and CI know the example works. Run it with `zig build example-eliza`.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const adapter = @import("connect_colibri");
const eliza = @import("eliza");
const service = @import("service.zig");
const link_server = @import("link_server.zig");
const link_module = @import("link.zig");
const Link = link_module.Link;
const Service = eliza.ElizaService;

/// Turns of the client and the server in one round before the example gives up.
const turns_max = 256;
const sends_per_event_max = 16;
const receive_calls_max = 4096;
/// The longest the program sleeps when no octet waits: 100 ms.
const wait_ns_max: u64 = 100_000_000;
const now_seconds = 1_800_000_000;
const calls_count = 5;
/// Octets of each call's request, response and header values.
const buffer_len = 4096;

pub const Error = error{ ExchangeUnfinished, ExchangeWrong };

/// chapulin's one hook, which a program that links colibri's `tls` defines (colibri decision 94).
fn assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) callconv(.c) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}

comptime {
    @export(&assert_fail, .{ .name = "ch_assert_fail", .linkage = .strong });
}

var link: Link align(@alignOf(Link)) = undefined;
var output: [client.constants.limits.stream_output_len_min]u8 = undefined;
var client_config: client.Config align(@alignOf(client.Config)) = undefined;
var pool: client.ConnectionPool align(@alignOf(client.ConnectionPool)) = undefined;
var pool_memory: [client.ConnectionPool.memory_bytes(.{})]u8 align(client.ConnectionPool.memory_alignment) = undefined;
var prng: std.Random.DefaultPrng align(@alignOf(std.Random.DefaultPrng)) = .init(0x636c69656e74);
var tcp: client.ConnectionHandle align(@alignOf(client.ConnectionHandle)) = .{ .slot = 0, .generation = 0 };
var finished: u32 = 0;
var pool_closed: bool = false;
var spoken: ?client.Protocol align(@alignOf(client.Protocol)) = null;

var say_proto: adapter.Exchange(Service.say) align(@alignOf(adapter.Exchange(Service.say))) = undefined;
var say_get: adapter.Exchange(Service.say) align(@alignOf(adapter.Exchange(Service.say))) = undefined;
var introduce: adapter.Exchange(Service.introduce) align(@alignOf(adapter.Exchange(Service.introduce))) = undefined;
var converse: adapter.Exchange(Service.converse) align(@alignOf(adapter.Exchange(Service.converse))) = undefined;
var say_empty: adapter.Exchange(Service.say) align(@alignOf(adapter.Exchange(Service.say))) = undefined;
var buffers: [calls_count][6][buffer_len]u8 = undefined;
var read_buffers: [4][buffer_len]u8 = undefined;
var details: [4]connect.Detail align(@alignOf(connect.Detail)) = undefined;
var metadata: [8]connect.Header align(@alignOf(connect.Header)) = undefined;

pub fn main() !void {
    try link.init();
    defer link.deinit();
    try link_server.init(&link);
    try round(.{ .h11 = false, .h3 = false }, .h2);
    try round(.{ .h2 = false, .h3 = false }, .h11);
    std.debug.print("eliza: every call answered as expected over h2 and h11\n", .{});
}

fn buffers_of(index: usize) adapter.ExchangeBuffers {
    const set = &buffers[index];
    return .{
        .request = .{ .body = &set[0], .scratch = .{ .message = &set[1], .work = &set[2], .tokens = &.{} }, .values = &set[3] },
        .values = &set[4],
        .body = &set[5],
    };
}

fn round(protocols: client.Protocols, expected: client.Protocol) !void {
    client_config = .{ .authority = "localhost", .protocols = protocols };
    const loopback = [_]u8{ 127, 0, 0, 1 };
    const addresses = [_]client.Address{.of(&loopback, 0)};
    try pool.init(&pool_memory, &client_config, .{ .addresses = &addresses, .port = 80 }, null);
    finished = 0;
    pool_closed = false;
    try say_proto.init(.{}, &.{.{ .sentence = service.said }}, buffers_of(0));
    try say_get.init(.{ .codec = .json, .use_get = true }, &.{.{ .sentence = service.said }}, buffers_of(1));
    try introduce.init(.{ .protocol = .grpc_web }, &.{.{ .name = service.name }}, buffers_of(2));
    try converse.init(.{ .codec = .json }, &.{ .{ .sentence = service.conversation[0] }, .{ .sentence = service.conversation[1] } }, buffers_of(3));
    try say_empty.init(.{ .protocol = .grpc }, &.{.{}}, buffers_of(4));
    _ = try pool.request(&say_proto.request, &say_proto.response);
    _ = try pool.request(&say_get.request, &say_get.response);
    _ = try pool.request(&introduce.request, &introduce.response);
    _ = try pool.request(&converse.request, &converse.response);
    _ = try pool.request(&say_empty.request, &say_empty.response);
    for (0..turns_max) |_| {
        try client_turn();
        try link_server.turn();
        // The round is over once the pool closed and the server's connection ended, so the next
        // round's socket takes the server's one slot.
        if (pool_closed and link_server.idle()) {
            if (spoken != expected) return error.ExchangeWrong;
            return check();
        }
        if (!link.pending()) try link.wait(.client, sleep_ns());
    }
    return error.ExchangeUnfinished;
}

fn client_turn() !void {
    const now_ns = link.now_ns(.client);
    pool.on_instant(now_ns);
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
        if (event == .close) consumed = input.len;
    }
    link.consume(.client, consumed);
}

fn report(event: client.Event, now_ns: u64) !void {
    switch (event) {
        .open => |open| {
            if (open.transport != .tcp) return error.ExchangeWrong;
            tcp = open.connection;
            // The link stands where a socket would be: the server accepts what the client connects.
            try link_server.accept();
            try pool.start_tcp(open.connection, prng.random(), now_seconds, null);
        },
        .send => |connection| try send_owed(connection, now_ns),
        .connected => |connected| spoken = connected.protocol,
        .finished => {
            finished += 1;
            if (finished == calls_count) pool.shutdown();
        },
        // The pool closed the socket, after the GOAWAY: the server reads its end.
        .close => link_server.peer_closed(),
        .closed => pool_closed = true,
        else => {},
    }
}

fn send_owed(connection: client.ConnectionHandle, now_ns: u64) !void {
    for (0..sends_per_event_max) |_| {
        const written = pool.send_stream(connection, &output, now_ns);
        try link.send(.client, output[0..written]);
        if (written < output.len) return;
    }
    return error.ExchangeWrong;
}

fn sleep_ns() u64 {
    var wait_ns: u64 align(@alignOf(u64)) = wait_ns_max;
    if (pool.deadline_ns()) |deadline_ns| wait_ns = @min(wait_ns, deadline_ns -| link.now_ns(.client));
    if (link_server.deadline_ns()) |deadline_ns| wait_ns = @min(wait_ns, deadline_ns -| link.now_ns(.server));
    return @max(wait_ns, 1);
}

fn storage() connect.client.Storage {
    return .{
        .scratch = .{ .message = &read_buffers[0], .work = &read_buffers[1], .tokens = &read_buffers[2] },
        .octets = &read_buffers[3],
        .details = &details,
        .metadata = &metadata,
    };
}

/// Reads every message of a response and checks each sentence, then success.
fn expect_sentences(response: *connect.client.Response, comptime T: type, sentences: []const []const u8) !void {
    for (sentences) |sentence| {
        const message = try response.next(T) orelse return error.ExchangeWrong;
        if (!std.mem.eql(u8, message.sentence, sentence)) {
            std.debug.print("eliza: got \"{s}\", wanted \"{s}\"\n", .{ message.sentence, sentence });
            return error.ExchangeWrong;
        }
    }
    if (try response.next(T) != null) return error.ExchangeWrong;
    if (response.failure) |failure| {
        std.debug.print("eliza: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.ExchangeWrong;
    }
}

fn check() !void {
    var said_proto = say_proto.read(storage());
    try expect_sentences(&said_proto, eliza.SayResponse, &.{service.say_answer});
    var said_get = say_get.read(storage());
    try expect_sentences(&said_get, eliza.SayResponse, &.{service.say_answer});
    var introduced = introduce.read(storage());
    try expect_sentences(&introduced, eliza.IntroduceResponse, &service.introduce_answers);
    var conversed = converse.read(storage());
    try expect_sentences(&conversed, eliza.ConverseResponse, &service.converse_answers);
    if (conversed.metadata.len != 1 or !std.mem.eql(u8, conversed.metadata[0].value, "done")) return error.ExchangeWrong;
    var empty = say_empty.read(storage());
    if (try empty.next(eliza.SayResponse) != null) return error.ExchangeWrong;
    const failure = empty.failure orelse return error.ExchangeWrong;
    if (failure.code != .invalid_argument or !std.mem.eql(u8, failure.message, "say something")) return error.ExchangeWrong;
    std.debug.print("eliza: round over {s} answered\n", .{@tagName(spoken.?)});
}
