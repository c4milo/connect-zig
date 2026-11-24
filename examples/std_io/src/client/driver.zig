//! A client loop over a real TCP socket, with no Rotor (decision 32): one `client.ConnectionPool`
//! that the program drives by hand through Zig 0.16's `std.Io`. It opens the socket the pool
//! asks for, passes the pool what the socket read, writes what the pool owes, and reads the
//! clock through `std.Io` for each instant it passes. It runs in cleartext, over h2 with prior
//! knowledge or h11 (decision 13).
//!
//! A program keeps one `Driver` in its state (decision 42), and calls `init` once. For each
//! round, it calls `begin` with the protocols the round may speak, `request` for each call, then
//! `finish`, which runs the pool until every call finished and the socket closed.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const constants = @import("constants.zig");
const Io = std.Io;
const net = std.Io.net;

/// The server's address, as the pool names it: the port goes in the `Destination`.
const server_addresses = [_]client.Address{.init(&constants.loopback, 0)};

pub const Error = error{ CallUnfinished, CallWrong, InputTooLong };

const Pool = client.ConnectionPool(.{ .quic = false });

/// The buffers of one call: its request's body, scratch and header values, and its response's
/// headers, trailers and body.
pub const CallBuffers = struct {
    request_body: [constants.call_buffer_len]u8,
    message: [constants.call_buffer_len]u8,
    work: [constants.call_buffer_len]u8,
    values: [constants.call_buffer_len]u8,
    headers: [constants.call_buffer_len]u8,
    trailers: [constants.call_buffer_len]u8,
    body: [constants.call_buffer_len]u8,

    /// The `ClientCall` buffers that `set` holds.
    pub fn of(set: *CallBuffers) rpc.ClientCallBuffers {
        return .{
            .request = .{ .body = &set.request_body, .scratch = .{ .message = &set.message, .work = &set.work, .tokens = &.{} }, .values = &set.values },
            .headers = &set.headers,
            .trailers = &set.trailers,
            .body = &set.body,
        };
    }
};

/// A client call of `connect_colibri` with the buffers it writes and reads in. colibri reads and
/// writes each call until its round ends, so a program keeps each call in its state.
pub fn Call(comptime method: connect.Method) type {
    return struct {
        const Self = @This();

        call: rpc.ClientCall(method, .{}),
        buffers: CallBuffers,

        /// Builds a call that sends `messages` whole, with `shared`, the program's client.
        pub fn init(self: *Self, shared: *const connect.Client, call_options: *const connect.client.Options, messages: []const method.Request) !void {
            try self.call.init(shared, {}, call_options, messages, &CallBuffers.of(&self.buffers));
        }
    };
}

/// Room for one response's strings, details and metadata. Each `read` reuses it.
const ReadBuffers = struct {
    message: [constants.read_len]u8,
    work: [constants.read_len]u8,
    tokens: [constants.read_len]u8,
    octets: [constants.read_len]u8,
    details: [constants.entries_max]connect.Detail,
    metadata: [constants.entries_max]connect.Header,
};

/// The pool of one round, its socket, and the octets between them.
pub const Driver = struct {
    pool: Pool,
    pool_memory: [Pool.memory_bytes(.{})]u8 align(Pool.memory_alignment),
    config: client.Config,
    output: [client.constants.limits.stream_output_len_min]u8,
    held: [constants.held_len_max]u8,
    held_len: usize,
    read_buffers: ReadBuffers,
    random_source: std.Random.IoSource,
    /// The socket of the round's connection, while it is open.
    stream: ?net.Stream,
    tcp: client.ConnectionHandle,
    port: u16,
    requested: u32,
    finished: u32,
    pool_closed: bool,
    spoken: ?client.Protocol,

    /// Starts a driver with no socket. `deinit` closes the socket a failed round left open.
    pub fn init(driver: *Driver, io: Io) void {
        driver.random_source = .{ .io = io };
        driver.stream = null;
        driver.tcp = .{ .slot = 0, .generation = 0 };
        driver.held_len = 0;
    }

    pub fn deinit(driver: *Driver, io: Io) void {
        driver.close_socket(io);
    }

    /// Starts a round whose pool speaks `protocols` to the server on `server_port`.
    pub fn begin(driver: *Driver, protocols: client.Protocols, server_port: u16) !void {
        std.debug.assert(!protocols.h3);
        std.debug.assert(driver.stream == null);
        driver.port = server_port;
        driver.config = .{ .authority = constants.authority, .protocols = protocols };
        try driver.pool.init(&driver.pool_memory, &driver.config, &.{ .addresses = &server_addresses, .port = server_port }, null);
        driver.held_len = 0;
        driver.requested = 0;
        driver.finished = 0;
        driver.pool_closed = false;
        driver.spoken = null;
    }

    /// Adds a call to the round. Both stay in place until `finish` returns.
    pub fn request(driver: *Driver, call_request: *client.Request, call_response: *client.Response) !void {
        _ = try driver.pool.request(call_request, call_response);
        driver.requested += 1;
    }

    /// Room for one response's strings, details and metadata. Each `read` reuses it.
    pub fn storage(driver: *Driver) connect.client.Storage {
        const room = &driver.read_buffers;
        return .{
            .scratch = .{ .message = &room.message, .work = &room.work, .tokens = &room.tokens },
            .octets = &room.octets,
            .details = &room.details,
            .metadata = &room.metadata,
        };
    }

    /// Runs the round until every call finished and the socket closed, and checks it spoke
    /// `expected`.
    pub fn finish(driver: *Driver, io: Io, expected: client.Protocol) !void {
        for (0..constants.turns_max) |_| {
            const now = now_ns(io);
            driver.pool.on_instant(now);
            try driver.drain(io, now);
            if (driver.pool_closed) {
                if (driver.spoken != expected) return error.CallWrong;
                return;
            }
            try driver.wait(io, now);
        }
        driver.close_socket(io);
        return error.CallUnfinished;
    }

    /// Waits for the socket to read, until the pool's next deadline or `wait_ns_max`.
    fn wait(driver: *Driver, io: Io, now: u64) !void {
        var wait_ns: u64 = constants.wait_ns_max;
        if (driver.pool.deadline_ns()) |deadline_ns| wait_ns = @min(wait_ns, deadline_ns -| now);
        const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(@max(wait_ns, 1)), .clock = .awake } };
        const open = driver.stream orelse return io.sleep(timeout.duration.raw, .awake);
        if (driver.held_len == driver.held.len) return error.InputTooLong;
        const file: Io.File = .{ .handle = open.socket.handle, .flags = .{ .nonblocking = false } };
        const operation: Io.Operation = .{ .file_read_streaming = .{ .file = file, .data = &.{driver.held[driver.held_len..]} } };
        const result = io.operateTimeout(operation, timeout) catch |failure| switch (failure) {
            error.Timeout => return,
            else => return failure,
        };
        const len = result.file_read_streaming catch {
            // The server closed the socket, or it failed: the pool ends the connection.
            driver.pool.transport_closed(driver.tcp);
            driver.close_socket(io);
            return;
        };
        driver.held_len += len;
    }

    /// Passes the pool the octets the socket read, or `.none` when it holds none, until it
    /// consumes nothing and reports nothing.
    fn drain(driver: *Driver, io: Io, now: u64) !void {
        var consumed: usize = 0;
        for (0..constants.receive_calls_max) |_| {
            const rest = driver.held[consumed..driver.held_len];
            const input: client.Input = if (rest.len > 0) .{ .stream = .{ .connection = driver.tcp, .bytes = rest } } else .none;
            const received = driver.pool.receive(input, now);
            consumed += received.consumed;
            const event = received.event orelse {
                if (received.consumed == 0) break;
                continue;
            };
            try driver.report(io, event, now);
            if (event == .close) consumed = driver.held_len;
        }
        std.mem.copyForwards(u8, driver.held[0 .. driver.held_len - consumed], driver.held[consumed..driver.held_len]);
        driver.held_len -= consumed;
    }

    fn report(driver: *Driver, io: Io, event: client.Event, now: u64) !void {
        switch (event) {
            .open => |open| try driver.open_socket(io, open),
            .send => |connection| try driver.send_owed(io, connection, now),
            .connected => |connected| driver.spoken = connected.protocol,
            .finished => {
                driver.finished += 1;
                if (driver.finished == driver.requested) driver.pool.shutdown();
            },
            // The pool sent its GOAWAY, or is done with h11: the program closes the socket.
            .close => driver.close_socket(io),
            .closed => driver.pool_closed = true,
            // No call of these rounds streams (colibri decision 153).
            .headers, .body, .body_taken => return error.CallWrong,
            // The pool opens no second connection to resume, so it wipes the server's ticket.
            .ticket => |connection| if (driver.pool.take_ticket(connection)) |ticket| {
                var kept = ticket;
                kept.wipe();
            },
        }
    }

    /// Connects the socket an `open` named, and starts the pool's connection on it.
    fn open_socket(driver: *Driver, io: Io, open: client.Open) !void {
        if (open.transport != .tcp) return error.CallWrong;
        const address: net.IpAddress = .{ .ip4 = .loopback(driver.port) };
        driver.tcp = open.connection;
        driver.stream = address.connect(io, .{ .mode = .stream }) catch {
            // No socket, so the pool ends the connection and fails its calls.
            driver.pool.transport_closed(open.connection);
            return;
        };
        try driver.pool.start_tcp(open.connection, driver.random_source.interface(), 0, null);
    }

    fn send_owed(driver: *Driver, io: Io, connection: client.ConnectionHandle, now: u64) !void {
        const open = driver.stream orelse return error.CallWrong;
        var writer = open.writer(io, &.{});
        for (0..constants.sends_per_event_max) |_| {
            const written = driver.pool.send_stream(connection, &driver.output, now);
            try writer.interface.writeAll(driver.output[0..written]);
            if (written < driver.output.len) return;
        }
        return error.CallWrong;
    }

    fn close_socket(driver: *Driver, io: Io) void {
        const open = driver.stream orelse return;
        open.close(io);
        driver.stream = null;
        driver.held_len = 0;
    }
};

fn now_ns(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// Checks a response holds no message more, and ended in success.
pub fn expect_end(response: *connect.client.Response, comptime T: type) !void {
    if (try response.next(T) != null) return error.CallWrong;
    if (response.failure) |failure| {
        std.debug.print("std_io: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.CallWrong;
    }
}
