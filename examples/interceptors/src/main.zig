//! Example: interceptors on both sides of a call.
//!
//! On the server, Whoami runs behind two interceptors, which the service defines and lists in
//! its route options:
//!
//! - `Logging` counts every call and adds a response header, and sees each call's outcome;
//! - `Auth` refuses a call with no bearer token as unauthenticated, before the handler runs.
//!
//! On the client, a `ClientCall` takes interceptors of its own, in its options:
//!
//! - `BearerToken` adds the authorization header to each request it builds;
//! - `Log` sees each response before the program reads it, and prints its HTTP status.
//!
//! Two rounds run, one over h2 and one over h3: Whoami with a token over Connect as a POST, with a
//! token over Connect as a GET in JSON, and without one over gRPC-Web, which `Auth` refuses. Run
//! it with `zig build run`.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const harness = @import("harness");
const interceptors = @import("interceptors");
const constants = @import("constants.zig");
const app_file = @import("app.zig");
const App = app_file.App;
const Router = app_file.Router;
const WhoamiService = interceptors.WhoamiService;

comptime {
    _ = harness.hooks;
}

pub const Error = error{CallWrong};

const caller = "Ada";
/// The HTTP status of a response whose head the server sent with no error (RFC 9110 §15.3.1).
const http_ok = connect.constants.protocol.status.ok;

/// Adds "authorization: Bearer Ada" to each request, as a program adds its credentials.
const BearerToken = struct {
    pub fn on_request(request: *connect.client.Request) !void {
        try request.add_header("authorization", "Bearer " ++ caller);
    }
};

/// Prints the HTTP status of each response the client reads. It runs before the program reads a
/// response's messages, so it sees the head alone. gRPC-Web answers 200 even when the call
/// fails, and puts the outcome in its trailers. A client interceptor is a type with no state,
/// so the program counts what it reads.
const Log = struct {
    pub fn on_response(response: *connect.client.Response) void {
        std.debug.print("interceptors: client read HTTP {d} over {s}\n", .{ response.incoming.status, @tagName(response.speaks.protocol) });
    }
};

const Signed = harness.Call(WhoamiService.whoami, .{ .interceptors = &.{ BearerToken, Log } });
const Anonymous = harness.Call(WhoamiService.whoami, .{ .interceptors = &.{Log} });

/// All the program holds, which `main` allocates once (decision 42). colibri reads and writes
/// each call until its round ends, so the calls live here.
const State = struct {
    app: App,
    rounds: harness.Rounds(App, Router),
    signed_post: Signed,
    signed_get: Signed,
    anonymous: Anonymous,
};

pub fn main(init: std.process.Init) !void {
    const state = try init.arena.allocator().create(State);
    state.app = .{};
    try state.rounds.init(&state.app);
    defer state.rounds.deinit();
    try round(state, .{ .h11 = false, .h3 = false }, .h2);
    try round(state, .{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("interceptors: every call answered as expected over h2 and h3\n", .{});
}

/// Runs the three calls over `expected`. The server's counts go on across rounds, so the round
/// checks what it added to them.
fn round(state: *State, protocols: client.Protocols, expected: client.Protocol) !void {
    const room = &state.app.whoami;
    const logged_before = room.logged;
    const failed_before = room.failed;
    const queried_before = room.queried;
    const rounds = &state.rounds;
    try rounds.begin(protocols);
    try state.signed_post.init(&.{}, &.{.{}});
    try state.signed_get.init(&.{ .codec = .json, .use_get = true }, &.{.{}});
    try state.anonymous.init(&.{ .protocol = .grpc_web }, &.{.{}});
    inline for (.{ "signed_post", "signed_get", "anonymous" }) |field| {
        const call = &@field(state, field).call;
        try rounds.request(&call.request, &call.response);
    }
    try rounds.finish(expected);

    const first = try expect_caller(state, &state.signed_post) - logged_before;
    const second = try expect_caller(state, &state.signed_get) - logged_before;
    // `Logging` counted the calls in the order they arrived, so each saw a different count.
    if (first == second or first < 0 or second < 0) return error.CallWrong;
    if (first >= constants.calls_count or second >= constants.calls_count) return error.CallWrong;
    try expect_refused(state);

    // The server's interceptors saw all three calls, and the one `Auth` refused.
    const logged = room.logged - logged_before;
    const failed = room.failed - failed_before;
    if (logged != constants.calls_count or failed != 1) return error.CallWrong;
    // The one GET reached the interceptor with its query.
    if (room.queried - queried_before != 1) return error.CallWrong;
    std.debug.print("interceptors: over {s}, server logged {d} calls, {d} failed; client read {d}\n", .{ @tagName(expected), logged, failed, constants.calls_count });
}

/// Reads a Whoami answer, checks the name, and returns the calls the server logged before it.
fn expect_caller(state: *State, signed: *const Signed) !i64 {
    var response = signed.call.read(state.rounds.storage());
    if (response.incoming.status != http_ok) return error.CallWrong;
    const answer = try response.next(interceptors.WhoamiResponse) orelse {
        if (response.failure) |failure| std.debug.print("interceptors: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.CallWrong;
    };
    if (!std.mem.eql(u8, answer.name, caller)) return error.CallWrong;
    std.debug.print("interceptors: whoami answered {s}, after {d} calls\n", .{ answer.name, answer.calls_before });
    return answer.calls_before;
}

/// Checks the call without a token failed unauthenticated. gRPC-Web states the outcome in its
/// trailers frame, so the response's head said HTTP 200.
fn expect_refused(state: *State) !void {
    var refused = state.anonymous.call.read(state.rounds.storage());
    if (refused.incoming.status != http_ok) return error.CallWrong;
    if (try refused.next(interceptors.WhoamiResponse) != null) return error.CallWrong;
    const failure = refused.failure orelse return error.CallWrong;
    if (failure.code != .unauthenticated) return error.CallWrong;
    std.debug.print("interceptors: refused without a token: {s}: {s}\n", .{ failure.code.name(), failure.message });
}
