//! Example: the ELIZA service on a TCP socket, with no Rotor at all (decision 32). The program
//! drives colibri's sans-I/O `server.Engine` itself, over Zig 0.16's `std.Io` sockets, tasks and
//! clocks. Run it with `zig build serve -- [port]`, then call it with any Connect, gRPC or
//! gRPC-Web client. From the root of the repository:
//!
//! ```sh
//! curl -sS --json '{"sentence":"I feel tired"}' \
//!   http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
//! buf curl --http2-prior-knowledge --protocol grpc --schema examples/eliza/proto \
//!   -d '{"name":"Ada"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Introduce
//! ```
//!
//! It serves h11 and h2 with prior knowledge, in cleartext (decision 13). It holds no TLS
//! identity and opens no UDP socket, so it serves no h3: the socket_server example does that, on
//! `colibri.Server`.
//!
//! One task owns the engine, since the engine serves every connection from one thread. Other
//! tasks only wait: one accepts sockets while an entry is free, one reads each socket, and one
//! wakes the owner every `tick_ns`. Each sends what it got to the owner through one bounded
//! `std.Io.Queue`, and blocks while the queue is full. The owner takes one message at a time,
//! hands it to the engine, and writes what the engine owes to the sockets itself. So no lock
//! guards the engine, and a read never waits on a write. The ticks fire the engine's deadlines,
//! at most `tick_ns` late: a queue has no wait with a timeout, and a tick is the plainest way to
//! get one. A write blocks the owner until the kernel takes the octets, which a loopback client
//! always does; a server for slow clients gives each socket a writer task too.
//!
//! `main` allocates the queue with the rest of the program's `State` (decision 42). Each task
//! gets a pointer to the queue, and touches only what is safe across threads: the queue, the
//! permits of free entries, and the read buffer of its own socket. So the tasks may run on other
//! threads.
//!
//! The program reads the clock and draws entropy through `std.Io`, and passes the engine each
//! instant as a value: colibri reads no clock (decision 3).
const std = @import("std");
const platform = @import("connect_zig").platform;
const server = @import("connect_zig").server;
const rpc = @import("connect_zig").connect_colibri;
const eliza = @import("eliza");
const eliza_service = @import("eliza_service");
const constants = @import("constants.zig");
const Io = std.Io;
const net = std.Io.net;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (colibri decision 94). The
    // harness holds it.
    _ = @import("hooks");
}

/// TCP connections alone: the program opens no UDP socket.
const Engine = server.Engine(.{ .tcp_connections = constants.connections_max, .quic_connections = 0 });

/// What the routes read: ELIZA's room.
const App = struct {
    /// The CPU features the routes read and write each message with, stdx's type. The program
    /// detects them once, as it starts.
    cpu_features: platform.CpuFeatures,
    eliza: eliza_service.Room = .{},
};

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

/// ELIZA's routes, and the 405 a method Connect does not serve gets (decision 27).
const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = eliza_service.Service(App).routes ++ rpc.Refusals(App, eliza.ElizaService.say).routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes, .header_bytes = 0 });

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

const Chunk = struct { entry: u32, len: u32, bytes: ReadRoom };
const ReadRoom = [constants.chunk_len]u8;
const Queue = Io.Queue(Message);

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
    /// The engine reported `half_close`: the socket's write side shuts once its octets are out,
    /// and its reader goes on, since colibri discards what it reads (RFC 9112 §9.6, colibri
    /// decision 160). The engine's `close`, or the peer's, ends it.
    half_closing: bool = false,
    /// The owner shut the socket's write side down.
    write_shut: bool = false,
    /// The connection owes octets no `send_stream` has taken.
    send_owed: bool = false,
    held_len: usize = 0,
};

/// All the program holds, which `main` allocates once (decision 42). The owner alone touches the
/// fields above `chunks`. The tasks share `queue` and `free_sockets`, and each reader writes its
/// own entry of `chunks` alone.
const State = struct {
    engine: Engine,
    config: server.Config,
    router: Router,
    app: App,
    entries: [constants.connections_max]Entry,
    /// The octets each socket read that the engine has not consumed yet.
    held: [constants.connections_max][constants.held_len_max]u8,
    output: [constants.output_len]u8,
    random_source: std.Random.IoSource,
    /// Each reader's room for one read, which it copies into its message.
    chunks: [constants.connections_max]ReadRoom,
    queue_buffer: [constants.queue_len]Message,
    queue: Queue,
    /// A permit for each entry no socket holds: the acceptor takes one before each accept.
    free_sockets: Io.Semaphore,

    /// Starts the engine, with no socket yet.
    fn init(state: *State, io: Io) !void {
        state.config = .{ .timeouts = .{ .first_request_ns = constants.first_request_timeout_ns } };
        state.router.init();
        // The program detects the CPU's features once, as it starts.
        state.app = .{ .cpu_features = .detect() };
        state.entries = @splat(.{});
        state.random_source = .{ .io = io };
        state.queue = .init(&state.queue_buffer);
        state.free_sockets = .{ .permits = constants.connections_max };
        try state.engine.init(&state.config, state.random_source.interface(), instant(io));
    }
};

pub const Error = error{ListenerFailed};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    const port = try port_of(init);
    const address: net.IpAddress = .{ .ip4 = .loopback(port) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    // A script that asked for port 0 reads the port from this line.
    std.debug.print("listening on port {d}\n", .{listener.socket.address.getPort()});
    try serve(io, state, &listener);
}

fn port_of(init: std.process.Init) !u16 {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const text = args.next() orelse return constants.port_default;
    return std.fmt.parseInt(u16, text, constants.port_base);
}

/// The time the engine is given: the Unix time, and the monotonic clock beside it.
fn instant(io: Io) server.Timestamp {
    const awake = Io.Clock.awake.now(io).toNanoseconds();
    const real = Io.Clock.real.now(io).toSeconds();
    return .{ .unix_seconds = @intCast(@max(real, 0)), .monotonic_ns = @intCast(awake) };
}

/// Starts the engine and the tasks that wait, then owns the engine until a task fails.
fn serve(io: Io, state: *State, listener: *net.Server) !void {
    try state.init(io);
    var group: Io.Group = .init;
    // Stops every reader, the acceptor and the ticker, then closes the sockets left.
    defer close_all(io, state);
    defer group.cancel(io);
    // A closed queue refuses every put, so no task waits on the owner while it stops.
    defer state.queue.close(io);
    try group.concurrent(io, accept_sockets, .{ io, &state.queue, &state.free_sockets, listener });
    try group.concurrent(io, tick, .{ io, &state.queue });
    for (0..constants.messages_max) |_| {
        const message = try state.queue.getOne(io);
        const now_ns = instant(io).monotonic_ns;
        state.engine.on_instant(now_ns);
        switch (message) {
            .accepted => |stream| try start(io, state, &group, stream, now_ns),
            .read => |*chunk| take(state, chunk),
            .ended => |index| stopped(io, state, index),
            .tick => {},
            .listener_failed => return error.ListenerFailed,
        }
        service(io, state, now_ns);
    }
}

/// Accepts sockets and hands each to the owner.
fn accept_sockets(io: Io, queue: *Queue, free_sockets: *Io.Semaphore, listener: *net.Server) Io.Cancelable!void {
    for (0..constants.messages_max) |_| {
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
fn tick(io: Io, queue: *Queue) Io.Cancelable!void {
    for (0..constants.messages_max) |_| {
        try io.sleep(.fromNanoseconds(constants.tick_ns), .awake);
        queue.putOne(io, .tick) catch return error.Canceled;
    }
}

/// Reads entry `index`'s socket into `room` until it ends, and hands each read to the owner. Its
/// last message is `ended`, after which the owner closes the socket.
fn read_socket(io: Io, queue: *Queue, room: *ReadRoom, index: u32, stream: net.Stream) Io.Cancelable!void {
    defer queue.putOneUncancelable(io, .{ .ended = index }) catch {};
    const file: Io.File = .{ .handle = stream.socket.handle, .flags = .{ .nonblocking = false } };
    for (0..constants.reads_max) |_| {
        const result = try io.operate(.{ .file_read_streaming = .{ .file = file, .data = &.{room} } });
        const len = result.file_read_streaming catch return;
        if (len == 0) continue;
        queue.putOne(io, .{ .read = .{ .entry = index, .len = @intCast(len), .bytes = room.* } }) catch return;
    }
}

/// Starts the connection of a socket the listener accepted, in cleartext, with its reader.
fn start(io: Io, state: *State, group: *Io.Group, stream: net.Stream, now_ns: u64) !void {
    // The acceptor took a permit for this socket, so an entry is free.
    const index = free_entry(state).?;
    const handle = state.engine.accept(.{ .tls = false }, now_ns) orelse return refuse(io, state, stream);
    state.entries[index] = .{ .stream = stream, .open = true, .handle = handle, .attached = true };
    group.concurrent(io, read_socket, .{ io, &state.queue, &state.chunks[index], index, stream }) catch {
        // No task reads the socket, so it closes now, and the engine ends its connection.
        state.engine.transport_closed(handle);
        state.entries[index].open = false;
        stream.close(io);
    };
}

/// Closes a socket the engine started no connection on, and gives its permit back.
fn refuse(io: Io, state: *State, stream: net.Stream) void {
    stream.close(io);
    state.free_sockets.post(io);
}

fn free_entry(state: *const State) ?u32 {
    for (&state.entries, 0..) |*entry, index| {
        if (!entry.open and !entry.attached) return @intCast(index);
    }
    return null;
}

/// Keeps what a socket read for the engine. A connection whose unread octets pass
/// `held_len_max` fails: its client sent more than it waits to have read.
fn take(state: *State, chunk: *const Chunk) void {
    const entry = &state.entries[chunk.entry];
    if (!entry.attached or entry.closing) return;
    if (entry.held_len + chunk.len > constants.held_len_max) return fail(state, entry);
    @memcpy(state.held[chunk.entry][entry.held_len..][0..chunk.len], chunk.bytes[0..chunk.len]);
    entry.held_len += chunk.len;
}

/// The reader of entry `index` stopped. The engine ends the connection if it still holds it, and
/// the socket closes.
fn stopped(io: Io, state: *State, index: u32) void {
    const entry = &state.entries[index];
    std.debug.assert(entry.open);
    if (entry.attached) state.engine.transport_closed(entry.handle);
    entry.stream.close(io);
    entry.open = false;
    entry.held_len = 0;
    // The engine's `ended` frees an entry still attached, in `route`.
    if (!entry.attached) state.free_sockets.post(io);
}

/// Ends a connection whose socket failed: the engine ends it, and the socket shuts down.
fn fail(state: *State, entry: *Entry) void {
    state.engine.transport_closed(entry.handle);
    entry.closing = true;
}

/// Steps every connection until none moves, then shuts down each socket whose connection
/// closed, so that its reader stops.
fn service(io: Io, state: *State, now_ns: u64) void {
    drain(io, state, now_ns);
    for (&state.entries, 0..) |*entry, index| {
        if (entry.attached) step(io, state, entry, index, now_ns);
    }
    for (&state.entries) |*entry| {
        const over = entry.closing or !entry.attached;
        if (!entry.open or entry.shut or !over or entry.send_owed) continue;
        entry.stream.shutdown(io, .both) catch {};
        entry.shut = true;
    }
    shut_writes(io, state);
}

/// Shuts the write side of each socket whose connection half-closed, once its octets are out.
/// Its reader goes on until the engine's `close` or the peer's.
fn shut_writes(io: Io, state: *State) void {
    for (&state.entries) |*entry| {
        if (!entry.open or entry.shut or entry.write_shut or !entry.half_closing or entry.send_owed) continue;
        entry.stream.shutdown(io, .send) catch {};
        entry.write_shut = true;
    }
}

/// Passes the connection its socket's octets, writes what it owes, and routes every event the
/// engine reports, until nothing moves.
fn step(io: Io, state: *State, entry: *Entry, index: usize, now_ns: u64) void {
    for (0..constants.passes_max) |_| {
        const moved = feed(io, state, entry, index, now_ns);
        const sent = flush(io, state, entry, now_ns);
        drain(io, state, now_ns);
        if (!moved and !sent) return;
    }
}

/// Passes the octets the socket read to the engine until it consumes nothing and reports
/// nothing, and keeps what it left.
fn feed(io: Io, state: *State, entry: *Entry, index: usize, now_ns: u64) bool {
    const room = &state.held[index];
    var consumed: usize = 0;
    var moved = false;
    for (0..constants.events_per_step_max) |_| {
        if (!entry.attached or entry.closing) break;
        const bytes: server.StreamBytes = .{ .connection = entry.handle, .bytes = room[consumed..entry.held_len] };
        const received = state.engine.receive(.{ .stream = bytes }, now_ns);
        consumed += received.consumed;
        if (received.event) |event| route(io, state, event);
        if (received.consumed == 0 and received.event == null) break;
        moved = true;
    }
    std.mem.copyForwards(u8, room[0 .. entry.held_len - consumed], room[consumed..entry.held_len]);
    entry.held_len -= consumed;
    return moved;
}

/// Writes what the connection owes to its socket. A write that fails fails the connection.
fn flush(io: Io, state: *State, entry: *Entry, now_ns: u64) bool {
    if (!entry.send_owed) return false;
    var writer = entry.stream.writer(io, &.{});
    var sent = false;
    for (0..constants.sends_per_flush_max) |_| {
        const written = state.engine.send_stream(entry.handle, &state.output, now_ns);
        writer.interface.writeAll(state.output[0..written]) catch {
            entry.send_owed = false;
            fail(state, entry);
            return true;
        };
        sent = sent or written > 0;
        if (written < state.output.len) {
            entry.send_owed = false;
            return sent;
        }
    }
    return sent;
}

/// Reads the engine's events until it reports none, and routes each.
fn drain(io: Io, state: *State, now_ns: u64) void {
    for (0..constants.events_per_step_max) |_| {
        const event = state.engine.receive(.none, now_ns).event orelse return;
        route(io, state, event);
    }
}

/// Hands an event to the router, which answers every request, and keeps what the connection's
/// own events say.
fn route(io: Io, state: *State, event: server.Event) void {
    const other = switch (state.router.handle(&state.app, &state.engine, event)) {
        .taken => return,
        .event => |other| other,
    };
    switch (other) {
        .send => |handle| if (find(state, handle)) |entry| {
            entry.send_owed = true;
        },
        .close => |handle| if (find(state, handle)) |entry| {
            entry.closing = true;
        },
        .half_close => |handle| if (find(state, handle)) |entry| {
            entry.half_closing = true;
        },
        .ended => |over| if (find(state, over.connection)) |entry| {
            entry.attached = false;
            if (!entry.open) state.free_sockets.post(io);
        },
        // The router takes every event of a request, and the server never shuts the engine down.
        .request, .body, .trailers, .writable, .finished, .closed => {},
    }
}

/// The entry of the connection `handle` names. The engine reports nothing of a connection after
/// its `ended`, so an attached entry with the same handle is its own.
fn find(state: *State, handle: server.ConnectionHandle) ?*Entry {
    for (&state.entries) |*entry| {
        if (entry.attached and std.meta.eql(entry.handle, handle)) return entry;
    }
    return null;
}

/// Closes each socket still open once every task stopped.
fn close_all(io: Io, state: *State) void {
    for (&state.entries) |*entry| {
        if (entry.open) entry.stream.close(io);
        entry.open = false;
    }
}
