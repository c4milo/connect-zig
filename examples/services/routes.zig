//! The route table both example servers serve: the ELIZA service and the demo service, under one
//! `server.router`.
const server = @import("server");
const App = @import("app.zig").App;
const eliza = @import("eliza.zig");
const demo = @import("demo.zig");

/// A route's error that is not an RPC's: the router answers 500.
fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = 500;
}

pub const routes = server.router(App, .{
    .error_handler = on_error,
    .routes = eliza.routes ++ demo.routes,
});

/// The router's pool: the calls the server answers at once, and room for each one's request and
/// response.
pub const Router = @TypeOf(routes).Of(.{ .requests = 8, .response_bytes = 8192, .body_bytes = 8192 });
