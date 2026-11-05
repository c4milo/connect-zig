//! connect_colibri: Connect, gRPC and gRPC-Web servers and clients over colibri's h11, h2 and h3
//! (design §7). A server serves each `connect.Method` as a route of `server.router`; a client
//! writes each call as a `client.Request` for its `client.ConnectionPool`.
const std = @import("std");
const builtin = @import("builtin");

pub const constants = @import("constants.zig");

const files = struct {
    pub const route = @import("route.zig");
    pub const refusal = @import("refusal.zig");
    pub const call = @import("call.zig");
    pub const client_call = @import("client_call.zig");
    pub const dispatch = @import("dispatch.zig");
};

/// The struct route that serves a method, and its router entries.
pub const Route = files.route.Route;
pub const RouteOptions = files.route.Options;
pub const Codings = files.route.Codings;
pub const post = files.route.post;
pub const get = files.route.get;
/// The router entries that answer 405 for the HTTP methods Connect does not serve.
pub const Refusals = files.refusal.Refusals;
/// What a handler reads about its call, and the streams it reads and writes.
pub const Call = files.call.Call;
pub const Sender = files.call.Sender;
pub const Receiver = files.call.Receiver;
/// A client call over colibri's pool.
pub const ClientCall = files.client_call.ClientCall;
pub const ClientCallWith = files.client_call.ClientCallWith;
pub const ClientCallBuffers = files.client_call.Buffers;
pub const failure_of = files.client_call.failure_of;

/// chapulin's one hook, which a program that links colibri's `tls` defines (colibri decision
/// 94). The module's own test binary defines it here; a program defines its own.
fn test_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) callconv(.c) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}

comptime {
    if (builtin.is_test) @export(&test_assert_fail, .{ .name = "ch_assert_fail", .linkage = .strong });
}

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "constants",         "Route",      "RouteOptions", "Codings",  "post",       "get",
        "Refusals",          "Call",       "Sender",       "Receiver", "ClientCall", "ClientCallWith",
        "ClientCallBuffers", "failure_of",
    });
}

test {
    std.testing.refAllDecls(files);
    _ = @import("connect_colibri_test.zig");
}
