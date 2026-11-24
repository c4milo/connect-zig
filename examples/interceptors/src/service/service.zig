//! The Whoami service, interceptors.v1.WhoamiService: its handler, and the two interceptors
//! around it. A program's `App` holds the service's `Room` in its field `whoami`, so one route
//! table may serve Whoami beside other services (decision 41).
//!
//! - `Logging` counts every call and marks its reply with a header.
//! - `Auth` refuses a call without a bearer token, before the handler runs.
//!
//! Whoami has no side effects, so it also answers a GET.
const std = @import("std");
const connect = @import("connect_zig").connect;
const rpc = @import("connect_zig").connect_colibri;
const interceptors = @import("interceptors");
const constants = @import("constants.zig");

/// The service's part of a program's `App`: the counts of its interceptors, which go on across
/// calls.
pub const Room = struct {
    /// The calls `Logging` saw start, and those it saw fail.
    logged: u32 = 0,
    failed: u32 = 0,
    /// The logged calls that arrived as a Connect GET, with their message in the query.
    queried: u32 = 0,
};

/// The route options of Whoami before its interceptors: room for a message and a JSON token of
/// `text_len_max` octets.
pub const route_options: rpc.RouteOptions = .{ .message_bytes = constants.text_len_max, .token_bytes = constants.text_len_max };

/// The prefix of the authorization header `Auth` reads (RFC 6750 §2.1).
pub const bearer_prefix = "Bearer ";
/// The response header `Logging` adds to each reply, and its value.
pub const logged_header = "demo-logged";
pub const logged_value = "yes";
/// The trailer Whoami adds: the caller's name. A Connect unary reply sends it as the header
/// "trailer-whoami-caller".
pub const caller_trailer = "whoami-caller";

/// The service's handler and interceptors over `App`, and their entries in a route table:
/// `Service(App).routes`. Each passes the call to the function below, with the service's room.
pub fn Service(comptime App: type) type {
    return struct {
        /// Whoami runs behind both interceptors, as a POST and as a GET.
        pub const routes = interceptors.WhoamiService.Routes(rpc, App, @This(), guarded).routes;
        const guarded = with_interceptors(&.{ Logging, Auth });

        /// Counts each call, and each GET among them, and marks its reply. It wraps `Auth`, so it
        /// also sees the calls `Auth` refuses, and counts them as failed.
        pub const Logging = struct {
            pub fn on_call(app: *App, _: *rpc.Context, request: *const rpc.AnyRequest, response: *rpc.AnyResponse) ?connect.RpcError {
                return log_call(&app.whoami, request, response);
            }

            pub fn on_finish(app: *App, _: *rpc.Context, _: *rpc.AnyResponse, failure: ?connect.RpcError) ?connect.RpcError {
                return log_finish(&app.whoami, failure);
            }
        };

        /// Refuses a call whose request has no "authorization: Bearer <name>" header.
        pub const Auth = struct {
            pub fn on_call(_: *App, _: *rpc.Context, request: *const rpc.AnyRequest, _: *rpc.AnyResponse) ?connect.RpcError {
                return authenticate(request);
            }
        };

        pub fn whoami(app: *App, _: *rpc.Context, request: *const rpc.Request(interceptors.WhoamiRequest), response: *rpc.Response(interceptors.WhoamiResponse)) ?connect.RpcError {
            return whoami_in(&app.whoami, request, response);
        }
    };
}

fn with_interceptors(comptime list: []const type) rpc.RouteOptions {
    var options = route_options;
    options.interceptors = list;
    return options;
}

fn log_call(room: *Room, request: *const rpc.AnyRequest, response: *rpc.AnyResponse) ?connect.RpcError {
    room.logged += 1;
    if (request.query().len != 0) room.queried += 1;
    response.add_header(logged_header, logged_value) catch return .{ .code = .internal, .message = "no room for a header" };
    return null;
}

fn log_finish(room: *Room, failure: ?connect.RpcError) ?connect.RpcError {
    if (failure != null) room.failed += 1;
    return failure;
}

fn authenticate(request: *const rpc.AnyRequest) ?connect.RpcError {
    _ = caller_of(request) orelse return .{ .code = .unauthenticated, .message = "a bearer token is required" };
    return null;
}

/// The name a request's bearer token carries, or null.
pub fn caller_of(request: *const rpc.AnyRequest) ?[]const u8 {
    const value = request.header("authorization") orelse return null;
    if (!std.mem.startsWith(u8, value, bearer_prefix)) return null;
    const name = value[bearer_prefix.len..];
    if (name.len == 0) return null;
    return name;
}

/// Whoami answers with the caller's name, which `Auth` already checked.
fn whoami_in(room: *Room, request: *const rpc.Request(interceptors.WhoamiRequest), response: *rpc.Response(interceptors.WhoamiResponse)) ?connect.RpcError {
    response.message.name = caller_of(&request.any).?;
    response.add_trailer(caller_trailer, response.message.name) catch {};
    // `Logging` counted this call before the handler ran.
    response.message.calls_before = room.logged - 1;
    return null;
}
