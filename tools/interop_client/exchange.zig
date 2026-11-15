//! One call of the interop client over the conformance client's transport, a `client.ConnectionPool`
//! driven over TCP with `poll` (decision 32). A unary or server-stream call sends its one message
//! in one body, and reads its response once it finished. A client or bidirectional stream writes
//! each message with its `Sender`, and a bidirectional one hands each answer to its watcher as
//! its piece arrives, so a full-duplex program reads an answer before it sends the next message
//! (decision 18 as amended).
//!
//! The client gives a call up `call_ns_max` after it started, so a server that never answers
//! fails a scenario, not the run.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const transport = @import("client_transport");
const buffers = @import("buffers.zig");
const verdict = @import("verdict.zig");

/// The longest one call runs before the client gives it up: 10 s.
pub const call_ns_max: u64 = 10 * std.time.ns_per_s;
/// The turns of the transport one wait takes at most. A turn ends at an event, a timer, or a read
/// of the socket, and waits 100 ms at most, so `call_ns_max` passes first.
const wait_turns_max = 1_000_000;
/// The messages one response piece holds, at most.
const answers_per_piece_max = 4096;

/// A watcher of a call whose answers it does not read as they arrive.
pub const Unwatched = struct {
    answers: u32 = 0,

    pub fn on_answer(_: *Unwatched, _: anytype) void {}
};

/// The call of `method`. A bidirectional one hands each answer to `Watcher.on_answer` as it
/// arrives, and waits for `Watcher.answers` to grow.
pub fn Exchange(comptime method: connect.Method, comptime Watcher: type) type {
    return struct {
        const Self = @This();
        pub const rpc_method = method;
        const streamed = method.stream_type == .client_stream or method.stream_type == .bidi_stream;

        call: rpc.ClientCall(method, .{ .pool = transport.Pool }),
        watcher: *Watcher,
        give_up_ns: u64,
        /// The exchange finished, or the client stopped it: either way no event follows.
        finished: bool = false,
        stopped: bool = false,
        /// Why reading an answer as it arrived failed.
        failure: ?connect.RpcError = null,

        /// colibri reads and writes the call until it finished, so it lives outside the stack.
        var instance: Self align(@alignOf(Self)) = undefined;

        /// Starts a call of `messages`, or a stream whose messages `send` writes.
        pub fn begin(options: *const connect.client.Options, messages: []const method.Request, watcher: *Watcher) !*Self {
            instance = .{ .call = undefined, .watcher = watcher, .give_up_ns = transport.now_ns() + call_ns_max };
            const self = &instance;
            if (streamed) {
                try self.call.init_stream(options, &buffers.call(true));
            } else {
                try self.call.init(options, messages, &buffers.call(false));
            }
            try self.call.start(transport.pool_of());
            transport.listen(.{ .context = self, .on_event = on_event });
            return self;
        }

        fn on_event(context: *anyopaque, event: client.Event) void {
            const self: *Self = @ptrCast(@alignCast(context));
            switch (event) {
                .headers => self.call.on_headers(buffers.storage()),
                .body => |piece| {
                    self.call.on_body(piece.len);
                    read_arrived(self);
                },
                // A piece the pool could not take ends the call, which `finished` reports.
                .body_taken => self.call.on_body_taken() catch {},
                .finished => self.finished = true,
                else => unreachable,
            }
        }
    };
}

/// Hands each answer of a bidirectional stream that arrived whole to the watcher.
fn read_arrived(self: anytype) void {
    const method = @TypeOf(self.*).rpc_method;
    if (method.stream_type != .bidi_stream) return;
    for (0..answers_per_piece_max) |_| {
        if (self.stopped) return;
        const answer = self.call.reader.next(method.Response) catch |failure| {
            self.failure = connect.client.failure_of(failure);
            return stop(self);
        } orelse return;
        self.watcher.on_answer(&answer);
    }
}

fn ended(self: anytype) bool {
    return self.finished or self.stopped;
}

/// Cancels the exchange. The pool reports nothing more of it.
fn stop(self: anytype) void {
    if (ended(self)) return;
    transport.pool_of().cancel(self.call.id, transport.now_ns());
    self.stopped = true;
}

/// Turns the transport until `until` holds of the call, it ends, or the client gives it up.
fn wait(self: anytype, comptime until: Until, wanted: u32) void {
    for (0..wait_turns_max) |_| {
        if (ended(self) or holds(self, until, wanted)) return;
        if (transport.now_ns() >= self.give_up_ns) return stop(self);
        transport.turn(self.give_up_ns);
    }
    stop(self);
}

/// What a wait waits for, beyond the call's end.
const Until = enum { end, piece_taken, answered };

fn holds(self: anytype, until: Until, wanted: u32) bool {
    return switch (until) {
        .end => false,
        .piece_taken => !self.call.outgoing.holding,
        .answered => self.watcher.answers >= wanted,
    };
}

/// Writes one message of a stream, waiting for the pool to take the piece before it when
/// it must.
pub fn send(self: anytype, message: anytype) verdict.Error!void {
    var sender = self.call.sender();
    for (0..wait_turns_max) |_| {
        if (ended(self)) return verdict.wrong("the call ended while the client sent", .{});
        sender.send(message) catch |failure| switch (failure) {
            error.PieceHeld => {
                wait(self, .piece_taken, 0);
                continue;
            },
            else => return verdict.wrong("sending a message: {s}", .{@errorName(failure)}),
        };
        return;
    }
    return verdict.wrong("the pool took no piece", .{});
}

/// Ends the request stream.
pub fn close_send(self: anytype) verdict.Error!void {
    if (ended(self)) return verdict.wrong("the call ended before the client closed it", .{});
    var sender = self.call.sender();
    sender.close_send() catch |failure| return verdict.wrong("closing the stream: {s}", .{@errorName(failure)});
}

/// Waits until the watcher counted `wanted` answers, and fails when the call ends or is
/// given up first.
pub fn wait_answers(self: anytype, wanted: u32) verdict.Error!void {
    wait(self, .answered, wanted);
    if (self.watcher.answers >= wanted) return;
    if (self.failure) |failure| return verdict.failed(failure);
    return verdict.wrong("answer {d} did not arrive before the next message", .{wanted});
}

/// Waits for the call to end, and returns its response to read.
pub fn finish(self: anytype) verdict.Error!connect.client.Response {
    wait(self, .end, 0);
    if (self.failure) |failure| return verdict.failed(failure);
    if (self.stopped) return verdict.wrong("the call did not end within {d} s", .{call_ns_max / std.time.ns_per_s});
    return self.call.read(buffers.storage());
}

/// A header of the response, or null.
pub fn header(self: anytype, name: []const u8) ?[]const u8 {
    return self.call.response.headers.get(name);
}

/// An HTTP trailer of the response, or null: gRPC's (PROTOCOL-HTTP2.md, "Responses").
pub fn trailer(self: anytype, name: []const u8) ?[]const u8 {
    return self.call.response.trailers.get(name);
}
