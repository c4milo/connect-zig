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
        pub fn handle(app: *App, call: *rpc.Call, request: *const Request, response: *Response) ?connect.RpcError {
            const echo = &app.echo;
            const requests = echo.one_request(Request, request) catch return echo_file.internal;
            const info = echo.request_info(call, requests);
            return answer(app, call, request.response_definition, &info, &response.payload);
        }
    };
}

/// Answers a unary or client-stream call as `definition` asks: the payload echoes `info` and
/// carries the data, or the call fails with the error, which carries `info` as a detail.
pub fn answer(app: *App, call: *rpc.Call, definition: ?service.UnaryResponseDefinition, info: *const RequestInfo, payload: *?service.ConformancePayload) ?connect.RpcError {
    const wanted = definition orelse {
        payload.* = .{ .request_info = info.* };
        return null;
    };
    if (echo_file.apply_metadata(call, &wanted.response_headers, &wanted.response_trailers)) |failure| return failure;
    var slept_ms: u64 = 0;
    if (echo_file.pause(app.io, call, wanted.response_delay_ms, &slept_ms)) |failure| return failure;
    const response = wanted.response orelse {
        payload.* = .{ .request_info = info.* };
        return null;
    };
    switch (response) {
        .response_data => |data| payload.* = .{ .data = data, .request_info = info.* },
        .@"error" => |*failure| return app.echo.failure(failure, info),
    }
    return null;
}

/// ServerStream sends each response the definition lists, the first with the request info,
/// then fails with its error, if any. The error carries the request info when no response
/// went out.
pub fn server_stream(app: *App, call: *rpc.Call, request: *const service.ServerStreamRequest, sender: *rpc.Sender(service.ServerStreamResponse)) ?connect.RpcError {
    const echo = &app.echo;
    const requests = echo.one_request(service.ServerStreamRequest, request) catch return echo_file.internal;
    const info = echo.request_info(call, requests);
    const wanted = request.response_definition orelse return null;
    if (echo_file.apply_metadata(call, &wanted.response_headers, &wanted.response_trailers)) |failure| return failure;
    var slept_ms: u64 = 0;
    var data = wanted.response_data.iterator();
    var sent: usize = 0;
    for (0..constants.responses_max) |_| {
        const bytes = (data.next() catch return echo_file.internal) orelse break;
        if (echo_file.pause(app.io, call, wanted.response_delay_ms, &slept_ms)) |failure| return failure;
        const payload: service.ConformancePayload = .{ .data = bytes, .request_info = if (sent == 0) info else null };
        sender.send(&.{ .payload = payload }) catch return echo_file.internal;
        sent += 1;
    }
    const failure = if (wanted.@"error") |*failure| failure else return null;
    return echo.failure(failure, if (sent == 0) &info else null);
}
