//! What both programs of the example share: the `App` the routes read, and the route table.
//! `main.zig` serves it in memory, and `serve.zig` on a socket.
const server = @import("server");
const rpc = @import("connect_colibri");
const interceptors = @import("interceptors");
const service = @import("interceptors_service");
const constants = @import("constants.zig");

/// What the routes read: the Whoami service's room.
pub const App = struct {
    whoami: service.Room = .{},
};

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

/// The Whoami service's routes. A method Connect does not serve gets 405, on every path of the
/// table.
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = service.Service(App).routes ++ rpc.Refusals(App, interceptors.WhoamiService.whoami).routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes, .header_bytes = 0 });
