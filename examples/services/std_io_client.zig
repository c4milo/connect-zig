//! A client loop over a real TCP socket, with no Rotor (decision 32): one `client.ConnectionPool`
//! that the program drives by hand through Zig 0.16's `std.Io`. It opens the socket the pool
//! asks for, passes the pool what the socket read, writes what the pool owes, and reads the
//! clock through `std.Io` for each instant it passes. It runs in cleartext, over h2 with prior
//! knowledge or h11 (decision 13).
//!
//! A program calls `begin` with the protocols the round may speak, `request` for each call,
//! then `finish`, which runs the pool until every call finished and the socket closed.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const Io = std.Io;
const net = std.Io.net;

/// Turns of the loop in one round before the program gives up, and the longest one turn waits
/// for the socket: 100 ms. A round thus ends within about a minute, even against a server that
/// never answers.
const turns_max = 512;
const wait_ns_max: u64 = 100 * std.time.ns_per_ms;
/// Calls of `receive` in one drain, and calls of `send_stream` for one `send`, at most.
const receive_calls_max = 4096;
const sends_per_event_max = 16;
/// Octets the socket read that the pool has not consumed yet, at most.
const held_len_max = 64 * 1024;
/// Octets of each buffer `storage` lends a response, and the details and metadata it reads.
const read_len = 4096;
const entries_max = 8;
/// Octets of each buffer one call writes its request into and reads its response into.
const call_buffer_len = 4096;
/// The buffers of one call: its request's body, scratch and header values, and its response's
/// headers, trailers and body.
pub const CallBuffers = [7][call_buffer_len]u8;

/// The server's address, as the pool names it: the port goes in the `Destination`.
const loopback = [_]u8{ 127, 0, 0, 1 };
const server_addresses = [_]client.Address{.of(&loopback, 0)};
const authority = "127.0.0.1";

pub const Error = error{ CallUnfinished, CallWrong, InputTooLong };

const Pool = client.ConnectionPool(.{ .quic = false });
var pool: Pool align(@alignOf(Pool)) = undefined;
var pool_memory: [Pool.memory_bytes(.{})]u8 align(Pool.memory_alignment) = undefined;
var client_config: client.Config align(@alignOf(client.Config)) = undefined;
var output: [client.constants.limits.stream_output_len_min]u8 align(@alignOf(u64)) = undefined;
var held: [held_len_max]u8 align(@alignOf(u64)) = undefined;
var held_len: usize = 0;
var read_buffers: [4][read_len]u8 align(@alignOf(u64)) = undefined;
var details: [entries_max]connect.Detail align(@alignOf(connect.Detail)) = undefined;
var metadata: [entries_max]connect.Header align(@alignOf(connect.Header)) = undefined;
var random_source: std.Random.IoSource align(@alignOf(std.Random.IoSource)) = undefined;
/// The socket of the round's connection, while it is open.
var stream: ?net.Stream align(@alignOf(net.Stream)) = null;
var tcp: client.ConnectionHandle align(@alignOf(client.ConnectionHandle)) = .{ .slot = 0, .generation = 0 };
var port: u16 = 0;
var requested: u32 = 0;
var finished: u32 = 0;
var pool_closed: bool = false;
var spoken: ?client.Protocol align(@alignOf(client.Protocol)) = null;

/// The `ClientCall` buffers that `set` holds.
pub fn buffers(set: *CallBuffers) rpc.ClientCallBuffers {
    return .{
        .request = .{ .body = &set[0], .scratch = .{ .message = &set[1], .work = &set[2], .tokens = &.{} }, .values = &set[3] },
        .headers = &set[4],
        .trailers = &set[5],
        .body = &set[6],
    };
}

/// Starts a round whose pool speaks `protocols` to the server on `server_port`.
pub fn begin(io: Io, protocols: client.Protocols, server_port: u16) !void {
    std.debug.assert(!protocols.h3);
    random_source = .{ .io = io };
    port = server_port;
    client_config = .{ .authority = authority, .protocols = protocols };
    try pool.init(&pool_memory, &client_config, .{ .addresses = &server_addresses, .port = port }, null);
    held_len = 0;
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

/// Room for one response's strings, details and metadata. Each `read` reuses it.
pub fn storage() connect.client.Storage {
    return .{
        .scratch = .{ .message = &read_buffers[0], .work = &read_buffers[1], .tokens = &read_buffers[2] },
        .octets = &read_buffers[3],
        .details = &details,
        .metadata = &metadata,
    };
}

fn now_ns(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// Runs the round until every call finished and the socket closed, and checks it spoke
/// `expected`.
pub fn finish(io: Io, expected: client.Protocol) !void {
    for (0..turns_max) |_| {
        const now = now_ns(io);
        pool.on_instant(now);
        try drain(io, now);
        if (pool_closed) {
            if (spoken != expected) return error.CallWrong;
            return;
        }
        try wait(io, now);
    }
    close_socket(io);
    return error.CallUnfinished;
}

/// Waits for the socket to read, until the pool's next deadline or `wait_ns_max`.
fn wait(io: Io, now: u64) !void {
    var wait_ns: u64 = wait_ns_max;
    if (pool.deadline_ns()) |deadline_ns| wait_ns = @min(wait_ns, deadline_ns -| now);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(@max(wait_ns, 1)), .clock = .awake } };
    const open = stream orelse return io.sleep(timeout.duration.raw, .awake);
    if (held_len == held.len) return error.InputTooLong;
    const file: Io.File = .{ .handle = open.socket.handle, .flags = .{ .nonblocking = false } };
    const operation: Io.Operation = .{ .file_read_streaming = .{ .file = file, .data = &.{held[held_len..]} } };
    const result = io.operateTimeout(operation, timeout) catch |failure| switch (failure) {
        error.Timeout => return,
        else => return failure,
    };
    const len = result.file_read_streaming catch {
        // The server closed the socket, or it failed: the pool ends the connection.
        pool.transport_closed(tcp);
        close_socket(io);
        return;
    };
    held_len += len;
}

/// Passes the pool the octets the socket read, or `.none` when it holds none, until it consumes
/// nothing and reports nothing.
fn drain(io: Io, now: u64) !void {
    var consumed: usize = 0;
    for (0..receive_calls_max) |_| {
        const rest = held[consumed..held_len];
        const input: client.Input = if (rest.len > 0) .{ .stream = .{ .connection = tcp, .bytes = rest } } else .none;
        const received = pool.receive(input, now);
        consumed += received.consumed;
        const event = received.event orelse {
            if (received.consumed == 0) break;
            continue;
        };
        try report(io, event, now);
        if (event == .close) consumed = held_len;
    }
    std.mem.copyForwards(u8, held[0 .. held_len - consumed], held[consumed..held_len]);
    held_len -= consumed;
}

fn report(io: Io, event: client.Event, now: u64) !void {
    switch (event) {
        .open => |open| try open_socket(io, open),
        .send => |connection| try send_owed(io, connection, now),
        .connected => |connected| spoken = connected.protocol,
        .finished => {
            finished += 1;
            if (finished == requested) pool.shutdown();
        },
        // The pool sent its GOAWAY, or is done with h11: the program closes the socket.
        .close => close_socket(io),
        .closed => pool_closed = true,
        // No call of these rounds streams (colibri decision 153).
        .headers, .body, .body_taken => return error.CallWrong,
        // The pool opens no second connection to resume, so it wipes the server's ticket.
        .ticket => |connection| if (pool.take_ticket(connection)) |ticket| {
            var kept = ticket;
            kept.wipe();
        },
    }
}

/// Connects the socket an `open` named, and starts the pool's connection on it.
fn open_socket(io: Io, open: client.Open) !void {
    if (open.transport != .tcp) return error.CallWrong;
    const address: net.IpAddress = .{ .ip4 = .loopback(port) };
    tcp = open.connection;
    stream = address.connect(io, .{ .mode = .stream }) catch {
        // No socket, so the pool ends the connection and fails its calls.
        pool.transport_closed(open.connection);
        return;
    };
    try pool.start_tcp(open.connection, random_source.interface(), 0, null);
}

fn send_owed(io: Io, connection: client.ConnectionHandle, now: u64) !void {
    const open = stream orelse return error.CallWrong;
    var writer = open.writer(io, &.{});
    for (0..sends_per_event_max) |_| {
        const written = pool.send_stream(connection, &output, now);
        try writer.interface.writeAll(output[0..written]);
        if (written < output.len) return;
    }
    return error.CallWrong;
}

fn close_socket(io: Io) void {
    const open = stream orelse return;
    open.close(io);
    stream = null;
    held_len = 0;
}

/// Checks a response holds no message more, and ended in success.
pub fn expect_end(response: *connect.client.Response, comptime T: type) !void {
    if (try response.next(T) != null) return error.CallWrong;
    if (response.failure) |failure| {
        std.debug.print("std_io: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.CallWrong;
    }
}
