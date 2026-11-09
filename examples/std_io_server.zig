//! Example: the ELIZA service on a TCP socket, with no Rotor at all (decision 32). The program
//! drives colibri's sans-I/O `server.Engine` itself, over Zig 0.16's `std.Io` sockets, tasks and
//! clocks. Run it with `zig build run-std-io-server -- [port]`, then call it with any Connect,
//! gRPC or gRPC-Web client:
//!
//! ```sh
//! curl -sS --json '{"sentence":"I feel tired"}' \
//!   http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
//! buf curl --http2-prior-knowledge --protocol grpc --schema examples/proto \
//!   -d '{"name":"Ada"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Introduce
//! ```
//!
//! It serves h11 and h2 with prior knowledge, in cleartext (decision 13). It holds no TLS
//! identity and opens no UDP socket, so it serves no h3: `examples/socket_server.zig` does that,
//! on `colibri.Server`.
//!
//! One task owns the engine, since the engine serves every connection from one thread. Other
//! tasks only wait: one accepts sockets while an entry is free, one reads each socket, and one
//! wakes the owner every `tick_ns`. Each sends what it got to the owner through one bounded `std.Io.Queue`, and blocks
//! while the queue is full. The owner takes one message at a time, hands it to the engine, and
//! writes what the engine owes to the sockets itself. So no lock guards the engine, and a read
//! never waits on a write. The ticks fire the engine's deadlines, at most `tick_ns` late: a queue
//! has no wait with a timeout, and a tick is the plainest way to get one. A write blocks the
//! owner until the kernel takes the octets, which a loopback client always does; a server for
//! slow clients gives each socket a writer task too.
//!
//! The program reads the clock and draws entropy through `std.Io`, and passes the engine each
//! instant as a value: colibri reads no clock (decision 3).
const std = @import("std");
const server = @import("server");
const rpc = @import("connect_colibri");
const Service = @import("eliza").ElizaService;
const App = @import("services/app.zig").App;
const eliza = @import("services/eliza.zig");
const Io = std.Io;
const net = std.Io.net;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (colibri decision 94).
    _ = @import("services/hooks.zig");
}

const port_default = 8080;

/// Sockets the server serves at once, at most. One past them waits in the kernel's backlog until
/// a socket closes, as `colibri.Server` rules (decision 31).
const connections_max = 16;
/// Octets one read of a socket takes, at most: the payload of one message to the owner.
const chunk_len = 4096;
/// Octets of a socket the engine has not consumed yet, at most. A connection past it fails.
const held_len_max = 64 * 1024;
/// Octets one `send_stream` writes, at most.
const output_len = 16 * 1024;
/// Messages waiting for the owner, at most. A task that finds the queue full waits.
const queue_len = 32;
/// The longest a deadline of the engine waits past its instant: 50 ms.
const tick_ns = 50 * std.time.ns_per_ms;
/// A socket that sends no request for 5 s closes: the self-check of `std_io.zig` waits for it.
const first_request_timeout_ns = 5 * std.time.ns_per_s;
/// Messages the owner takes, sockets the server accepts and ticks it counts before it stops: far
/// past any run, so every loop of the program is bounded.
const messages_max = std.math.maxInt(u64);
/// Reads of one socket before its reader stops, at most.
const reads_max = std.math.maxInt(u64);
/// Calls of `receive` in one pass over a socket's octets, passes of one step, and calls of
/// `send_stream` in one flush, at most.
const events_per_step_max = 64;
const passes_max = 16;
const sends_per_flush_max = 16;

/// TCP connections alone: the program opens no UDP socket.
const Engine = server.Engine(.{ .tcp_connections = connections_max, .quic_connections = 0 });

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

/// ELIZA's routes, and the 405 a method Connect does not serve gets (decision 27).
const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = eliza.routes ++ rpc.Refusals(App, Service.say).routes,
}, .{ .requests = 8, .response_bytes = 64 * 1024, .body_bytes = 64 * 1024 });

/// What a task tells the owner.
const Message = union(enum) {
    /// The listener accepted this socket.
    accepted: net.Stream,
    /// The socket of entry `entry` read `len` octets.
    read: Chunk,
    /// The reader of entry `entry` stopped: its socket ended, failed or was shut down.
    ended: u32,
    /// `tick_ns` passed.
    tick,
    /// The listener failed, and accepts no more.
    listener_failed,
};

const Chunk = struct { entry: u32, len: u32, bytes: [chunk_len]u8 };

/// What the owner holds for one socket. The entry outlives the engine's connection: the engine
/// ends it at `close`, and the socket closes once its reader stopped.
const Entry = struct {
    stream: net.Stream = undefined,
    /// The socket is open: its reader runs, or it stopped and the owner has not closed it yet.
    open: bool = false,
    handle: server.ConnectionHandle = .{ .slot = 0, .generation = 0 },
    /// The engine holds the connection: it has not reported its `ended`.
    attached: bool = false,
    /// The engine reported `close`, or the connection failed: the socket shuts down once its
    /// octets are out.
    closing: bool = false,
    /// The owner shut the socket down, which stops its reader.
    shut: bool = false,
    /// The connection owes octets no `send_stream` has taken.
    send_owed: bool = false,
    held_len: usize = 0,
};

var engine: Engine align(@alignOf(Engine)) = undefined;
var config: server.Config align(@alignOf(server.Config)) = .{ .timeouts = .{ .first_request_ns = first_request_timeout_ns } };
var router: Router align(@alignOf(Router)) = .{};
var app: App align(@alignOf(App)) = .{};
var entries: [connections_max]Entry align(@alignOf(Entry)) = @splat(.{});
var held: [connections_max][held_len_max]u8 align(@alignOf(u64)) = undefined;
/// Each reader's room for one read, which it copies into its message.
var chunks: [connections_max][chunk_len]u8 align(@alignOf(u64)) = undefined;
var output: [output_len]u8 align(@alignOf(u64)) = undefined;
var queue_buffer: [queue_len]Message align(@alignOf(Message)) = undefined;
var queue: Io.Queue(Message) align(@alignOf(Io.Queue(Message))) = .init(&queue_buffer);
/// A permit for each entry no socket holds: the acceptor takes one before each accept.
var free_sockets: Io.Semaphore align(@alignOf(Io.Semaphore)) = .{ .permits = connections_max };
var random_source: std.Random.IoSource align(@alignOf(std.Random.IoSource)) = undefined;

pub const Error = error{ListenerFailed};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const port = try port_of(init);
    const address: net.IpAddress = .{ .ip4 = .loopback(port) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    // A script that asked for port 0 reads the port from this line.
    std.debug.print("listening on port {d}\n", .{listener.socket.address.getPort()});
    try serve(io, &listener);
}

fn port_of(init: std.process.Init) !u16 {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const text = args.next() orelse return port_default;
    return std.fmt.parseInt(u16, text, 10);
}

/// The instant the engine is given: the monotonic clock, and the Unix time beside it.
fn instant(io: Io) server.Instant {
    const awake = Io.Clock.awake.now(io).toNanoseconds();
    const real = Io.Clock.real.now(io).toSeconds();
    return .{ .ns = @intCast(awake), .unix_seconds = @intCast(@max(real, 0)) };
}

/// Starts the engine and the tasks that wait, then owns the engine until a task fails.
fn serve(io: Io, listener: *net.Server) !void {
    random_source = .{ .io = io };
    try engine.init(&config, random_source.interface(), instant(io));
    var group: Io.Group = .init;
    // Stops every reader, the acceptor and the ticker, then closes the sockets left.
    defer close_all(io);
    defer group.cancel(io);
    // A closed queue refuses every put, so no task waits on the owner while it stops.
    defer queue.close(io);
    try group.concurrent(io, accept_sockets, .{ io, listener });
    try group.concurrent(io, tick, .{io});
    for (0..messages_max) |_| {
        const message = try queue.getOne(io);
        const now_ns = instant(io).ns;
        engine.on_instant(now_ns);
        switch (message) {
            .accepted => |stream| try start(io, &group, stream, now_ns),
            .read => |*chunk| take(chunk),
            .ended => |index| stopped(io, index),
            .tick => {},
            .listener_failed => return error.ListenerFailed,
        }
        service(io, now_ns);
    }
}

/// Accepts sockets and hands each to the owner.
fn accept_sockets(io: Io, listener: *net.Server) Io.Cancelable!void {
    for (0..messages_max) |_| {
        try free_sockets.wait(io);
        const stream = listener.accept(io) catch |failure| switch (failure) {
            error.Canceled => return error.Canceled,
            // The client gave up before the accept, which ends nothing else.
            error.ConnectionAborted => {
                free_sockets.post(io);
                continue;
            },
            else => return queue.putOne(io, .listener_failed) catch {},
        };
        queue.putOne(io, .{ .accepted = stream }) catch {
            stream.close(io);
            return error.Canceled;
        };
    }
}

/// Wakes the owner every `tick_ns`, so it fires the engine's deadlines.
fn tick(io: Io) Io.Cancelable!void {
    for (0..messages_max) |_| {
        try io.sleep(.fromNanoseconds(tick_ns), .awake);
        queue.putOne(io, .tick) catch return error.Canceled;
    }
}

/// Reads entry `index`'s socket until it ends, and hands each read to the owner. Its last
/// message is `ended`, after which the owner closes the socket.
fn read_socket(io: Io, index: u32, stream: net.Stream) Io.Cancelable!void {
    defer queue.putOneUncancelable(io, .{ .ended = index }) catch {};
    const file: Io.File = .{ .handle = stream.socket.handle, .flags = .{ .nonblocking = false } };
    const room = &chunks[index];
    for (0..reads_max) |_| {
        const result = try io.operate(.{ .file_read_streaming = .{ .file = file, .data = &.{room} } });
        const len = result.file_read_streaming catch return;
        if (len == 0) continue;
        queue.putOne(io, .{ .read = .{ .entry = index, .len = @intCast(len), .bytes = room.* } }) catch return;
    }
}

/// Starts the connection of a socket the listener accepted, in cleartext, with its reader.
fn start(io: Io, group: *Io.Group, stream: net.Stream, now_ns: u64) !void {
    // The acceptor took a permit for this socket, so an entry is free.
    const index = free_entry().?;
    const handle = engine.accept(.{ .tls = false }, now_ns) orelse return refuse(io, stream);
    entries[index] = .{ .stream = stream, .open = true, .handle = handle, .attached = true };
    group.concurrent(io, read_socket, .{ io, index, stream }) catch {
        // No task reads the socket, so it closes now, and the engine ends its connection.
        engine.transport_closed(handle);
        entries[index].open = false;
        stream.close(io);
    };
}

/// Closes a socket the engine started no connection on, and gives its permit back.
fn refuse(io: Io, stream: net.Stream) void {
    stream.close(io);
    free_sockets.post(io);
}

fn free_entry() ?u32 {
    for (&entries, 0..) |*entry, index| {
        if (!entry.open and !entry.attached) return @intCast(index);
    }
    return null;
}

/// Keeps what a socket read for the engine. A connection whose unread octets pass
/// `held_len_max` fails: its client sent more than it waits to have read.
fn take(chunk: *const Chunk) void {
    const entry = &entries[chunk.entry];
    if (!entry.attached or entry.closing) return;
    if (entry.held_len + chunk.len > held_len_max) return fail(entry);
    @memcpy(held[chunk.entry][entry.held_len..][0..chunk.len], chunk.bytes[0..chunk.len]);
    entry.held_len += chunk.len;
}

/// The reader of entry `index` stopped. The engine ends the connection if it still holds it, and
/// the socket closes.
fn stopped(io: Io, index: u32) void {
    const entry = &entries[index];
    std.debug.assert(entry.open);
    if (entry.attached) engine.transport_closed(entry.handle);
    entry.stream.close(io);
    entry.open = false;
    entry.held_len = 0;
    // The engine's `ended` frees an entry still attached, in `route`.
    if (!entry.attached) free_sockets.post(io);
}

/// Ends a connection whose socket failed: the engine ends it, and the socket shuts down.
fn fail(entry: *Entry) void {
    engine.transport_closed(entry.handle);
    entry.closing = true;
}

/// Steps every connection until none moves, then shuts down each socket whose connection
/// closed, so that its reader stops.
fn service(io: Io, now_ns: u64) void {
    drain(io, now_ns);
    for (&entries, 0..) |*entry, index| {
        if (entry.attached) step(io, entry, index, now_ns);
    }
    for (&entries) |*entry| {
        const over = entry.closing or !entry.attached;
        if (!entry.open or entry.shut or !over or entry.send_owed) continue;
        entry.stream.shutdown(io, .both) catch {};
        entry.shut = true;
    }
}

/// Passes the connection its socket's octets, writes what it owes, and routes every event the
/// engine reports, until nothing moves.
fn step(io: Io, entry: *Entry, index: usize, now_ns: u64) void {
    for (0..passes_max) |_| {
        const moved = feed(io, entry, index, now_ns);
        const sent = flush(io, entry, now_ns);
        drain(io, now_ns);
        if (!moved and !sent) return;
    }
}

/// Passes the octets the socket read to the engine until it consumes nothing and reports
/// nothing, and keeps what it left.
fn feed(io: Io, entry: *Entry, index: usize, now_ns: u64) bool {
    const room = &held[index];
    var consumed: usize = 0;
    var moved = false;
    for (0..events_per_step_max) |_| {
        if (!entry.attached or entry.closing) break;
        const bytes: server.StreamBytes = .{ .connection = entry.handle, .bytes = room[consumed..entry.held_len] };
        const received = engine.receive(.{ .stream = bytes }, now_ns);
        consumed += received.consumed;
        if (received.event) |event| route(io, event);
        if (received.consumed == 0 and received.event == null) break;
        moved = true;
    }
    std.mem.copyForwards(u8, room[0 .. entry.held_len - consumed], room[consumed..entry.held_len]);
    entry.held_len -= consumed;
    return moved;
}

/// Writes what the connection owes to its socket. A write that fails fails the connection.
fn flush(io: Io, entry: *Entry, now_ns: u64) bool {
    if (!entry.send_owed) return false;
    var writer = entry.stream.writer(io, &.{});
    var sent = false;
    for (0..sends_per_flush_max) |_| {
        const written = engine.send_stream(entry.handle, &output, now_ns);
        writer.interface.writeAll(output[0..written]) catch {
            entry.send_owed = false;
            fail(entry);
            return true;
        };
        sent = sent or written > 0;
        if (written < output.len) {
            entry.send_owed = false;
            return sent;
        }
    }
    return sent;
}

/// Reads the engine's events until it reports none, routing each.
fn drain(io: Io, now_ns: u64) void {
    for (0..events_per_step_max) |_| {
        const event = engine.receive(.none, now_ns).event orelse return;
        route(io, event);
    }
}

/// Hands an event to the router, which answers every request, and keeps what the connection's
/// own events say.
fn route(io: Io, event: server.Event) void {
    const other = switch (router.handle(&app, &engine, event)) {
        .taken => return,
        .event => |other| other,
    };
    switch (other) {
        .send => |handle| if (find(handle)) |entry| {
            entry.send_owed = true;
        },
        .close => |handle| if (find(handle)) |entry| {
            entry.closing = true;
        },
        .ended => |over| if (find(over.connection)) |entry| {
            entry.attached = false;
            if (!entry.open) free_sockets.post(io);
        },
        // The router takes every event of a request, and the server never shuts the engine down.
        .request, .body, .trailers, .writable, .finished, .closed => {},
    }
}

/// The entry of the connection `handle` names. The engine reports nothing of a connection after
/// its `ended`, so an attached entry with the same handle is its own.
fn find(handle: server.ConnectionHandle) ?*Entry {
    for (&entries) |*entry| {
        if (entry.attached and std.meta.eql(entry.handle, handle)) return entry;
    }
    return null;
}

/// Closes each socket still open once every task stopped.
fn close_all(io: Io) void {
    for (&entries) |*entry| {
        if (entry.open) entry.stream.close(io);
        entry.open = false;
    }
}
