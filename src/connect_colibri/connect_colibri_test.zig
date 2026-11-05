//! connect_colibri's tests: a router table holding a route of each stream type compiles, and a
//! client `Exchange` reads what colibri wrote into its response. `zig build examples` runs both
//! sides over colibri's h2 and h11 (design §8 step 5).
const std = @import("std");
const testing = std.testing;
const connect = @import("connect");
const proto = @import("protobuf");
const server = @import("server");
const rpc = @import("connect_colibri.zig");

const Note = struct {
    text: []const u8 = "",
    pub const FieldNumber = enum(u29) { text = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Note", .fields = &.{
        proto.field_of(FieldNumber.text, .string, .{}),
    } };
};

fn method(comptime name: []const u8, comptime stream_type: connect.StreamType, comptime idempotency: connect.Idempotency) connect.Method {
    return .{ .service = "test.Svc", .name = name, .Request = Note, .Response = Note, .stream_type = stream_type, .idempotency = idempotency };
}

const say = method("Say", .unary, .no_side_effects);
const count = method("Count", .server_stream, .unknown);
const gather = method("Gather", .client_stream, .unknown);
const chat = method("Chat", .bidi_stream, .unknown);

const App = struct {};

/// The messages a chat answers, at most.
const chat_turns_max = 4;

fn on_say(_: *App, _: *rpc.Call, request: *const Note, response: *Note) ?connect.RpcError {
    response.text = request.text;
    return null;
}

fn on_count(_: *App, _: *rpc.Call, request: *const Note, sender: *rpc.Sender(Note)) ?connect.RpcError {
    sender.send(request) catch return .{ .code = .resource_exhausted };
    return null;
}

fn on_gather(_: *App, _: *rpc.Call, receiver: *rpc.Receiver(Note), response: *Note) ?connect.RpcError {
    response.* = receiver.next() orelse return .{ .code = .invalid_argument };
    return null;
}

fn on_chat(_: *App, call: *rpc.Call, receiver: *rpc.Receiver(Note), sender: *rpc.Sender(Note)) ?connect.RpcError {
    for (0..chat_turns_max) |_| {
        const note = receiver.next() orelse break;
        sender.send(&note) catch return .{ .code = .resource_exhausted };
    }
    call.add_trailer("x-chat", "done") catch {};
    return null;
}

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = connect.constants.protocol.status.internal_server_error;
}

const message_bytes = 1024;
const token_bytes = 256;
const options: rpc.RouteOptions = .{ .message_bytes = message_bytes, .token_bytes = token_bytes };

const routes = server.router(App, .{
    .error_handler = on_error,
    .routes = .{
        rpc.post(App, say, on_say, options),
        rpc.get(App, say, on_say, options),
        rpc.post(App, count, on_count, options),
        rpc.post(App, gather, on_gather, options),
        rpc.post(App, chat, on_chat, options),
    },
});

test "a route table holds a route of each stream type, and a GET beside a POST" {
    const Router = @TypeOf(routes).Of(.{ .requests = 2, .response_bytes = 4096, .body_bytes = 4096 });
    try testing.expect(@sizeOf(Router) > 0);
    var parameters: server.PathParameters = undefined;
    try testing.expect(routes.match("GET", "/test.Svc/Say", &parameters) == .found);
    try testing.expect(routes.match("GET", "/test.Svc/Count", &parameters) != .found);
}

test "an exchange writes its request for colibri and reads what colibri filled in" {
    const Call = rpc.Exchange(say);
    var call: Call = undefined;
    var buffers: [6][512]u8 = undefined;
    try call.init(.{ .protocol = .grpc_web }, &.{.{ .text = "hi" }}, .{
        .request = .{ .body = &buffers[0], .scratch = .{ .message = &buffers[1], .work = &buffers[2], .tokens = &.{} }, .values = &buffers[3] },
        .values = &buffers[4],
        .body = &buffers[5],
    });
    try testing.expectEqualStrings("POST", call.request.method);
    try testing.expectEqualStrings("/test.Svc/Say", call.request.path);
    // What colibri writes into the response at the exchange's end: a grpc-web body.
    const body = [_]u8{ 0, 0, 0, 0, 4, 0x0a, 2, 'h', 'i', 0x80, 0, 0, 0, 16 } ++ "grpc-status: 0\r\n".*;
    @memcpy(call.response.body[0..body.len], &body);
    call.response.body_len = body.len;
    call.response.status = 200;
    call.response.result = .response;
    call.wanted[0].value = "application/grpc-web+proto";
    var storage_buffers: [4][256]u8 = undefined;
    var details: [2]connect.Detail = undefined;
    var metadata: [4]connect.Header = undefined;
    var response = call.read(.{
        .scratch = .{ .message = &storage_buffers[0], .work = &storage_buffers[1], .tokens = &storage_buffers[2] },
        .octets = &storage_buffers[3],
        .details = &details,
        .metadata = &metadata,
    });
    try testing.expectEqualStrings("hi", (try response.next(Note)).?.text);
    try testing.expectEqual(@as(?Note, null), try response.next(Note));
    try testing.expectEqual(@as(?connect.RpcError, null), response.failure);
    call.response.result = .closed;
    try testing.expectEqual(connect.Code.unavailable, call.read(response.storage).failure.?.code);
}

test "an exchange that ends with no response maps to the code a client retries on" {
    try testing.expectEqual(connect.Code.unavailable, rpc.failure_of(.refused).code);
    try testing.expectEqual(connect.Code.unavailable, rpc.failure_of(.closed).code);
    try testing.expectEqual(connect.Code.resource_exhausted, rpc.failure_of(.too_large).code);
    try testing.expectEqual(connect.Code.internal, rpc.failure_of(.malformed).code);
}
