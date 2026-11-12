//! The route table both example servers serve: the ELIZA service, the demo service, the
//! GitHub-style services and the account service, under one `server.Router`.
const server = @import("server");
const rpc = @import("connect_colibri");
const Service = @import("eliza").ElizaService;
const App = @import("app.zig").App;
const eliza = @import("eliza.zig");
const demo = @import("demo.zig");
const github = @import("github.zig");
const interop = @import("interop.zig");
const account = @import("account.zig");

/// A route's error that is not an RPC's: the router answers 500.
fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

/// The router, with its pool: the calls the server answers at once, and room for each one's
/// request and response. The interop service's messages, each a coverage case, take up to 64 KiB.
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    // A method Connect does not serve gets 405, on every path of the table.
    .routes = eliza.routes ++ demo.routes ++ github.routes ++ interop.routes ++ account.routes ++ rpc.Refusals(App, Service.say).routes,
}, .{ .requests = 8, .response_bytes = 64 * 1024, .body_bytes = 64 * 1024 });
