//! The handlers that take one request: Unary, IdempotentUnary and ServerStream (docs/
//! testing_servers.md in the conformance suite, "Unary" and "ServerStream").
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const service = @import("connectrpc_conformance_v1_service");
const echo_file = @import("echo.zig");
const constants = @import("constants.zig");
const App = @import("app.zig").App;

const RequestInfo = service.ConformancePayload.RequestInfo;

/// The handler of a unary method whose request holds a `UnaryResponseDefinition` and whose
/// response holds a `ConformancePayload`: Unary and IdempotentUnary.
pub fn Unary(comptime Request: type, comptime Response: type) type {
    return struct {
        pub fn handle(app: *App, ctx: *rpc.Context, request: *const rpc.Request(Request), response: *rpc.Response(Response)) ?connect.RpcError {
            const echo = &app.echo;
            const requests = echo.one_request(Request, &request.message) catch return echo_file.internal;
            const info = echo.request_info(ctx, &request.any, requests);
            return answer(app, ctx, &response.any, request.message.response_definition, &info, &response.message.payload);
        }
    };
}

/// Answers a unary or client-stream call as `definition` asks: the payload echoes `info` and
/// carries the data, or the call fails with the error, which carries `info` as a detail.
pub fn answer(app: *App, ctx: *const rpc.Context, response: *rpc.AnyResponse, definition: ?service.UnaryResponseDefinition, info: *const RequestInfo, payload: *?service.ConformancePayload) ?connect.RpcError {
    const wanted = definition orelse {
        payload.* = .{ .request_info = info.* };
        return null;
    };
    if (echo_file.apply_metadata(response, &wanted.response_headers, &wanted.response_trailers)) |failure| return failure;
    var slept_ms: u64 = 0;
    if (echo_file.pause(app.io, ctx, wanted.response_delay_ms, &slept_ms)) |failure| return failure;
    const outcome = wanted.response orelse {
        payload.* = .{ .request_info = info.* };
        return null;
    };
    switch (outcome) {
        .response_data => |data| payload.* = .{ .data = data, .request_info = info.* },
        .@"error" => |*failure| return app.echo.failure(failure, info),
    }
    return null;
}

/// ServerStream sends each response the definition lists, the first with the request info,
/// then fails with its error, if any. The error carries the request info when no response
/// went out.
pub fn server_stream(app: *App, ctx: *rpc.Context, request: *const rpc.Request(service.ServerStreamRequest), response: *rpc.ResponseStream(service.ServerStreamResponse)) ?connect.RpcError {
    const echo = &app.echo;
    const requests = echo.one_request(service.ServerStreamRequest, &request.message) catch return echo_file.internal;
    const info = echo.request_info(ctx, &request.any, requests);
    const wanted = request.message.response_definition orelse return null;
    if (echo_file.apply_metadata(&response.any, &wanted.response_headers, &wanted.response_trailers)) |failure| return failure;
    const sent = switch (send_each(app, ctx, &wanted, &info, response)) {
        .count => |count| count,
        .failure => |failure| return failure,
    };
    const failure = if (wanted.@"error") |*failure| failure else return null;
    return echo.failure(failure, if (sent == 0) &info else null);
}

/// How many responses `send_each` sent, or the error that stopped it.
const Sent = union(enum) { count: usize, failure: connect.RpcError };

/// Sends each response `wanted` lists, after its delay, the first with `info`.
fn send_each(app: *App, ctx: *const rpc.Context, wanted: *const service.StreamResponseDefinition, info: *const RequestInfo, response: *rpc.ResponseStream(service.ServerStreamResponse)) Sent {
    var slept_ms: u64 = 0;
    var data = wanted.response_data.iterator();
    var sent: usize = 0;
    for (0..constants.responses_max) |_| {
        const bytes = (data.next() catch return .{ .failure = echo_file.internal }) orelse break;
        if (echo_file.pause(app.io, ctx, wanted.response_delay_ms, &slept_ms)) |failure| return .{ .failure = failure };
        const payload: service.ConformancePayload = .{ .data = bytes, .request_info = if (sent == 0) info.* else null };
        response.send(&.{ .payload = payload }) catch return .{ .failure = echo_file.internal };
        sent += 1;
    }
    return .{ .count = sent };
}
