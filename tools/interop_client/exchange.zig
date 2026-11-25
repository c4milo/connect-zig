//! One call of the interop client over the conformance client's transport, a `client.ConnectionPool`
//! driven over TCP with `poll` (decision 32). A unary or server-stream call sends its one message
//! in one body, and reads its response once it finished. A client or bidirectional stream writes
//! each message with its `Sender`, and a bidirectional one hands each answer to its watcher as
//! its piece arrives, so a full-duplex program reads an answer before it sends the next message
//! (decision 18 as amended).
//!
//! The client gives a call up `constants.call_ns_max` after it started, so a server that never
//! answers fails a scenario, not the run.
const std = @import("std");
const connect = @import("connect");
const client = @import("colibri").client;
const rpc = @import("connect_colibri");
const transport = @import("client_transport");
const constants = @import("constants.zig");
const Buffers = @import("buffers.zig").Buffers;
const Verdict = @import("verdict.zig").Verdict;
const Transport = transport.Transport;

/// What an exchange works with, which the program's `State` holds (decision 42): the transport
/// its call runs on, the buffers of the call, and the verdict a failure writes.
pub const Shared = struct {
    client: *const connect.Client,
    transport: *Transport,
    buffers: *Buffers,
    verdict: *Verdict,
};

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
        transport: *Transport,
        buffers: *Buffers,
        verdict: *Verdict,
        give_up_ns: u64,
        /// The exchange finished, or the client stopped it: either way no event follows.
        finished: bool = false,
        stopped: bool = false,
        /// Why reading an answer as it arrived failed.
        failure: ?connect.RpcError = null,

        /// Starts a call of `messages`, or a stream whose messages `send` writes, in `self`.
        /// colibri reads and writes the call until it finished, so `self` lives outside the stack,
        /// in the program's `State` (decision 42).
        pub fn begin(self: *Self, shared: Shared, options: *const connect.client.Options, messages: []const method.Request, watcher: *Watcher) !void {
            self.* = .{
                .call = undefined,
                .watcher = watcher,
                .transport = shared.transport,
                .buffers = shared.buffers,
                .verdict = shared.verdict,
                .give_up_ns = shared.transport.now_ns() + constants.call_ns_max,
            };
            if (streamed) {
                try self.call.init_stream(shared.client, {}, options, &self.buffers.call(true));
            } else {
                try self.call.init(shared.client, {}, options, messages, &self.buffers.call(false));
            }
            try self.call.start(self.transport.pool_of());
            self.transport.listen(.{ .context = self, .on_event = on_event });
        }

        fn on_event(context: *anyopaque, event: client.Event) void {
            const self: *Self = @ptrCast(@alignCast(context));
            switch (event) {
                .headers => self.call.on_headers(self.buffers.storage()),
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
    for (0..constants.answers_per_piece_max) |_| {
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
    self.transport.pool_of().cancel(self.call.id, self.transport.now_ns());
    self.stopped = true;
}

/// Turns the transport until `until` holds of the call, it ends, or the client gives it up.
fn wait(self: anytype, comptime until: Until, wanted: u32) void {
    for (0..constants.wait_turns_max) |_| {
        if (ended(self) or holds(self, until, wanted)) return;
        if (self.transport.now_ns() >= self.give_up_ns) return stop(self);
        self.transport.turn(self.give_up_ns);
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
pub fn send(self: anytype, message: anytype) Verdict.Error!void {
    var sender = self.call.sender();
    for (0..constants.wait_turns_max) |_| {
        if (ended(self)) return self.verdict.wrong("the call ended while the client sent", .{});
        sender.send(message) catch |failure| switch (failure) {
            error.PieceHeld => {
                wait(self, .piece_taken, 0);
                continue;
            },
            else => return self.verdict.wrong("sending a message: {s}", .{@errorName(failure)}),
        };
        return;
    }
    return self.verdict.wrong("the pool took no piece", .{});
}

/// Ends the request stream.
pub fn close_send(self: anytype) Verdict.Error!void {
    if (ended(self)) return self.verdict.wrong("the call ended before the client closed it", .{});
    var sender = self.call.sender();
    sender.close_send() catch |failure| return self.verdict.wrong("closing the stream: {s}", .{@errorName(failure)});
}

/// Waits until the watcher counted `wanted` answers, and fails when the call ends or is
/// given up first.
pub fn wait_answers(self: anytype, wanted: u32) Verdict.Error!void {
    wait(self, .answered, wanted);
    if (self.watcher.answers >= wanted) return;
    if (self.failure) |failure| return self.verdict.failed(failure);
    return self.verdict.wrong("answer {d} did not arrive before the next message", .{wanted});
}

/// Waits for the call to end, and returns its response to read.
pub fn finish(self: anytype) Verdict.Error!connect.client.Response {
    wait(self, .end, 0);
    if (self.failure) |failure| return self.verdict.failed(failure);
    if (self.stopped) return self.verdict.wrong("the call did not end within {d} s", .{constants.call_ns_max / std.time.ns_per_s});
    return self.call.read(self.buffers.storage());
}

/// A header of the response, or null.
pub fn header(self: anytype, name: []const u8) ?[]const u8 {
    return self.call.response.headers.get(name);
}

/// An HTTP trailer of the response, or null: gRPC's (PROTOCOL-HTTP2.md, "Responses").
pub fn trailer(self: anytype, name: []const u8) ?[]const u8 {
    return self.call.response.trailers.get(name);
}
