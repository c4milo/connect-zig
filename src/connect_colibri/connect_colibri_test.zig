//! connect_colibri's tests: a router table holding a route of each stream type compiles, and a
//! client `ClientCall` reads what colibri wrote into its response. `zig build examples` runs both
//! sides over colibri's h2 and h11 (design §8 step 5).
const std = @import("std");
const platform = @import("platform");
const support = @import("pull_test_support.zig");
const testing = std.testing;
const connect = @import("connect");
const proto = @import("protobuf");
const server = @import("server");
const client = @import("client");
const rpc = @import("connect_colibri.zig");
const limits = @import("constants.zig");

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

const App = struct {
    cpu_features: platform.CpuFeatures = support.cpu_features,
};

/// The messages a chat answers, at most.
const chat_turns_max = 4;

fn on_say(_: *App, _: *rpc.Context, request: *const rpc.Request(Note), response: *rpc.Response(Note)) ?connect.RpcError {
    response.message.text = request.message.text;
    return null;
}

fn on_count(_: *App, _: *rpc.Context, request: *const rpc.Request(Note), response: *rpc.ResponseStream(Note)) ?connect.RpcError {
    response.send(&request.message) catch return .{ .code = .resource_exhausted };
    return null;
}

fn on_gather(_: *App, _: *rpc.Context, request: *rpc.RequestStream(Note), response: *rpc.Response(Note)) ?connect.RpcError {
    response.message = request.next() orelse return .{ .code = .invalid_argument };
    return null;
}

fn on_chat(_: *App, _: *rpc.Context, request: *rpc.RequestStream(Note), response: *rpc.ResponseStream(Note)) ?connect.RpcError {
    for (0..chat_turns_max) |_| {
        const note = request.next() orelse break;
        response.send(&note) catch return .{ .code = .resource_exhausted };
    }
    response.add_trailer("x-chat", "done") catch {};
    return null;
}

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = connect.constants.protocol.status.internal_server_error;
}

const message_bytes = 1024;
/// The router's calls at once, and its room for each one's response and body.
const router_requests = 2;
const router_bytes = 4096;
const token_bytes = 256;
const options: rpc.RouteOptions = .{ .message_bytes = message_bytes, .token_bytes = token_bytes };

const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = .{
        rpc.post(App, say, on_say, options),
        rpc.get(App, say, on_say, options),
        rpc.post(App, count, on_count, options),
        rpc.post(App, gather, on_gather, options),
        rpc.post(App, chat, on_chat, options),
    },
}, .{ .requests = router_requests, .response_bytes = router_bytes, .body_bytes = router_bytes, .header_bytes = 0 });

test "a route table holds a route of each stream type, and a GET beside a POST" {
    try testing.expect(@sizeOf(Router) > 0);
    var parameters: server.PathParameters = undefined;
    try testing.expect(Router.match("GET", "/test.Svc/Say", &parameters) == .found);
    try testing.expect(Router.match("GET", "/test.Svc/Count", &parameters) != .found);
}

test "a client call writes its request for colibri and reads what colibri filled in" {
    const Call = rpc.ClientCall(say, .{});
    var call: Call = undefined;
    var buffers: [7][512]u8 = undefined;
    try call.init({}, &.{ .protocol = .grpc_web, .cpu_features = support.cpu_features }, &.{.{ .text = "hi" }}, &.{
        .request = .{ .body = &buffers[0], .scratch = .{ .message = &buffers[1], .work = &buffers[2], .tokens = &.{} }, .values = &buffers[3] },
        .headers = &buffers[4],
        .trailers = &buffers[5],
        .body = &buffers[6],
    });
    try testing.expectEqualStrings("POST", call.request.method);
    try testing.expectEqualStrings("/test.Svc/Say", call.request.path);
    // What colibri writes into the response at the call's end: a grpc-web body.
    const body = [_]u8{ 0, 0, 0, 0, 4, 0x0a, 2, 'h', 'i', 0x80, 0, 0, 0, 16 } ++ "grpc-status: 0\r\n".*;
    @memcpy(call.response.body[0..body.len], &body);
    call.response.body_len = body.len;
    call.response.status = .ok;
    call.response.result = .response;
    write_lines(&call.response.headers, &.{.{ .name = "content-type", .value = "application/grpc-web+proto" }});
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
    // gRFC G2, "Errors": a stream the server reset with H3_REQUEST_CANCELLED ends the call canceled.
    call.response.result = .reset;
    call.response.error_code = limits.h3_error_request_cancelled;
    try testing.expectEqual(connect.Code.canceled, call.read(response.storage).failure.?.code);
}

/// Writes field lines into a section's buffer as colibri's client does: each name's and value's
/// length in two octets, big-endian, then the name and the value (colibri decision 152).
pub fn write_lines(section: anytype, lines: []const connect.Header) void {
    const length_len = @sizeOf(u16);
    var used: usize = 0;
    for (lines) |line| {
        std.mem.writeInt(u16, section.buffer[used..][0..length_len], @intCast(line.name.len), .big);
        std.mem.writeInt(u16, section.buffer[used + length_len ..][0..length_len], @intCast(line.value.len), .big);
        const start = used + length_len + length_len;
        @memcpy(section.buffer[start..][0..line.name.len], line.name);
        @memcpy(section.buffer[start + line.name.len ..][0..line.value.len], line.value);
        used = start + line.name.len + line.value.len;
    }
    section.len = used;
}

test "a gRPC client call reads its status from the response's trailers (PROTOCOL-HTTP2.md, Responses)" {
    const Call = rpc.ClientCall(say, .{});
    var call: Call = undefined;
    var buffers: [7][512]u8 = undefined;
    try call.init({}, &.{ .protocol = .grpc, .cpu_features = support.cpu_features }, &.{.{ .text = "hi" }}, &.{
        .request = .{ .body = &buffers[0], .scratch = .{ .message = &buffers[1], .work = &buffers[2], .tokens = &.{} }, .values = &buffers[3] },
        .headers = &buffers[4],
        .trailers = &buffers[5],
        .body = &buffers[6],
    });
    const body = [_]u8{ 0, 0, 0, 0, 4, 0x0a, 2, 'h', 'i' };
    @memcpy(call.response.body[0..body.len], &body);
    call.response.body_len = body.len;
    call.response.status = .ok;
    call.response.result = .response;
    write_lines(&call.response.headers, &.{.{ .name = "content-type", .value = "application/grpc+proto" }});
    // A grpc-status among the headers is not the call's status: only the trailers carry it.
    write_lines(&call.response.trailers, &.{.{ .name = "grpc-status", .value = "0" }});
    var storage_buffers: [4][256]u8 = undefined;
    var details: [2]connect.Detail = undefined;
    var metadata: [4]connect.Header = undefined;
    const storage: connect.client.Storage = .{
        .scratch = .{ .message = &storage_buffers[0], .work = &storage_buffers[1], .tokens = &storage_buffers[2] },
        .octets = &storage_buffers[3],
        .details = &details,
        .metadata = &metadata,
    };
    var success = call.read(storage);
    try testing.expectEqualStrings("hi", (try success.next(Note)).?.text);
    try testing.expectEqual(@as(?Note, null), try success.next(Note));
    try testing.expectEqual(@as(?connect.RpcError, null), success.failure);
    write_lines(&call.response.trailers, &.{ .{ .name = "grpc-status", .value = "5" }, .{ .name = "grpc-message", .value = "gone" } });
    var failed = call.read(storage);
    _ = try failed.next(Note);
    try testing.expectEqual(@as(?Note, null), try failed.next(Note));
    try testing.expectEqual(connect.Code.not_found, failed.failure.?.code);
    try testing.expectEqualStrings("gone", failed.failure.?.message);
    // No trailers at all: the call ended without its status.
    call.response.trailers.len = 0;
    var cut = call.read(storage);
    _ = try cut.next(Note);
    try testing.expectEqual(@as(?Note, null), try cut.next(Note));
    try testing.expect(cut.failure != null);
}

test "a client call that ends with no response maps to the code a client retries on" {
    try testing.expectEqual(connect.Code.unavailable, failure_code(.refused, 0));
    try testing.expectEqual(connect.Code.unavailable, failure_code(.closed, 0));
    try testing.expectEqual(connect.Code.resource_exhausted, failure_code(.too_large, 0));
    try testing.expectEqual(connect.Code.internal, failure_code(.malformed, 0));
}

test "a stream the server reset maps by the code of its reset, in h2 and in h3" {
    // The codes as RFC 9113 §7 and RFC 9114 §8.1 number them, apart from the module's constants.
    const cancel = 0x8;
    const enhance_your_calm = 0xb;
    const inadequate_security = 0xc;
    const excessive_load = 0x107;
    const request_cancelled = 0x10c;
    // PROTOCOL-HTTP2.md, "Errors", and gRFC G2, "Errors".
    try testing.expectEqual(connect.Code.canceled, failure_code(.reset, cancel));
    try testing.expectEqual(connect.Code.canceled, failure_code(.reset, request_cancelled));
    try testing.expectEqual(connect.Code.resource_exhausted, failure_code(.reset, enhance_your_calm));
    try testing.expectEqual(connect.Code.resource_exhausted, failure_code(.reset, excessive_load));
    try testing.expectEqual(connect.Code.permission_denied, failure_code(.reset, inadequate_security));
    // NO_ERROR, INTERNAL_ERROR, H3_NO_ERROR and a code neither protocol names.
    const others = [_]u32{ 0x0, 0x2, 0x100, 0xffff };
    for (others) |code| try testing.expectEqual(connect.Code.internal, failure_code(.reset, code));
    // A code reads only for a reset: a closed connection stays one the client retries on.
    try testing.expectEqual(connect.Code.unavailable, failure_code(.closed, cancel));
}

fn failure_code(result: client.Result, error_code: u32) connect.Code {
    const response: client.Response = .{ .result = result, .error_code = error_code };
    return rpc.failure_of(&response).code;
}
