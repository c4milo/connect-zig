//! How a route calls the program: its interceptors around the handler, and the handler itself.
//!
//! A handler is a function, which takes its request whole, or, for a client or bidirectional
//! stream, a type whose `on_message` takes each message as it arrives and whose `on_end` runs
//! once the client ends its stream. A type handler answers while the client still sends, which
//! over h2 is a full-duplex stream (Connect protocol, "Streaming-RPC"; decision 18).
//!
//! An interceptor is a type with any of:
//!
//! - `on_call(app, *Call) ?connect.RpcError`, which runs before the handler and refuses the call
//!   when it returns an error;
//! - `on_finish(app, *Call, ?connect.RpcError) ?connect.RpcError`, which runs after the handler
//!   and returns the outcome the client reads.
//!
//! `on_call` runs in the order the list names the interceptors, and `on_finish` in the reverse,
//! so the first interceptor wraps the others.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const call_file = @import("call.zig");
const constants = @import("constants.zig");
const Call = call_file.Call;
const Sender = call_file.Sender;
const Receiver = call_file.Receiver;

pub fn Interceptors(comptime list: []const type) type {
    return struct {
        pub fn on_call(app: anytype, call: *Call) ?connect.RpcError {
            inline for (list) |Interceptor| {
                if (comptime @hasDecl(Interceptor, "on_call")) {
                    if (Interceptor.on_call(app, call)) |refusal| return refusal;
                }
            }
            return null;
        }

        pub fn on_finish(app: anytype, call: *Call, failure: ?connect.RpcError) ?connect.RpcError {
            var outcome = failure;
            inline for (0..list.len) |index| {
                const Interceptor = list[list.len - 1 - index];
                if (comptime @hasDecl(Interceptor, "on_finish")) outcome = Interceptor.on_finish(app, call, outcome);
            }
            return outcome;
        }
    };
}

/// Whether `handler` is a type that takes messages as they arrive.
pub fn is_streaming(comptime handler: anytype) bool {
    return @TypeOf(handler) == type;
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
        .unary => return single(method, handler, I, app, call, messages),
        .server_stream => {
            var request: method.Request = .{};
            const failure = switch (call_file.read_one(method.Request, call, messages, &request)) {
                .failure => |failure| failure,
                .message => message: {
                    var sender: Sender(method.Response) = .{ .call = call };
                    break :message handler(app, call, &request, &sender);
                },
            };
            return call_file.finish(call, I.on_finish(app, call, failure));
        },
        .client_stream => return single(method, handler, I, app, call, messages),
        .bidi_stream => {
            var receiver: Receiver(method.Request) = .{ .messages = messages, .call = call };
            var sender: Sender(method.Response) = .{ .call = call };
            const failure = handler(app, call, &receiver, &sender) orelse receiver.failure;
            return call_file.finish(call, I.on_finish(app, call, failure));
        },
    }
}

/// A call answered with one message: unary, or a client stream taken whole. The interceptors see
/// the outcome before the message goes out, so `on_finish` may still turn it into an error.
fn single(comptime method: connect.Method, comptime handler: anytype, comptime I: type, app: anytype, call: *Call, messages: *connect.server.Messages) !void {
    var response: method.Response = .{};
    const failure = if (comptime method.stream_type == .unary) unary: {
        var request: method.Request = .{};
        break :unary switch (call_file.read_one(method.Request, call, messages, &request)) {
            .failure => |failure| failure,
            .message => handler(app, call, &request, &response),
        };
    } else stream: {
        var receiver: Receiver(method.Request) = .{ .messages = messages, .call = call };
        break :stream handler(app, call, &receiver, &response) orelse receiver.failure;
    };
    const outcome = I.on_finish(app, call, failure);
    if (outcome == null) try call_file.send_one(method.Response, call, &response);
    return call_file.finish(call, outcome);
}

/// The octets of `bytes` that hold whole envelopes, from its start.
pub fn whole_envelopes_len(bytes: []const u8) usize {
    const prefix_len = connect.constants.protocol.envelope_prefix_len;
    var at: usize = 0;
    // Each envelope takes at least its prefix.
    for (0..bytes.len / prefix_len + 1) |_| {
        if (bytes.len - at < prefix_len) return at;
        const payload_len = std.mem.readInt(u32, bytes[at + 1 ..][0 .. prefix_len - 1], .big);
        if (payload_len > bytes.len - at - prefix_len) return at;
        at += prefix_len + payload_len;
    }
    return at;
}

/// Passes each whole message of `bytes` to a type handler's `on_message`, and returns the error
/// that ends the call, if any.
pub fn each_message(comptime method: connect.Method, comptime handler: type, app: anytype, call: *Call, state: *HandlerState(handler), messages: *connect.server.Messages) ?connect.RpcError {
    for (0..constants.messages_per_read_max) |_| {
        const message = messages.next(method.Request) catch |failure| return connect.server.failure_of(failure);
        const request = message orelse return null;
        call.received += 1;
        const failure = if (comptime method.stream_type == .bidi_stream) bidi: {
            var sender: Sender(method.Response) = .{ .call = call };
            break :bidi handler.on_message(app, call, state, &request, &sender);
        } else handler.on_message(app, call, state, &request);
        if (failure) |rpc_failure| return rpc_failure;
    }
    return null;
}

/// Runs a type handler's `on_end` once the client ended its stream, then ends the call.
pub fn end_stream(comptime method: connect.Method, comptime handler: type, comptime I: type, app: anytype, call: *Call, state: *HandlerState(handler)) !void {
    if (comptime method.stream_type == .bidi_stream) {
        var sender: Sender(method.Response) = .{ .call = call };
        const failure = handler.on_end(app, call, state, &sender);
        return call_file.finish(call, I.on_finish(app, call, failure));
    }
    var response: method.Response = .{};
    const outcome = I.on_finish(app, call, handler.on_end(app, call, state, &response));
    if (outcome == null) try call_file.send_one(method.Response, call, &response);
    return call_file.finish(call, outcome);
}

test "whole envelopes stop before a partial one" {
    const bytes = [_]u8{ 0, 0, 0, 0, 1, 'a', 0, 0, 0, 0, 3, 'b' };
    try std.testing.expectEqual(@as(usize, 6), whole_envelopes_len(&bytes));
    try std.testing.expectEqual(@as(usize, 0), whole_envelopes_len(bytes[0..4]));
}
