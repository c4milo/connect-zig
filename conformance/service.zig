//! connectrpc.conformance.v1.ConformanceService on colibri's router: a route for each method a
//! server implements (docs/testing_servers.md in the conformance suite, "Endpoints").
//!
//! Unimplemented has no route, so the router answers it as it answers any path it does not
//! know, and the client reads `unimplemented` (Connect protocol, "Error Codes"; gRPC
//! PROTOCOL-HTTP2.md, HTTP status 404).
const server = @import("server");
const rpc = @import("connect_colibri");
const service = @import("connectrpc_conformance_v1_service");
const unary = @import("unary.zig");
const streams = @import("streams.zig");
const constants = @import("constants.zig");
const App = @import("app.zig").App;
const Service = service.ConformanceService;

const options: rpc.RouteOptions = .{ .message_bytes = constants.message_bytes, .token_bytes = constants.token_bytes };

/// A route's error that is not an RPC's: the router answers 500.
fn on_error(_: *App, _: *const server.Request, failure: anyerror, response: *server.ResponseWriter) void {
    @import("std").debug.print("route error: {s}\n", .{@errorName(failure)});
    response.status = @intFromEnum(@import("http").status.Code.internal_server_error);
}

const unary_handler = unary.Unary(service.UnaryRequest, service.UnaryResponse).handle;
const idempotent_handler = unary.Unary(service.IdempotentUnaryRequest, service.IdempotentUnaryResponse).handle;

pub const routes = server.router(App, .{
    .error_handler = on_error,
    .routes = .{
        rpc.post(App, Service.unary, unary_handler, options),
        rpc.post(App, Service.idempotent_unary, idempotent_handler, options),
        rpc.get(App, Service.idempotent_unary, idempotent_handler, options),
        rpc.post(App, Service.server_stream, unary.server_stream, options),
        rpc.post(App, Service.client_stream, streams.ClientStream, options),
        rpc.post(App, Service.bidi_stream, streams.BidiStream, options),
    },
});

pub const Router = @TypeOf(routes).Of(.{
    .requests = constants.requests_at_once,
    .response_bytes = constants.response_bytes,
    .body_bytes = constants.body_bytes,
});
