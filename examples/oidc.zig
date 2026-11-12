//! Example: a service behind OpenID Connect bearer tokens.
//!
//! `services/account.zig` puts `oidc.Interceptor` around the account service. The interceptor
//! checks each call's token with the server's `oidc.Verifier`: its signature under the issuer's
//! key, then its issuer, its audience and its times. A handler reads the token's claims from its
//! call's values, `ctx.values(Values).oidc`. `services/issuer.zig` stands where the OpenID
//! provider would be: it signs the tokens this client sends.
//!
//! Two rounds run, one over h2 and one over h3:
//!
//! - Status needs no token, since the interceptor excludes its path;
//! - Whoami without a token, with an expired one, and with one for another service is refused
//!   as unauthenticated, with RFC 6750's `WWW-Authenticate` challenge;
//! - Whoami with a valid token answers with the token's subject, email and role;
//! - between the rounds the issuer moves to a new key. A token of that key is refused first,
//!   and the verifier then says its keys are stale. The program passes it the issuer's keys
//!   again, as a real one fetches them again, and the same token passes.
//!
//! Run it with `zig build example-oidc`.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const account = @import("account");
const identity = @import("test_identity");
const harness = @import("services/link_client.zig");
const service = @import("services/account.zig");
const issuer = @import("services/issuer.zig");
const Service = account.AccountService;

pub const Error = error{CallWrong};

/// The instant the example server judges tokens at, and an hour, in seconds.
const now: i64 = @intCast(identity.now_seconds);
const hour_s = 3600;

/// The Whoami calls of one round, at most.
const calls_max = 4;
const bearer_len = issuer.token_len_max + "Bearer ".len;

const Status = rpc.ClientCall(Service.status, .{});
const Whoami = rpc.ClientCall(Service.whoami, .{});

var status: Status align(@alignOf(Status)) = undefined;
var whoamis: [calls_max]Whoami align(@alignOf(Whoami)) = undefined;
var status_buffers: harness.CallBuffers align(@alignOf(harness.CallBuffers)) = undefined;
var buffers: [calls_max]harness.CallBuffers align(@alignOf(harness.CallBuffers)) = undefined;
/// Each call's `Authorization` header, which lasts until its round ends.
var headers: [calls_max + 1][1]connect.Header align(@alignOf(connect.Header)) = undefined;
var bearers: [calls_max + 1][bearer_len]u8 = undefined;
var token_text: [issuer.token_len_max]u8 = undefined;
var jwks_text: [issuer.jwks_len_max]u8 = undefined;

/// RFC 6750 §3: the challenge of a request with no token, and of one whose token is refused.
const challenge_bare = "Bearer";
const challenge_invalid = "Bearer error=\"invalid_token\"";
/// RFC 9110 §15.5.2, which Connect answers an unauthenticated unary call with.
const http_unauthorized = 401;

pub fn main() !void {
    try harness.init();
    defer harness.deinit();
    const first = issuer.first_key();
    const second = issuer.second_key();
    try round_first_key(&first, &second);
    // The verifier met a key it does not hold, so the program gets the issuer's keys again.
    if (!harness.app.oidc.keys_stale()) return error.CallWrong;
    try harness.app.oidc.set_keys(issuer.jwks(&jwks_text, &.{ first, second }));
    if (harness.app.oidc.keys_stale()) return error.CallWrong;
    std.debug.print("oidc: the verifier asked for the issuer's keys again, and took both\n", .{});
    try round_both_keys(&second);
    std.debug.print("oidc: every call answered as expected over h2 and h3\n", .{});
}

/// Over h2, while the verifier holds the issuer's first key alone.
fn round_first_key(first: *const issuer.Key, second: *const issuer.Key) !void {
    try harness.begin(.{ .h11 = false, .h3 = false });
    try ask_status(.{ .use_get = true }, null);
    try ask(0, .{}, null);
    try ask(1, .{ .protocol = .grpc }, issuer.token(&token_text, first, &.{ .subject = "ada", .audience = service.audience, .expires_unix_seconds = now + hour_s, .email = "ada@example.com", .admin = true }));
    try ask(2, .{ .protocol = .grpc_web }, issuer.token(&token_text, first, &.{ .subject = "ada", .audience = service.audience, .expires_unix_seconds = now - hour_s }));
    try ask(3, .{ .codec = .json }, issuer.token(&token_text, second, &.{ .subject = "grace", .audience = service.audience, .expires_unix_seconds = now + hour_s }));
    try harness.finish(.h2);

    try expect_status();
    try expect_refused(0, "missing bearer token", challenge_bare, http_unauthorized);
    try expect_caller(1, .{ .subject = "ada", .email = "ada@example.com", .admin = true });
    try expect_refused(2, "token expired", challenge_invalid, null);
    try expect_refused(3, "invalid token", challenge_invalid, http_unauthorized);
}

/// Over h3, once the verifier holds both keys.
fn round_both_keys(second: *const issuer.Key) !void {
    try harness.begin(.{ .h11 = false, .h2 = false });
    const refused_before = issuer.token(&token_text, second, &.{ .subject = "grace", .audience = service.audience, .expires_unix_seconds = now + hour_s });
    // An excluded path reads no token, so one that the verifier would refuse changes nothing.
    try ask_status(.{}, "not-a-token");
    try ask(0, .{}, refused_before);
    try ask(1, .{ .protocol = .grpc }, issuer.token(&token_text, second, &.{ .subject = "grace", .audience = "another-service", .expires_unix_seconds = now + hour_s }));
    try harness.finish(.h3);

    try expect_status();
    try expect_caller(0, .{ .subject = "grace", .email = "", .admin = false });
    try expect_refused(1, "invalid token", challenge_invalid, null);
}

/// The `Authorization` header of the call at `slot`, with `token` as its bearer credentials.
fn authorization(slot: usize, token: []const u8) Error![]const connect.Header {
    const value = std.fmt.bufPrint(&bearers[slot], "Bearer {s}", .{token}) catch return error.CallWrong;
    headers[slot][0] = .{ .name = "authorization", .value = value };
    return &headers[slot];
}

/// Adds a Whoami call to the round, with `token` when it has one.
fn ask(index: usize, call_options: connect.client.Options, token: ?[]const u8) !void {
    var options = call_options;
    if (token) |text| options.headers = try authorization(index, text);
    try whoamis[index].init(&options, &.{.{}}, &harness.buffers(&buffers[index]));
    try harness.request(&whoamis[index].request, &whoamis[index].response);
}

fn ask_status(call_options: connect.client.Options, token: ?[]const u8) !void {
    var options = call_options;
    if (token) |text| options.headers = try authorization(calls_max, text);
    try status.init(&options, &.{.{}}, &harness.buffers(&status_buffers));
    try harness.request(&status.request, &status.response);
}

fn expect_status() !void {
    var response = status.read(harness.storage());
    const answer = try response.next(account.StatusResponse) orelse return error.CallWrong;
    if (!std.mem.eql(u8, answer.status, "ok")) return error.CallWrong;
    std.debug.print("oidc: status answered {s}, with no check of a token\n", .{answer.status});
}

/// What a Whoami answer states.
const Caller = struct { subject: []const u8, email: []const u8, admin: bool };

fn expect_caller(index: usize, expected: Caller) !void {
    var response = whoamis[index].read(harness.storage());
    const answer = try response.next(account.WhoamiResponse) orelse {
        if (response.failure) |failure| std.debug.print("oidc: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.CallWrong;
    };
    if (!std.mem.eql(u8, answer.subject, expected.subject) or !std.mem.eql(u8, answer.email, expected.email)) return error.CallWrong;
    if (answer.admin != expected.admin) return error.CallWrong;
    std.debug.print("oidc: whoami answered {s}, email \"{s}\", admin {}\n", .{ answer.subject, answer.email, answer.admin });
}

/// Requires the call at `index` to fail as unauthenticated with `message` and `challenge`, and
/// with `http_status` when the protocol states the outcome there.
fn expect_refused(index: usize, message: []const u8, challenge: []const u8, http_status: ?u16) !void {
    const call = &whoamis[index];
    var response = call.read(harness.storage());
    if (try response.next(account.WhoamiResponse) != null) return error.CallWrong;
    const failure = response.failure orelse return error.CallWrong;
    if (failure.code != .unauthenticated or !std.mem.eql(u8, failure.message, message)) return error.CallWrong;
    const header = call.response.headers.get("www-authenticate") orelse return error.CallWrong;
    if (!std.mem.eql(u8, header, challenge)) return error.CallWrong;
    if (http_status) |expected| {
        if (response.incoming.status != expected) return error.CallWrong;
    }
    std.debug.print("oidc: refused: {s}, with www-authenticate: {s}\n", .{ failure.message, header });
}
