//! What both programs of the example share: the `App` the routes read, and the route table.
//! `main.zig` serves it in memory, and `serve.zig` on a socket.
const server = @import("connect_zig").server;
const platform = @import("connect_zig").platform;
const rpc = @import("connect_zig").connect_colibri;
const errors = @import("errors");
const service = @import("errors_service");
const constants = @import("constants.zig");

/// What the routes read: the calculator service's room.
pub const App = struct {
    /// The CPU features the routes read and write each message with, stdx's type. The program
    /// detects them once, as it starts.
    cpu_features: platform.CpuFeatures,
    calculator: service.Room = .{},
};

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

/// The calculator service's routes. A method Connect does not serve gets 405, on every path of
/// the table.
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = service.Service(App).routes ++ rpc.Refusals(App, errors.CalculatorService.divide).routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes, .header_bytes = 0 });
