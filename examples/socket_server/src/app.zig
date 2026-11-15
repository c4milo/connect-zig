//! The `App` and the route table of the socket server: every example's service under one router,
//! each with its room in the field it names (decision 41).
const server = @import("server");
const rpc = @import("connect_colibri");
const oidc = @import("oidc");
const eliza = @import("eliza");
const eliza_service = @import("eliza_service");
const streaming_service = @import("streaming_service");
const interceptors_service = @import("interceptors_service");
const errors_service = @import("errors_service");
const github_service = @import("github_service");
const account_service = @import("account_service");
const constants = @import("constants.zig");

/// What the routes read: each service's room, the verifier of the account service's tokens, and
/// the codings connect_colibri reads and writes messages in.
pub const App = struct {
    codings: rpc.Codings = .{},
    eliza: eliza_service.Room = .{},
    streaming: streaming_service.Room = .{},
    whoami: interceptors_service.Room = .{},
    calculator: errors_service.Room = .{},
    github: github_service.Room = .{},
    oidc: oidc.Verifier = undefined,
};

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

/// Every service's routes. A method Connect does not serve gets 405, on every path of the table.
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = eliza_service.Service(App).routes ++
        streaming_service.Service(App).routes ++
        interceptors_service.Service(App).routes ++
        errors_service.Service(App).routes ++
        github_service.Service(App).routes ++
        account_service.Service(App).routes ++
        rpc.Refusals(App, eliza.ElizaService.say).routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes });
