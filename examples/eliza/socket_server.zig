//! Example: the ELIZA service on a TCP socket, in cleartext, on Rotor's loop. Run it with `zig
//! build run-eliza-server -- [port]`, then call it with any Connect, gRPC or gRPC-Web client:
//!
//! ```sh
//! curl -sS --json '{"sentence":"I feel tired"}' \
//!   http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
//! buf curl --http2-prior-knowledge --protocol grpc --schema examples/proto \
//!   -d '{"name":"Ada"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Introduce
//! ```
//!
//! colibri does no I/O, so the program owns the sockets: it accepts, reads and writes through
//! Rotor, passes what each socket read to one `server.Endpoint`, and hands each event to the
//! router that connect_colibri's routes fill (design §8 step 5). It reads the clock once a turn,
//! through the loop, and passes the instant on.
const std = @import("std");
const assert = std.debug.assert;
const rotor = @import("rotor");
const server = @import("server");
const connect = @import("connect");
const service = @import("service.zig");

/// The sockets the server holds at once.
const sockets_max = 8;
/// The octets one socket reads, and writes, before the endpoint takes them.
const socket_buffer_len = 64 * 1024;
/// The turns the server runs before it stops: as many as a `usize` counts.
const turns_max = std.math.maxInt(usize);
/// Events one input yields to the program, at most.
const events_per_input_max = 256;
const port_default = 8080;
const now_seconds = 1_800_000_000;

/// The low bits of an operation's user data name its kind, the next its socket, and the rest the
/// socket's generation, so the completion of an operation on a closed socket is dropped.
const Kind = enum(u2) { receive, send, close };
const kind_bits = 2;
const index_bits = 8;
const accept_user_data: u64 = std.math.maxInt(u64);
const loop_options: rotor.Loop.Options = .{ .operations = sockets_max * 3 + 1 };

const Socket = struct {
    live: bool = false,
    generation: u32 = 0,
    descriptor: rotor.Descriptor = undefined,
    connection: server.ConnectionHandle = undefined,
    receiving: bool = false,
    sending: bool = false,
    closing: bool = false,
    /// The endpoint said to close, or the peer closed: the socket closes once it sent its octets.
    close_wanted: bool = false,
    input: [socket_buffer_len]u8 = undefined,
    input_len: usize = 0,
    output: [socket_buffer_len]u8 = undefined,
    output_len: usize = 0,
    output_sent: usize = 0,
};

/// chapulin's one hook, which a program that links colibri's `tls` defines (colibri decision 94).
fn assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) callconv(.c) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}

comptime {
    @export(&assert_fail, .{ .name = "ch_assert_fail", .linkage = .strong });
}

const Endpoint = server.EndpointOf(.{ .tcp_connections = sockets_max, .quic_connections = 0 });

var loop_memory: [rotor.Loop.memory_bytes(loop_options)]u8 align(rotor.memory_alignment) = undefined;
var loop: rotor.Loop = undefined;
var listener: rotor.Descriptor = undefined;
var accepting = false;
var sockets: [sockets_max]Socket = @splat(.{});
var events: [loop_options.operations]rotor.Event = undefined;
var config: server.Config align(@alignOf(server.Config)) = .{};
var endpoint: Endpoint align(@alignOf(Endpoint)) = undefined;
var router: service.Router align(@alignOf(service.Router)) = .{};
var app: service.App align(@alignOf(service.App)) = .{};
/// The server reads gzip messages and writes them when a client accepts gzip.
var gzip_decoder: connect.GzipDecoder = undefined;
var gzip_encoder: connect.GzipEncoder = undefined;
/// A cleartext endpoint draws no secret, so a seeded generator stands in for entropy.
var prng: std.Random.DefaultPrng = .init(0x656c697a61);

pub fn main(init: std.process.Init) !void {
    const port = try port_of(init);
    listener = try rotor.sync.listen(&rotor.Address.ipv4(.{ 127, 0, 0, 1 }, port), .{ .backlog = 64, .reuse_port = false });
    defer rotor.sync.close_now(listener);
    const bound = try rotor.sync.local_address(listener);
    try loop.init(&loop_memory, loop_options);
    defer loop.deinit();
    try endpoint.init(&config, prng.random(), now_seconds, loop.now_ns());
    app.codings = .{ .decoders = .{ .gzip = &gzip_decoder }, .encoder = &gzip_encoder };
    std.debug.print("listening on port {d}\n", .{bound.port});
    for (0..turns_max) |_| try turn();
}

fn port_of(init: std.process.Init) !u16 {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const text = args.next() orelse return port_default;
    return std.fmt.parseInt(u16, text, 10);
}

fn turn() !void {
    arm();
    const wait = if (endpoint.deadline_ns()) |at| @min(rotor.constants.wait_ns_max, at -| loop.now_ns()) else rotor.constants.wait_ns_max;
    const count = try loop.tick(&events, wait);
    const now_ns = loop.now_ns();
    for (events[0..count]) |event| on_event(event, now_ns);
    endpoint.on_instant(now_ns);
    for (&sockets) |*socket| {
        if (socket.live and !socket.closing) try serve_input(socket, now_ns);
    }
    try serve_events(.none, now_ns);
}

fn user_data(index: usize, kind: Kind) u64 {
    const socket = &sockets[index];
    return (@as(u64, socket.generation) << (kind_bits + index_bits)) | (@as(u64, index) << kind_bits) | @intFromEnum(kind);
}

fn submit(operation: rotor.Operation) void {
    const taken = loop.submit(&.{operation}, &.{});
    assert(taken == 1);
}

/// Starts each operation a socket waits for: an accept while a socket is free, a read while a
/// socket has room, a write of what the endpoint wrote, and a close once nothing is owed.
fn arm() void {
    if (!accepting and free_index() != null) {
        submit(rotor.Operation.accept(accept_user_data, listener, false));
        accepting = true;
    }
    for (&sockets, 0..) |*socket, index| {
        if (!socket.live or socket.closing) continue;
        const owes = socket.output_sent < socket.output_len;
        if (owes and !socket.sending) {
            submit(rotor.Operation.send(user_data(index, .send), socket.descriptor, socket.output[socket.output_sent..socket.output_len]));
            socket.sending = true;
        }
        if (socket.close_wanted and !owes and !socket.sending) {
            submit(rotor.Operation.close(user_data(index, .close), socket.descriptor));
            socket.closing = true;
            continue;
        }
        if (!socket.receiving and !socket.close_wanted and socket.input_len < socket.input.len) {
            submit(rotor.Operation.receive(user_data(index, .receive), socket.descriptor, socket.input[socket.input_len..]));
            socket.receiving = true;
        }
    }
}

fn free_index() ?usize {
    for (&sockets, 0..) |*socket, index| {
        if (!socket.live) return index;
    }
    return null;
}

fn on_event(event: rotor.Event, now_ns: u64) void {
    if (event.user_data == accept_user_data) return on_accept(event, now_ns);
    const index: usize = @intCast((event.user_data >> kind_bits) & ((1 << index_bits) - 1));
    const generation: u32 = @intCast(event.user_data >> (kind_bits + index_bits));
    const socket = &sockets[index];
    if (!socket.live or socket.generation != generation) return;
    switch (@as(Kind, @enumFromInt(@as(u2, @truncate(event.user_data))))) {
        .receive => {
            socket.receiving = false;
            const read = event.outcome() catch 0;
            // A read of 0 octets is the peer's close, and a failed read ends the socket too.
            if (read == 0) return peer_closed(socket);
            socket.input_len += read;
        },
        .send => {
            socket.sending = false;
            const sent = event.outcome() catch return peer_closed(socket);
            socket.output_sent += sent;
            if (socket.output_sent == socket.output_len) {
                socket.output_sent = 0;
                socket.output_len = 0;
            }
        },
        .close => {
            socket.live = false;
            socket.generation +%= 1;
        },
    }
}

fn peer_closed(socket: *Socket) void {
    if (socket.close_wanted) return;
    socket.close_wanted = true;
    socket.output_len = 0;
    socket.output_sent = 0;
    endpoint.transport_closed(socket.connection);
}

fn on_accept(event: rotor.Event, now_ns: u64) void {
    accepting = false;
    const descriptor: rotor.Descriptor = @intCast(event.outcome() catch return);
    const index = free_index() orelse return rotor.sync.close_now(descriptor);
    const connection = endpoint.accept(.{ .tls = false }, now_ns) orelse return rotor.sync.close_now(descriptor);
    rotor.sync.set_no_delay(descriptor, true) catch {};
    const generation = sockets[index].generation;
    sockets[index] = .{ .live = true, .generation = generation, .descriptor = descriptor, .connection = connection };
}

/// Passes the endpoint what a socket read, and keeps what it did not take.
fn serve_input(socket: *Socket, now_ns: u64) !void {
    if (socket.input_len == 0) return;
    var consumed: usize = 0;
    for (0..events_per_input_max) |_| {
        const read: server.StreamBytes = .{ .connection = socket.connection, .bytes = socket.input[consumed..socket.input_len] };
        const received = endpoint.receive(.{ .stream = read }, now_ns);
        consumed += received.consumed;
        const event = received.event orelse {
            if (received.consumed == 0) break;
            continue;
        };
        try serve(event, now_ns);
    }
    // What an event carried points into the input, so the input moves only now.
    std.mem.copyForwards(u8, socket.input[0 .. socket.input_len - consumed], socket.input[consumed..socket.input_len]);
    socket.input_len -= consumed;
}

fn serve_events(input: server.Input, now_ns: u64) !void {
    var rest = input;
    for (0..events_per_input_max) |_| {
        const received = endpoint.receive(rest, now_ns);
        rest = .none;
        try serve(received.event orelse return, now_ns);
    }
}

fn serve(event: server.Event, now_ns: u64) !void {
    if (event == .request) std.debug.print("{s} {s}\n", .{ event.request.method, event.request.target });
    switch (router.handle(&app, &endpoint, event)) {
        .taken => {},
        .event => |other| switch (other) {
            .send => |connection| flush(socket_of(connection) orelse return, now_ns),
            .close => |connection| if (socket_of(connection)) |socket| {
                socket.close_wanted = true;
            },
            .ended => |over| if (socket_of(over.connection)) |socket| {
                socket.close_wanted = true;
            },
            else => {},
        },
    }
}

fn socket_of(connection: server.ConnectionHandle) ?*Socket {
    for (&sockets) |*socket| {
        if (socket.live and std.meta.eql(socket.connection, connection)) return socket;
    }
    return null;
}

/// Writes what the endpoint owes a connection into its socket's output, as room allows. A
/// connection that owes more writes it at a later `send` event.
fn flush(socket: *Socket, now_ns: u64) void {
    if (socket.sending) return;
    const room = socket.output[socket.output_len..];
    const written = endpoint.send_stream(socket.connection, room, now_ns);
    socket.output_len += written;
}
