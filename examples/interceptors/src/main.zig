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
//! - `Log` sees each response before the program reads it, and prints its HTTP status;
//! - `Count` counts each response in the program's `Tally`, which each call's context points to
//!   (decision 44).
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

/// Adds "authorization: Bearer Ada" to each request, as a program adds its credentials. It reads
/// no context, so it takes any.
const BearerToken = struct {
    pub fn on_request(_: anytype, request: *connect.client.Request) !void {
        try request.add_header("authorization", "Bearer " ++ caller);
    }
};

/// Prints the HTTP status of each response the client reads. It runs before the program reads a
/// response's messages, so it sees the head alone. gRPC-Web answers 200 even when the call
/// fails, and puts the outcome in its trailers.
const Log = struct {
    pub fn on_response(_: anytype, response: *connect.client.Response) void {
        std.debug.print("interceptors: client read HTTP {d} over {s}\n", .{ response.incoming.status, @tagName(response.speaks.protocol) });
    }
};

/// What `Count` counts: the responses the client read, and those with HTTP status 200.
const Tally = struct {
    read: u32 = 0,
    http_ok: u32 = 0,
};

/// Counts each response the client reads in the call's context, a `*Tally`. A client
/// interceptor keeps no state of its own: the program hands the call a context (decision 44).
const Count = struct {
    pub fn on_response(tally: *Tally, response: *connect.client.Response) void {
        tally.read += 1;
        if (response.incoming.status == http_ok) tally.http_ok += 1;
    }
};

const Signed = harness.Call(WhoamiService.whoami, .{ .interceptors = &.{ BearerToken, Log, Count }, .Context = *Tally });
const Anonymous = harness.Call(WhoamiService.whoami, .{ .interceptors = &.{ Log, Count }, .Context = *Tally });

/// All the program holds, which `main` allocates once (decision 42). colibri reads and writes
/// each call until its round ends, so the calls live here.
const State = struct {
    app: App,
    /// What the program's calls share: the CPU features it detected (decision 51).
    client: connect.Client,
    rounds: harness.Rounds(App, Router),
    /// What the client's `Count` counted, across both rounds.
    tally: Tally,
    signed_post: Signed,
    signed_get: Signed,
    anonymous: Anonymous,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    // The program detects the CPU's features once, as it starts.
    state.app = .{ .cpu_features = .detect() };
    // One client for every call, with the CPU features the program detected.
    state.client = .{ .cpu_features = state.app.cpu_features };
    state.tally = .{};
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
    const tally_before = state.tally;
    const rounds = &state.rounds;
    try rounds.begin(protocols);
    try state.signed_post.init(&state.client, &state.tally, &.{}, &.{.{}});
    try state.signed_get.init(&state.client, &state.tally, &.{ .codec = .json, .use_get = true }, &.{.{}});
    try state.anonymous.init(&state.client, &state.tally, &.{ .protocol = .grpc_web }, &.{.{}});
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
    // The client's `Count` saw each response as the program read it, each with HTTP 200: the
    // refused call speaks gRPC-Web, whose outcome is in its trailers.
    const read = state.tally.read - tally_before.read;
    if (read != constants.calls_count or state.tally.http_ok - tally_before.http_ok != read) return error.CallWrong;
    std.debug.print("interceptors: over {s}, server logged {d} calls, {d} failed; client read {d}\n", .{ @tagName(expected), logged, failed, read });
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
