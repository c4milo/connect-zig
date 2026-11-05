//! Router entries that answer 405 Method Not Allowed for the HTTP methods Connect does not serve.
//!
//! colibri's router answers 501 for a method that no route of its table names, and 405 with an
//! Allow header for a method that a route names on another path (colibri decision 122). A Connect
//! server answers 405 to every method it does not serve, as connect-go does, and the conformance
//! suite asks it. So a table holds these entries once, on one method's path: there they answer
//! 405 themselves, and on each other path colibri answers 405 for them.
const std = @import("std");
const connect = @import("connect");
const server = @import("server");
const constants = @import("constants.zig");

/// The Allow value of a path that serves POST alone, and of one that serves GET too (RFC 9110
/// §10.2.1; HEAD follows GET, §9.3.2).
const allow_post = "POST";
const allow_get_post = "GET, HEAD, POST";

/// Whether a table serves `method` as a GET too: a unary method with no side effects (Connect
/// protocol, "Unary-Get-Request").
fn served_as_get(comptime method: connect.Method) bool {
    return method.stream_type == .unary and method.idempotency == .no_side_effects;
}

/// The entries that answer 405 on `method`'s path for GET when the path does not serve it, and
/// for PUT, DELETE, OPTIONS, TRACE and PATCH: RFC 9110 §9.1's methods but CONNECT, which has no
/// path (§9.3.6), HEAD, which follows GET, and POST; and PATCH (RFC 5789). A table joins them to
/// its routes once, with `++`, for any one of its methods.
pub fn Refusals(comptime App: type, comptime method: connect.Method) type {
    const path = comptime method.path();
    const Refuse = RefuseWith(App, if (served_as_get(method)) allow_get_post else allow_post);
    const others = .{
        .{ .put, path, Refuse.on_request },
        .{ .delete, path, Refuse.on_request },
        .{ .options, path, Refuse.on_request },
        .{ .trace, path, Refuse.on_request },
        .{ "PATCH", path, Refuse.on_request },
    };
    return struct {
        pub const routes = if (served_as_get(method)) others else .{.{ .get, path, Refuse.on_request }} ++ others;
    };
}

fn RefuseWith(comptime App: type, comptime allow: []const u8) type {
    return struct {
        /// RFC 9110 §15.5.6: a 405 carries an Allow header that lists the methods the path serves.
        fn on_request(_: *App, _: *const server.Request, _: void, _: void, response: *server.ResponseWriter) !void {
            response.status = constants.status_method_not_allowed;
            try response.header("allow", allow);
            return response.end();
        }
    };
}

const testing = std.testing;

test "a path that serves GET is not refused GET, and each other method is refused once" {
    const Note = struct {};
    const say: connect.Method = .{ .service = "test.Eliza", .name = "Say", .Request = Note, .Response = Note, .stream_type = .unary, .idempotency = .no_side_effects };
    const chat: connect.Method = .{ .service = "test.Eliza", .name = "Chat", .Request = Note, .Response = Note, .stream_type = .bidi_stream };
    const App = struct {};
    const with_get = Refusals(App, say).routes;
    const without_get = Refusals(App, chat).routes;
    try testing.expectEqual(without_get.len, with_get.len + 1);
    try testing.expect(with_get[0][0] == .put);
    try testing.expect(without_get[0][0] == .get);
    try testing.expectEqualStrings("/test.Eliza/Chat", without_get[0][1]);
}
