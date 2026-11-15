//! What both programs of the example share: the `App` the routes read, and the route table.
//! `main.zig` serves it in memory, and `serve.zig` on a socket.
const server = @import("server");
const rpc = @import("connect_colibri");
const otlp = @import("otlp");
const service = @import("otlp_service");
const constants = @import("constants.zig");

/// What the routes read: the receiver's room, and the codings it reads messages in. An
/// OpenTelemetry exporter sends gzip, so a server for one sets them (`serve.zig`).
pub const App = struct {
    codings: rpc.Codings = .{},
    otlp: service.Room = .{},
};

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

/// The receiver's routes. A method Connect does not serve gets 405, on every path of the table.
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = service.Service(App).routes ++ rpc.Refusals(App, otlp.TraceService.@"export").routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes });
