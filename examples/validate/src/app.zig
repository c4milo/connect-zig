//! What both programs of the example share: the `App` the routes read, and the route table.
//! `main.zig` serves it in memory, and `serve.zig` on a socket.
const server = @import("connect_zig").server;
const rpc = @import("connect_zig").connect_colibri;
const signup = @import("signup");
const platform = @import("connect_zig").platform;
const service = @import("signup_service");
const constants = @import("constants.zig");

/// What the routes read: the signup service's room, and the CPU features, stdx's type, which
/// `protovalidate.Interceptor` reads by this name. The program detects them once as it starts.
pub const App = struct {
    signup: service.Room = .{},
    cpu_features: platform.CpuFeatures,
};

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

/// The signup service's routes. A method Connect does not serve gets 405, on every path of the
/// table.
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    // What each call keeps for itself: what the error of a refused message points to (decision
    // 35).
    .Values = service.Values,
    .routes = service.Service(App).routes ++ rpc.Refusals(App, signup.SignupService.register).routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes, .header_bytes = 0 });
