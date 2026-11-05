//! Example: interceptors on both sides of a call.
//!
//! On the server, Whoami runs behind two interceptors, which `services/demo.zig` defines and
//! lists in its route options:
//!
//! - `Logging` counts every call and adds a response header, and sees each call's outcome;
//! - `Auth` refuses a call with no bearer token as unauthenticated, before the handler runs.
//!
//! On the client, an `ClientCallWith` takes interceptors of its own:
//!
//! - `BearerToken` adds the authorization header to each request it builds;
//! - `Tally` sees each response before the program reads it, and counts them.
//!
//! Two rounds run, one over h2 and one over h3: Whoami with a token over Connect as a POST, with a
//! token over Connect as a GET in JSON, and without one over gRPC-Web, which `Auth` refuses. Run
//! it with `zig build example-interceptors`.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const demo = @import("demo");
const harness = @import("services/link_client.zig");
const Service = demo.DemoService;

const caller = "Ada";
const calls_count = 3;

pub const Error = error{CallWrong};

/// Adds "authorization: Bearer Ada" to each request, as a program adds its credentials.
const BearerToken = struct {
    pub fn on_request(request: *connect.client.Request) !void {
        try request.add_header("authorization", "Bearer " ++ caller);
    }
};

/// Counts the responses the client read, and those with HTTP status 200. It runs before the
/// program reads a response's messages, so it sees the head alone. gRPC-Web answers 200 even when
/// the call fails, and puts the outcome in its trailers.
const Tally = struct {
    var read: u32 = 0;
    var http_ok: u32 = 0;

    pub fn on_response(response: *connect.client.Response) void {
        read += 1;
        if (response.incoming.status == http_ok_status) http_ok += 1;
    }
};

const http_ok_status = 200;

const Signed = rpc.ClientCallWith(Service.whoami, &.{ BearerToken, Tally });
const Anonymous = rpc.ClientCallWith(Service.whoami, &.{Tally});

var signed_post: Signed align(@alignOf(Signed)) = undefined;
var signed_get: Signed align(@alignOf(Signed)) = undefined;
var anonymous: Anonymous align(@alignOf(Anonymous)) = undefined;
var buffers: [calls_count]harness.CallBuffers align(@alignOf(harness.CallBuffers)) = undefined;

pub fn main() !void {
    try harness.init();
    defer harness.deinit();
    try round(.{ .h11 = false, .h3 = false }, .h2);
    try round(.{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("interceptors: every call answered as expected over h2 and h3\n", .{});
}

/// Runs the three calls over `expected`. The server's and the client's counts go on across
/// rounds, so the round checks what it added to them.
fn round(protocols: client.Protocols, expected: client.Protocol) !void {
    const logged_before = harness.app.logged;
    const failed_before = harness.app.failed;
    const queried_before = harness.app.queried;
    const read_before = Tally.read;
    const http_ok_before = Tally.http_ok;
    try harness.begin(protocols);
    try signed_post.init(.{}, &.{.{}}, harness.buffers(&buffers[0]));
    try signed_get.init(.{ .codec = .json, .use_get = true }, &.{.{}}, harness.buffers(&buffers[1]));
    try anonymous.init(.{ .protocol = .grpc_web }, &.{.{}}, harness.buffers(&buffers[2]));
    try harness.request(&signed_post.request, &signed_post.response);
    try harness.request(&signed_get.request, &signed_get.response);
    try harness.request(&anonymous.request, &anonymous.response);
    try harness.finish(expected);

    const first = try expect_caller(&signed_post) - logged_before;
    const second = try expect_caller(&signed_get) - logged_before;
    // `Logging` counted the calls in the order they arrived, so each saw a different count.
    if (first == second or first < 0 or second < 0) return error.CallWrong;
    if (first >= calls_count or second >= calls_count) return error.CallWrong;
    var refused = anonymous.read(harness.storage());
    if (try refused.next(demo.WhoamiResponse) != null) return error.CallWrong;
    const failure = refused.failure orelse return error.CallWrong;
    if (failure.code != .unauthenticated) return error.CallWrong;
    std.debug.print("interceptors: refused without a token: {s}: {s}\n", .{ failure.code.name(), failure.message });

    // The server's interceptors saw all three calls, and the one `Auth` refused.
    const logged = harness.app.logged - logged_before;
    const failed = harness.app.failed - failed_before;
    if (logged != calls_count or failed != 1) return error.CallWrong;
    // The one GET reached the interceptor with its query.
    if (harness.app.queried - queried_before != 1) return error.CallWrong;
    if (Tally.read - read_before != calls_count or Tally.http_ok - http_ok_before != calls_count) return error.CallWrong;
    std.debug.print("interceptors: over {s}, server logged {d} calls, {d} failed; client read {d}\n", .{ @tagName(expected), logged, failed, Tally.read - read_before });
}

/// Reads a Whoami answer, checks the name, and returns the calls the server logged before it.
fn expect_caller(client_call: *const Signed) !i64 {
    var response = client_call.read(harness.storage());
    const answer = try response.next(demo.WhoamiResponse) orelse {
        if (response.failure) |failure| std.debug.print("interceptors: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.CallWrong;
    };
    if (!std.mem.eql(u8, answer.name, caller)) return error.CallWrong;
    std.debug.print("interceptors: whoami answered {s}, after {d} calls\n", .{ answer.name, answer.calls_before });
    return answer.calls_before;
}
