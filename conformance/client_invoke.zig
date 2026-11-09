//! One call of the conformance client, as docs/testing_clients.md in the conformance suite lays
//! out each stream type's steps ("Stream types"). A unary or server-stream call sends its one
//! message in one body, and reads its response whole once it finished (decision 18 as amended).
//! A client or bidirectional stream writes each message with its `Sender` and reads each answer
//! as its piece arrives; a full-duplex one reads an answer before it sends the next message.
//!
//! The steps run in order, and each wait turns the transport until what it waits for happened.
//! The client keeps its own deadline: when the call's timeout passes first, it cancels the call
//! and reports `deadline_exceeded` (Connect protocol, "Timeouts"; PROTOCOL-HTTP2.md,
//! "Timeout": the deadline binds the client too).
//!
//! `Invocation(method)` holds a call's state; the steps are functions of it, in this file and in
//! `client_reading.zig`.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const constants = @import("constants.zig");
const transport = @import("client_transport.zig");
const Plan = @import("client_plan.zig").Plan;
const Result = @import("client_result.zig").Result;
const buffers = @import("client_buffers.zig");
const reading = @import("client_reading.zig");

/// What a call reports when the client stops it.
pub const canceled: connect.RpcError = .{ .code = .canceled, .message = "the client canceled the call" };
const past_deadline: connect.RpcError = .{ .code = .deadline_exceeded, .message = "the call's deadline passed" };
const given_up: connect.RpcError = .{ .code = .unknown, .message = "the client gave up waiting for the call" };

/// What stops a call before it starts.
pub const StartError = connect.client.RequestError || client.RequestError || error{WrongMessageCount};

/// No wait ends early.
const forever = std.math.maxInt(u64);

/// The call of `method` a case runs.
pub fn Invocation(comptime method: connect.Method) type {
    return struct {
        const Self = @This();
        pub const rpc_method = method;
        pub const streamed = method.stream_type == .client_stream or method.stream_type == .bidi_stream;
        /// docs/testing_clients.md, "Interacting with the test runner": a unary or client-stream
        /// call that fails has no payload, so its response is read once it ended.
        pub const single_response = method.stream_type == .unary or method.stream_type == .client_stream;

        call: rpc.ClientCall(method, .{ .pool = transport.Pool }),
        plan: *const Plan,
        result: *Result,
        messages: []const method.Request,
        storage: connect.client.Storage,
        /// The client's deadline, and the instant it gives the call up past it.
        deadline_ns: ?u64,
        give_up_ns: u64,
        /// The exchange finished, or the client stopped it: either way no event follows.
        finished: bool = false,
        stopped: bool = false,
        headers_seen: bool = false,
        /// The answers a full-duplex stream waits to have read before it sends on.
        payloads_wanted: u32 = 0,
        /// What the streamed response's end-stream message or trailers frame carried.
        metadata: []const connect.Header = &.{},

        var instance: Self align(@alignOf(Self)) = undefined;

        /// Runs the call of `messages` as `plan` says, and records its outcome in `result`.
        pub fn run(plan: *const Plan, messages: []const method.Request, result: *Result) StartError!void {
            const now = transport.now_ns();
            instance = .{
                .call = undefined,
                .plan = plan,
                .result = result,
                .messages = messages,
                .storage = buffers.storage(plan.receive_limit),
                .deadline_ns = if (plan.timeout_ns) |timeout_ns| now + timeout_ns else null,
                .give_up_ns = now + (plan.timeout_ns orelse 0) + constants.client_call_ns_max,
            };
            if (streamed) try run_stream(&instance) else try run_whole(&instance);
            reading.record_metadata(&instance);
        }

        fn on_event(context: *anyopaque, event: client.Event) void {
            const self: *Self = @ptrCast(@alignCast(context));
            pass_event(self, event);
        }
    };
}

fn listen(self: anytype) void {
    const Self = @TypeOf(self.*);
    transport.listen(.{ .context = self, .on_event = Self.on_event });
}

/// Hands the call one event of its exchange.
fn pass_event(self: anytype, event: client.Event) void {
    switch (event) {
        .headers => {
            self.headers_seen = true;
            self.call.on_headers(self.storage);
        },
        .body => |piece| {
            self.call.on_body(piece.len);
            reading.read_arrived(self);
        },
        // A piece the pool could not take ends the call, which `finished` reports.
        .body_taken => self.call.on_body_taken() catch {},
        .finished => self.finished = true,
        else => unreachable,
    }
}

pub fn ended(self: anytype) bool {
    return self.finished or self.stopped;
}

/// Cancels the exchange, and the call ends with `failure`. The pool reports nothing more of it.
pub fn stop(self: anytype, failure: connect.RpcError) void {
    assert(!ended(self));
    transport.pool_of().cancel(self.call.id, transport.now_ns());
    self.stopped = true;
    self.result.failure = failure;
}

/// What a wait waits for.
const Until = enum { end, piece_taken, payloads };

fn done(self: anytype, until: Until) bool {
    return switch (until) {
        .end => false,
        .piece_taken => !self.call.outgoing.holding,
        // The answer waited for arrived, or none more will.
        .payloads => self.result.payloads >= self.payloads_wanted or (self.headers_seen and self.call.reader.done),
    };
}

/// Turns the transport until `until` holds, the call ends, or `until_ns` passes. The client's
/// deadline stops the call where it passes.
fn wait(self: anytype, until_ns: u64, until: Until) void {
    for (0..constants.client_turns_max) |_| {
        if (ended(self) or done(self, until)) return;
        const now = transport.now_ns();
        const deadline_ns = self.deadline_ns orelse forever;
        if (now >= deadline_ns) return stop(self, past_deadline);
        if (now >= self.give_up_ns) return stop(self, given_up);
        if (now >= until_ns) return;
        transport.turn(@min(until_ns, deadline_ns, self.give_up_ns));
    }
    stop(self, given_up);
}

/// The steps of a unary or server-stream call (docs/testing_clients.md, "Unary" and "Server
/// stream").
fn run_whole(self: anytype) StartError!void {
    if (self.messages.len != 1) return error.WrongMessageCount;
    try self.call.init(&self.plan.options, self.messages, &buffers.call(false));
    try self.call.start(transport.pool_of());
    listen(self);
    cancel_after_close(self);
    wait(self, forever, .end);
    if (self.stopped) return;
    var response = self.call.read(self.storage);
    reading.read_rest(self, &response);
}

/// A cancel after the send side closed waits its delay, then cancels a call still running.
fn cancel_after_close(self: anytype) void {
    const delay_ms = switch (self.plan.cancel) {
        .after_close_send_ms => |delay_ms| delay_ms,
        else => return,
    };
    wait(self, transport.now_ns() + @as(u64, delay_ms) * constants.nanos_per_milli, .end);
    if (!ended(self)) stop(self, canceled);
}

/// The steps of a client or bidirectional stream (docs/testing_clients.md, "Client stream",
/// "Half-Duplex Bidi Stream" and "Full-Duplex Bidi Stream").
fn run_stream(self: anytype) StartError!void {
    try self.call.init_stream(&self.plan.options, &buffers.call(true));
    try self.call.start(transport.pool_of());
    listen(self);
    send_all(self);
    if (!ended(self)) close_or_cancel(self);
    wait(self, forever, .end);
    if (self.stopped) return;
    var response = self.call.read(self.storage);
    reading.read_rest(self, &response);
}

/// Cancels in place of closing the send side, or closes it, as the plan says.
fn close_or_cancel(self: anytype) void {
    if (self.plan.cancel == .before_close_send) return stop(self, canceled);
    var sender = self.call.sender();
    // A close the pool cannot take ends the call, which `finished` reports.
    sender.close_send() catch {};
    cancel_after_close(self);
}

/// Sends each message after its delay. A message the call ended before counts as unsent, with
/// each after it. A full-duplex stream waits for an answer after each message, or for the
/// answers' end.
fn send_all(self: anytype) void {
    for (self.messages, 0..) |*message, index| {
        if (self.plan.delay_ns > 0) wait(self, transport.now_ns() + self.plan.delay_ns, .end);
        if (ended(self) or !send(self, message)) {
            self.result.unsent = @intCast(self.messages.len - index);
            return;
        }
        if (!self.plan.full_duplex) continue;
        self.payloads_wanted = self.result.payloads + 1;
        wait(self, forever, .payloads);
    }
}

/// Writes one message, waiting for the pool to take the piece before it when it must.
fn send(self: anytype, message: anytype) bool {
    var sender = self.call.sender();
    for (0..constants.client_turns_max) |_| {
        sender.send(message) catch |failure| switch (failure) {
            error.PieceHeld => {
                wait(self, forever, .piece_taken);
                if (ended(self)) return false;
                continue;
            },
            else => return false,
        };
        return true;
    }
    return false;
}
