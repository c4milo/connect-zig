//! How a route calls the program: its interceptors around the handler, and the handler itself.
//!
//! A handler is a function, which takes its request whole, or, for a client or bidirectional
//! stream, a type whose `on_message` takes each message as it arrives and whose `on_end` runs
//! once the client ends its stream. A type handler answers while the client still sends, which
//! over h2 is a full-duplex stream (Connect protocol, "Streaming RPCs"; decision 18).
//!
//! A type handler of a server or bidirectional stream may declare `next`, which its route calls
//! for one message at a time while the response memory has room (`pull.zig`, decision 33). A
//! server stream's type handler takes its one request in `on_request`.
//!
//! A handler takes the call's `Context`, its request and its response (`context.zig`, decision
//! 36). An interceptor is a type with any of:
//!
//! - `on_call(app, *Context, *const AnyRequest, *AnyResponse) ?connect.RpcError`, which runs
//!   before the handler and refuses the call when it returns an error;
//! - `on_finish(app, *Context, *AnyResponse, ?connect.RpcError) ?connect.RpcError`, which runs
//!   after the handler and returns the outcome the client reads.
//!
//! `on_call` runs in the order the list names the interceptors, and `on_finish` in the reverse,
//! so the first interceptor wraps the others.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const call_file = @import("call.zig");
const context_file = @import("context.zig");
const constants = @import("constants.zig");
const Call = call_file.Call;
const Context = context_file.Context;
const AnyRequest = context_file.AnyRequest;
const AnyResponse = context_file.AnyResponse;
const Request = context_file.Request;
const RequestStream = context_file.RequestStream;
const Response = context_file.Response;
const ResponseStream = context_file.ResponseStream;

pub fn Interceptors(comptime list: []const type) type {
    return struct {
        pub fn on_call(app: anytype, call: *Call) ?connect.RpcError {
            var ctx: Context = .{ .call = call };
            const request: AnyRequest = .{ .call = call };
            var response: AnyResponse = .{ .call = call };
            inline for (list) |Interceptor| {
                if (comptime @hasDecl(Interceptor, "on_call")) {
                    if (Interceptor.on_call(app, &ctx, &request, &response)) |refusal| return refusal;
                }
            }
            return null;
        }

        pub fn on_finish(app: anytype, call: *Call, failure: ?connect.RpcError) ?connect.RpcError {
            var ctx: Context = .{ .call = call };
            var response: AnyResponse = .{ .call = call };
            var outcome = failure;
            inline for (0..list.len) |index| {
                const Interceptor = list[list.len - 1 - index];
                if (comptime @hasDecl(Interceptor, "on_finish")) outcome = Interceptor.on_finish(app, &ctx, &response, outcome);
            }
            return outcome;
        }
    };
}

/// Whether `handler` is a type that takes messages as they arrive.
pub fn is_streaming(comptime handler: anytype) bool {
    return @TypeOf(handler) == type;
}

/// Whether `handler` is a type whose route asks it for each message of the response (`next`).
pub fn pulls(comptime handler: anytype) bool {
    return is_streaming(handler) and @hasDecl(handler, "next");
}

/// Whether the route of `handler` reads the request body as it arrives: a type handler of a
/// client or bidirectional stream. A server stream's request is one message, read whole.
pub fn reads_pieces(comptime method: connect.Method, comptime handler: anytype) bool {
    return is_streaming(handler) and method.stream_type != .server_stream;
}

/// Fails the build when a type handler lacks a declaration its stream type calls, or declares
/// `next` for a stream that answers with one message.
pub fn check(comptime method: connect.Method, comptime handler: anytype) void {
    if (!is_streaming(handler)) return;
    switch (method.stream_type) {
        .unary => @compileError("a unary method takes a function handler"),
        .client_stream => if (pulls(handler)) @compileError("a client stream answers with one message, so its handler declares no next"),
        .server_stream => if (!pulls(handler) or !@hasDecl(handler, "on_request")) @compileError("a server stream's type handler declares on_request and next"),
        .bidi_stream => {},
    }
    if (method.stream_type != .server_stream and (!@hasDecl(handler, "on_message") or !@hasDecl(handler, "on_end"))) {
        @compileError("a client or bidirectional stream's type handler declares on_message and on_end");
    }
}

/// The state a type handler keeps for one call: its `State`, or none.
pub fn HandlerState(comptime handler: anytype) type {
    if (comptime is_streaming(handler) and @hasDecl(handler, "State")) return handler.State;
    return struct {};
}

/// Calls a function handler with its whole request, between the interceptors, and ends the call.
pub fn whole(comptime method: connect.Method, comptime handler: anytype, comptime I: type, app: anytype, call: *Call, messages: *connect.server.Messages) !void {
    comptime assert(!is_streaming(handler));
    if (I.on_call(app, call)) |refusal| return call_file.finish(call, I.on_finish(app, call, refusal));
    switch (comptime method.stream_type) {
        .unary, .client_stream => {
            var response: Response(method.Response) = .{ .any = .{ .call = call } };
            const failure = invoke(method, handler, app, call, messages, &response);
            return respond_one(method.Response, I, app, call, failure, &response.message);
        },
        .server_stream, .bidi_stream => {
            var stream: ResponseStream(method.Response) = .{ .any = .{ .call = call } };
            const failure = invoke(method, handler, app, call, messages, &stream);
            return call_file.finish(call, I.on_finish(app, call, failure));
        },
    }
}

/// Calls a function handler with the request as its stream type takes it: a `Request` of one
/// message, or a `RequestStream`. `response` is the `*Response` or the `*ResponseStream` the
/// handler writes to.
fn invoke(comptime method: connect.Method, comptime handler: anytype, app: anytype, call: *Call, messages: *connect.server.Messages, response: anytype) ?connect.RpcError {
    var ctx: Context = .{ .call = call };
    if (comptime method.stream_type == .unary or method.stream_type == .server_stream) {
        var request: Request(method.Request) = .{ .message = .{}, .any = .{ .call = call } };
        return switch (call_file.read_one(method.Request, call, messages, &request.message)) {
            .failure => |failure| failure,
            .message => handler(app, &ctx, &request, response),
        };
    }
    var stream: RequestStream(method.Request) = .{ .messages = messages, .any = .{ .call = call } };
    return handler(app, &ctx, &stream, response) orelse stream.failure;
}

/// Ends a call answered with one message. The interceptors see the outcome before the message
/// goes out, so `on_finish` may still turn it into an error.
fn respond_one(comptime T: type, comptime I: type, app: anytype, call: *Call, failure: ?connect.RpcError, response: *const T) !void {
    const outcome = I.on_finish(app, call, failure);
    if (outcome == null) try call_file.send_one(T, call, response);
    return call_file.finish(call, outcome);
}

/// The octets of `bytes` that hold whole envelopes, from its start. A partial envelope at the end
/// waits for more octets; an envelope over `payload_len_max` or with reserved flags set fails the
/// call at once, before its payload arrives.
pub fn whole_envelopes_len(bytes: []const u8, payload_len_max: usize) connect.envelope.Error!usize {
    var reader: connect.EnvelopeReader = .{ .body = bytes, .payload_len_max = payload_len_max };
    // Each envelope takes at least its prefix.
    for (0..bytes.len / connect.constants.protocol.envelope_prefix_len + 1) |_| {
        const envelope = reader.next() catch |failure| switch (failure) {
            error.Truncated => return reader.position,
            else => |other| return other,
        };
        if (envelope == null) return reader.position;
    }
    unreachable;
}

/// Passes each whole message of `bytes` to a type handler's `on_message`, and returns the error
/// that ends the call, if any.
pub fn each_message(comptime method: connect.Method, comptime handler: type, app: anytype, call: *Call, state: *HandlerState(handler), messages: *connect.server.Messages) ?connect.RpcError {
    for (0..constants.messages_per_read_max) |_| {
        const message = messages.next(method.Request) catch |failure| return connect.server.failure_of(failure);
        const request: Request(method.Request) = .{ .message = message orelse return null, .any = .{ .call = call } };
        call.received += 1;
        var ctx: Context = .{ .call = call };
        const failure = if (comptime method.stream_type == .bidi_stream) bidi: {
            var stream: ResponseStream(method.Response) = .{ .any = .{ .call = call } };
            break :bidi handler.on_message(app, &ctx, state, &request, &stream);
        } else handler.on_message(app, &ctx, state, &request);
        if (failure) |rpc_failure| return rpc_failure;
    }
    return null;
}

/// Runs the `on_end` of a bidirectional stream's type handler with `next`, once the client ended
/// its stream, and returns the error that ends the call, if any. The handler's `next` ends the
/// stream otherwise.
pub fn end_input(comptime method: connect.Method, comptime handler: type, app: anytype, call: *Call, state: *HandlerState(handler)) ?connect.RpcError {
    comptime assert(method.stream_type == .bidi_stream and pulls(handler));
    var ctx: Context = .{ .call = call };
    const request: AnyRequest = .{ .call = call };
    var stream: ResponseStream(method.Response) = .{ .any = .{ .call = call } };
    return handler.on_end(app, &ctx, state, &request, &stream);
}

/// Runs a type handler's `on_end` once the client ended its stream, then ends the call.
pub fn end_stream(comptime method: connect.Method, comptime handler: type, comptime I: type, app: anytype, call: *Call, state: *HandlerState(handler)) !void {
    var ctx: Context = .{ .call = call };
    const request: AnyRequest = .{ .call = call };
    if (comptime method.stream_type == .bidi_stream) {
        var stream: ResponseStream(method.Response) = .{ .any = .{ .call = call } };
        const failure = handler.on_end(app, &ctx, state, &request, &stream);
        return call_file.finish(call, I.on_finish(app, call, failure));
    }
    var response: Response(method.Response) = .{ .any = .{ .call = call } };
    return respond_one(method.Response, I, app, call, handler.on_end(app, &ctx, state, &request, &response), &response.message);
}

test "whole envelopes stop before a partial one, and refuse one too long or with reserved flags" {
    const payload_len_max = 4;
    const bytes = [_]u8{ 0, 0, 0, 0, 1, 'a', 0, 0, 0, 0, 3, 'b' };
    try std.testing.expectEqual(@as(usize, 6), try whole_envelopes_len(&bytes, payload_len_max));
    try std.testing.expectEqual(@as(usize, 0), try whole_envelopes_len(bytes[0..4], payload_len_max));
    // The prefix alone announces a payload over the limit, so the call fails before it arrives.
    const long = [_]u8{ 0, 0, 0, 0, payload_len_max + 1 };
    try std.testing.expectError(error.MessageTooLarge, whole_envelopes_len(&long, payload_len_max));
    const reserved = [_]u8{ 0x40, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidFlags, whole_envelopes_len(&reserved, payload_len_max));
}
