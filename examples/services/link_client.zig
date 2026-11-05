//! The example client's loop over the in-memory link: one `client.ConnectionPool` that carries a
//! round of calls to the server of `link_server.zig`, in cleartext, as colibri's examples do.
//!
//! A program calls `init` once, then for each round:
//!
//! 1. `begin` with the protocols the pool may speak;
//! 2. `request` for each call, with the colibri request and response of an `Exchange`;
//! 3. `finish` with the protocol the round must speak, which runs client and server until every
//!    call finished and the connection closed;
//! 4. `read` on each exchange, with `storage()`, to check what arrived.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const link_server = @import("link_server.zig");
const Link = @import("link.zig").Link;

/// Turns of the client and the server in one round before the example gives up.
const turns_max = 512;
const sends_per_event_max = 16;
const receive_calls_max = 4096;
/// The longest the program sleeps when no octet waits: 100 ms.
const wait_ns_max: u64 = 100_000_000;
/// Unix seconds, which a program reads from its clock; colibri reads no clock.
const now_seconds = 1_800_000_000;
/// Octets of each buffer `storage` lends a response, and the details and metadata it reads.
const read_len = 4096;
const entries_max = 8;

pub const Error = error{ ExchangeUnfinished, ExchangeWrong };

/// Octets of each buffer one call writes its request into and reads its response into.
pub const call_buffer_len = 4096;
/// The buffers of one call: its request's body, scratch and header values, and its response's
/// header values and body.
pub const CallBuffers = [6][call_buffer_len]u8;

/// The `Exchange` buffers that `set` holds.
pub fn buffers(set: *CallBuffers) rpc.ExchangeBuffers {
    return .{
        .request = .{ .body = &set[0], .scratch = .{ .message = &set[1], .work = &set[2], .tokens = &.{} }, .values = &set[3] },
        .values = &set[4],
        .body = &set[5],
    };
}

comptime {
    _ = @import("hooks.zig");
}

var link: Link align(@alignOf(Link)) = undefined;
var output: [client.constants.limits.stream_output_len_min]u8 = undefined;
var client_config: client.Config align(@alignOf(client.Config)) = undefined;
var pool: client.ConnectionPool align(@alignOf(client.ConnectionPool)) = undefined;
var pool_memory: [client.ConnectionPool.memory_bytes(.{})]u8 align(client.ConnectionPool.memory_alignment) = undefined;
var prng: std.Random.DefaultPrng align(@alignOf(std.Random.DefaultPrng)) = .init(0x636c69656e74);
var tcp: client.ConnectionHandle align(@alignOf(client.ConnectionHandle)) = .{ .slot = 0, .generation = 0 };
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
    try link_server.init(&link);
}

pub fn deinit() void {
    link.deinit();
}

/// Starts a round whose pool speaks `protocols`.
pub fn begin(protocols: client.Protocols) !void {
    client_config = .{ .authority = "localhost", .protocols = protocols };
    const loopback = [_]u8{ 127, 0, 0, 1 };
    const addresses = [_]client.Address{.of(&loopback, 0)};
    try pool.init(&pool_memory, &client_config, .{ .addresses = &addresses, .port = 80 }, null);
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
        // round's socket takes the server's one slot.
        if (pool_closed and link_server.idle()) {
            if (spoken != expected) return error.ExchangeWrong;
            return;
        }
        if (!link.pending()) try link.wait(.client, sleep_ns());
    }
    return error.ExchangeUnfinished;
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
            if (finished == requested) pool.shutdown();
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

/// Checks a response holds no message more, and ended in success.
pub fn expect_end(response: *connect.client.Response, comptime T: type) !void {
    if (try response.next(T) != null) return error.ExchangeWrong;
    if (response.failure) |failure| {
        std.debug.print("example: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.ExchangeWrong;
    }
}

/// Checks `trailers` holds a trailer `name` with `value`.
pub fn expect_trailer(trailers: []const connect.Header, name: []const u8, value: []const u8) !void {
    for (trailers) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            if (std.mem.eql(u8, entry.value, value)) return;
            std.debug.print("example: trailer {s} is {s}, wanted {s}\n", .{ name, entry.value, value });
            return error.ExchangeWrong;
        }
    }
    std.debug.print("example: no trailer {s}\n", .{name});
    return error.ExchangeWrong;
}
