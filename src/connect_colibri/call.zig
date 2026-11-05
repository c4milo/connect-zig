//! One call a route serves: what the handler reads about it, the streams it reads and writes, and
//! the writing of the reply through colibri's `server.ResponseWriter`.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const server = @import("server");
const http = @import("http");
const constants = @import("constants.zig");

/// What the end of a call writes its trailers into: their octets, and the lists of them that
/// connect and colibri each take. A route keeps one in each request's entry of the router pool.
pub const Room = struct {
    storage: [constants.trailer_bytes]u8 = undefined,
    headers: [connect.trailers.trailers_max]connect.Header = undefined,
    fields: [connect.trailers.trailers_max + constants.fields_max]http.Field = undefined,
};

pub const Call = struct {
    reply: connect.server.Reply,
    response: *server.ResponseWriter,
    room: *Room,
    head_written: bool = false,
    metadata: [constants.fields_max]connect.Header = undefined,
    metadata_count: usize = 0,

    /// The protocol the request spoke.
    pub fn protocol(call: *const Call) connect.Protocol {
        return call.reply.accepted.speaks.protocol;
    }

    /// The timeout the client asked for, in nanoseconds. The program turns it into a deadline
    /// with its own clock (decision 3).
    pub fn timeout_ns(call: *const Call) ?u64 {
        return call.reply.accepted.timeout_ns;
    }

    /// Adds a trailer the reply carries: in the end-stream message, gRPC's trailers or
    /// gRPC-Web's trailers frame. A Connect unary reply has no trailers, so it drops them.
    pub fn add_trailer(call: *Call, name: []const u8, value: []const u8) error{TooManyTrailers}!void {
        if (call.metadata_count == constants.fields_max) return error.TooManyTrailers;
        call.metadata[call.metadata_count] = .{ .name = name, .value = value };
        call.metadata_count += 1;
    }
};

/// Writes the messages of a server stream.
pub fn Sender(comptime T: type) type {
    return struct {
        call: *Call,

        pub fn send(sender: *@This(), message: *const T) !void {
            try write_head_once(sender.call, false);
            const prepared = try sender.call.reply.prepare(T, message);
            try sender.call.reply.write_message(prepared, sender.call.response.body());
        }
    };
}

/// Reads the messages of a client stream. A message that does not decode ends the stream, and
/// the call then fails with `failure`.
pub fn Receiver(comptime T: type) type {
    return struct {
        messages: *connect.server.Messages,
        failure: ?connect.RpcError = null,

        pub fn next(receiver: *@This()) ?T {
            return receiver.messages.next(T) catch |failure| {
                receiver.failure = connect.server.failure_of(failure);
                return null;
            };
        }
    };
}

fn apply_head(head: *const connect.server.Head, response: *server.ResponseWriter) !void {
    response.status = head.status;
    for (head.headers()) |header| try response.header(header.name, header.value);
}

fn write_head_once(call: *Call, compressed: bool) !void {
    if (call.head_written) return;
    call.head_written = true;
    const head = call.reply.head(compressed);
    try apply_head(&head, call.response);
}

/// Ends the call: with the error when it is set, else with success.
pub fn finish(call: *Call, failure: ?connect.RpcError) !void {
    if (failure) |rpc_failure| {
        if (call.reply.error_only() and !call.head_written) {
            const head = try call.reply.error_head(rpc_failure, &call.room.storage);
            try apply_head(&head, call.response);
            try call.reply.write_error_body(rpc_failure, call.response.body());
            return call.response.end();
        }
    }
    try write_head_once(call, false);
    if (!call.reply.accepted.speaks.enveloped) return call.response.end();
    const metadata = call.metadata[0..call.metadata_count];
    const trailers = try call.reply.finish(failure, metadata, call.response.body(), &call.room.storage, &call.room.headers);
    if (trailers.len == 0) return call.response.end();
    const fields = &call.room.fields;
    for (trailers, 0..) |trailer, index| fields[index] = .{ .name = trailer.name, .value = trailer.value };
    for (metadata, trailers.len..) |trailer, index| fields[index] = .{ .name = trailer.name, .value = trailer.value };
    return call.response.trailers(fields[0 .. trailers.len + metadata.len]);
}

/// Writes a reply's one message and ends the call.
fn send_one(comptime T: type, call: *Call, message: *const T) !void {
    const prepared = try call.reply.prepare(T, message);
    try write_head_once(call, prepared.compressed);
    try call.reply.write_message(prepared, call.response.body());
    return finish(call, null);
}

const One = union(enum) { message: void, failure: connect.RpcError };

/// Reads the one message of a unary or server-stream request into `out`.
fn read_one(comptime T: type, messages: *connect.server.Messages, out: *T) One {
    const message = messages.next(T) catch |failure| return .{ .failure = connect.server.failure_of(failure) };
    out.* = message orelse return .{ .failure = .{ .code = .invalid_argument, .message = "missing request message" } };
    // Connect protocol and PROTOCOL-HTTP2.md: a unary request holds exactly one message.
    const extra = messages.next(T) catch return .{ .failure = .{ .code = .invalid_argument, .message = "malformed request" } };
    if (extra != null) return .{ .failure = .{ .code = .unimplemented, .message = "unary request with more than one message" } };
    return .{ .message = {} };
}

/// Reads the request, calls the handler of `method`'s stream type, and writes the reply.
pub fn dispatch(comptime App: type, comptime method: connect.Method, comptime handler: anytype, app: *App, call: *Call, messages: *connect.server.Messages) !void {
    const Request = method.Request;
    const Response = method.Response;
    switch (method.stream_type) {
        .unary, .server_stream => {
            var request: Request = .{};
            switch (read_one(Request, messages, &request)) {
                .failure => |failure| return finish(call, failure),
                .message => {},
            }
            if (method.stream_type == .unary) {
                var response: Response = .{};
                if (handler(app, call, &request, &response)) |failure| return finish(call, failure);
                return send_one(Response, call, &response);
            }
            var sender: Sender(Response) = .{ .call = call };
            return finish(call, handler(app, call, &request, &sender));
        },
        .client_stream => {
            var receiver: Receiver(Request) = .{ .messages = messages };
            var response: Response = .{};
            const failure = handler(app, call, &receiver, &response) orelse receiver.failure;
            if (failure) |rpc_failure| return finish(call, rpc_failure);
            return send_one(Response, call, &response);
        },
        .bidi_stream => {
            var receiver: Receiver(Request) = .{ .messages = messages };
            var sender: Sender(Response) = .{ .call = call };
            return finish(call, handler(app, call, &receiver, &sender) orelse receiver.failure);
        },
    }
}

/// Answers a request the route refused before it read the body.
pub fn answer_refusal(refused: connect.server.Refused, scratch: connect.Scratch, room: *Room, response: *server.ResponseWriter) !void {
    const reply = connect.server.refusal_reply(refused, scratch) orelse {
        response.status = refused.http_status;
        return response.end();
    };
    var call: Call = .{ .reply = reply, .response = response, .room = room };
    return finish(&call, refused.failure.?);
}
