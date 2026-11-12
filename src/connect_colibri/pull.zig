//! A stream that its route asks for one message at a time (decision 33). colibri's router calls
//! a struct route's `on_writable` while the response memory has room, and the route then calls
//! the handler's `next`. A message that found no room stays in the call until the next call, so
//! the handler never writes one twice. The router's `response_bytes` then bound the octets in
//! flight, not the stream (colibri decisions 103 and 127 as amended on 2026-11-09).
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const constants = @import("constants.zig");
const call_file = @import("call.zig");
const Call = call_file.Call;
const context_file = @import("context.zig");

/// What a type handler's `next` answers when its route asks for the stream's next message.
pub const Next = union(enum) {
    /// The handler filled the response it was given, and the route sends it.
    message,
    /// The handler has no message yet. Only a bidirectional stream answers it, and only while
    /// its client still sends: the route asks again after the next request message. colibri has
    /// no way yet to wake a route whose request ended, so there the route ends the call with
    /// `internal` (https://github.com/c4milo/colibri/issues/130).
    wait,
    /// The stream ends with success.
    end,
    /// The stream ends with this error.
    failure: connect.RpcError,
};

/// What a route with `next` keeps between two calls of `on_writable`.
pub const Outgoing = struct {
    phase: Phase = .messages,
    /// The end of the response, built once into the call's `Room`, so that a later call writes
    /// it with no handler.
    end: connect.server.Reply.Ending = .{},

    pub const Phase = enum { messages, end_body, end_trailers, done };
};

/// Whether a pass of `serve` goes on to the next, or waits for the next `on_writable`.
const Pass = enum { go_on, wait };

/// Sends what the stream has while the response memory takes it. `input_open` says whether the
/// client still sends, which is when `next` may answer `.wait`.
pub fn serve(comptime method: connect.Method, comptime handler: type, comptime I: type, app: anytype, call: *Call, outgoing: *Outgoing, handler_state: anytype, input_open: bool) !void {
    // Bounded: each pass sends a message, moves the stream toward its end, or stops.
    for (0..constants.messages_per_writable_max) |_| {
        if (outgoing.phase == .done) return;
        // A message the call holds was written first, so it goes out first.
        if (!call_file.write_held(call)) break;
        const pass: Pass = switch (outgoing.phase) {
            .messages => try send_next(method, handler, I, app, call, outgoing, handler_state, input_open),
            .end_body, .end_trailers, .done => try write_end(call, outgoing),
        };
        if (pass == .wait) break;
    }
    hand_over(call, outgoing);
}

/// Ends the stream with `failure`, or with success, from outside `next`: a refused call, a
/// request that does not decode, or an error a handler returned. It writes as much of the end
/// as the response memory takes now, and `serve` writes the rest.
pub fn end(comptime I: type, app: anytype, call: *Call, outgoing: *Outgoing, failure: ?connect.RpcError) !void {
    assert(outgoing.phase == .messages);
    try begin_end(I, app, call, outgoing, failure);
    // Bounded: the held message, the end of the body and the trailers take a pass each.
    for (0..end_passes_max) |_| {
        if (outgoing.phase == .done) return;
        if (!call_file.write_held(call)) break;
        if (try write_end(call, outgoing) == .wait) break;
    }
    hand_over(call, outgoing);
}

/// The passes `end` makes at most: one for a held message, one for the body's end, one for the
/// trailers.
const end_passes_max = 3;

/// Asks the handler for the stream's next message, and sends it or ends the stream.
fn send_next(comptime method: connect.Method, comptime handler: type, comptime I: type, app: anytype, call: *Call, outgoing: *Outgoing, handler_state: anytype, input_open: bool) !Pass {
    assert(call.held.len == 0);
    var ctx: context_file.Context = .{ .call = call };
    var response: context_file.Response(method.Response) = .{ .any = .{ .call = call } };
    switch (handler.next(app, &ctx, handler_state, &response)) {
        .message => {
            try call_file.write_head_once(call, .plain);
            write_or_hold(method.Response, call, &response.message) catch |failure| try begin_end(I, app, call, outgoing, failure_of(failure));
        },
        .wait => {
            if (input_open) return .wait;
            try begin_end(I, app, call, outgoing, waited_after_end);
        },
        .end => try begin_end(I, app, call, outgoing, null),
        .failure => |failure| try begin_end(I, app, call, outgoing, failure),
    }
    return .go_on;
}

/// Encodes `message` straight into the response memory, or, when it has no room there, into the
/// reply's scratch storage, where the call holds it as one envelope for `write_held`.
fn write_or_hold(comptime T: type, call: *Call, message: *const T) connect.server.ReplyError!void {
    assert(call.held.len == 0);
    if (try call.reply.write_direct(T, message, call.response.body())) {
        call.sent += 1;
        return;
    }
    call.held = call.reply.envelope_of(try call.reply.prepare(T, message));
    // The envelope goes out before anything else the call writes, so the reply has sent a message.
    call.reply.sent = true;
}

/// The error that ends a stream whose message the route could not encode.
fn failure_of(failure: connect.server.ReplyError) connect.RpcError {
    return switch (failure) {
        // statuscodes.md, RESOURCE_EXHAUSTED: a message over the server's limit.
        error.NoSpaceLeft => .{ .code = .resource_exhausted, .message = "message larger than the server writes" },
        else => .{ .code = .internal, .message = "the server could not encode a message" },
    };
}

/// statuscodes.md, INTERNAL: the handler broke the contract of `Next.wait`.
const waited_after_end: connect.RpcError = .{ .code = .internal, .message = "the stream waited after its request ended" };

/// Ends the stream. The interceptors see the outcome, and the end of the response is built
/// once: later calls write it from the call's `Room`, whatever the handler's memory holds then.
fn begin_end(comptime I: type, app: anytype, call: *Call, outgoing: *Outgoing, failure: ?connect.RpcError) !void {
    const outcome = I.on_finish(app, call, failure);
    // Nothing went out yet, so the response memory is free: the whole end fits in this call.
    if (!call.head_written) {
        assert(call.held.len == 0);
        outgoing.phase = .done;
        return call_file.finish(call, outcome);
    }
    const metadata = call.room.metadata[0..call.room.metadata_count];
    outgoing.end = try call.reply.ending(outcome, metadata, &call.room.storage, &call.room.headers);
    outgoing.phase = .end_body;
}

/// Writes the next part of the end the stream built.
fn write_end(call: *Call, outgoing: *Outgoing) !Pass {
    assert(call.held.len == 0);
    return switch (outgoing.phase) {
        .messages => unreachable,
        .end_body => write_end_body(call, outgoing),
        .end_trailers => write_end_trailers(call, outgoing),
        .done => .wait,
    };
}

/// Writes the octets that end the body: a Connect end-stream envelope or a gRPC-Web trailers
/// frame, each one slice.
fn write_end_body(call: *Call, outgoing: *Outgoing) Pass {
    if (outgoing.end.octets.len != 0) {
        // colibri's `ResponseWriter.body`: a slice that does not fit is not written at all.
        call.response.body().writeAll(outgoing.end.octets) catch return .wait;
        outgoing.end.octets = "";
    }
    outgoing.phase = .end_trailers;
    return .go_on;
}

/// Ends the response: with gRPC's trailers, or with nothing more.
fn write_end_trailers(call: *Call, outgoing: *Outgoing) !Pass {
    const trailers = outgoing.end.trailers;
    const ended = if (trailers.len == 0) call.response.end() else call.response.trailers(call_file.trailer_fields(call, trailers));
    ended catch |failure| switch (failure) {
        // colibri's `ResponseWriter.Error`: `NoSpaceLeft` says the response memory is full, and
        // `Full` that as many runs wait for the engine as a response holds. Each call changed
        // nothing then, and passes once the engine released octets, so the route calls it again.
        error.NoSpaceLeft, error.Full => return .wait,
        else => |other| return other,
    };
    outgoing.phase = .done;
    return .go_on;
}

/// Hands the octets the writer holds to the engine, so the client reads them before the next
/// call. A flush that finds the engine full keeps its octets in the writer, which sends them
/// later (colibri's usage guide), so its failure is not the call's.
fn hand_over(call: *Call, outgoing: *const Outgoing) void {
    if (!call.head_written or outgoing.phase == .done) return;
    call.response.body().flush() catch {};
}
