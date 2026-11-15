//! What both programs of the example share: the `App` the routes read, and the route table.
//! `main.zig` serves it in memory, and `serve.zig` on a socket.
const server = @import("server");
const rpc = @import("connect_colibri");
const streaming = @import("streaming");
const service = @import("streaming_service");
const constants = @import("constants.zig");

/// What the routes read: the streaming service's room.
pub const App = struct {
    streaming: service.Room = .{},
};

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

/// The streaming service's routes. A method Connect does not serve gets 405, on every path of the
/// table.
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = service.Service(App).routes ++ rpc.Refusals(App, streaming.StreamingService.chat).routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes });
