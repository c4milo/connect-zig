//! What both programs of the example share: the `App` the routes read, and the route table.
//! `main.zig` serves it in memory, and `serve.zig` on a socket.
const server = @import("server");
const rpc = @import("connect_colibri");
const eliza = @import("eliza");
const service = @import("eliza_service");
const constants = @import("constants.zig");

/// What the routes read: ELIZA's room.
pub const App = struct {
    eliza: service.Room = .{},
};

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

/// ELIZA's routes. A method Connect does not serve gets 405, on every path of the table.
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = service.Service(App).routes ++ rpc.Refusals(App, eliza.ElizaService.say).routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes, .header_bytes = 0 });
