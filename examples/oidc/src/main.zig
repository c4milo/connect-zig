//! Example: a service behind OpenID Connect bearer tokens.
//!
//! The service module puts `oidc.Interceptor` around the account service. The interceptor checks
//! the token of each call with the `oidc.Verifier` of the program's `App`: its signature under
//! the issuer's key, then its issuer, its audience and its times. A handler reads the claims of
//! the token from the values of its call, `ctx.values(Values).oidc`. The service's `issuer`
//! stands where the OpenID provider would be: it signs the tokens this client sends.
//!
//! Both sides run in one process over the in-memory links of the harness. Two rounds run, one
//! over h2 and one over h3:
//!
//! - Status needs no token, since the interceptor excludes its path;
//! - Whoami without a token, with an expired one, and with one for another service is refused
//!   as unauthenticated, with RFC 6750's `WWW-Authenticate` challenge;
//! - Whoami with a valid token answers with the token's subject, email and role;
//! - between the rounds the issuer moves to a new key. A token of that key is refused first,
//!   and the verifier then says its keys are stale. The program passes it the issuer's keys
//!   again, as a real one fetches them again, and the same token passes.
//!
//! Anything other than the expected answers exits with an error, which is how `zig build test`
//! and CI know the example works. Run it with `zig build run`.
const std = @import("std");
const connect = @import("connect_zig").connect;
const harness = @import("harness");
const account = @import("account");
const service = @import("account_service");
const constants = @import("constants.zig");
const app_file = @import("app.zig");
const App = app_file.App;
const Router = app_file.Router;
const issuer = service.issuer;
const AccountService = account.AccountService;

pub const Error = error{CallWrong};

/// The instant the verifier judges tokens at: the instant the harness judges certificates at.
const now: i64 = @intCast(harness.now_seconds);

/// RFC 6750 §3: the challenge of a request with no token, and of one whose token is refused.
const challenge_bare = "Bearer";
const challenge_invalid = "Bearer error=\"invalid_token\"";

const Rounds = harness.Rounds(App, Router);

/// The room of one call's `Authorization` header, which lasts until its round ends.
const Bearer = struct {
    const prefix = "Bearer ";

    headers: [1]connect.Header,
    value: [prefix.len + issuer.token_len_max]u8,

    /// The call's headers: `Authorization` with `token` as its bearer credentials (RFC 6750
    /// §2.1).
    fn of(bearer: *Bearer, token: []const u8) Error![]const connect.Header {
        const value = std.fmt.bufPrint(&bearer.value, prefix ++ "{s}", .{token}) catch return error.CallWrong;
        bearer.headers[0] = .{ .name = "authorization", .value = value };
        return &bearer.headers;
    }
};

/// A call of a round, with the room of its `Authorization` header.
fn Asked(comptime method: connect.Method) type {
    return struct {
        client: harness.Call(method, .{}),
        bearer: Bearer,
    };
}

/// All the program holds, which `main` allocates once (decision 42). colibri reads and writes
/// each call until its round ends, so the calls live here.
const State = struct {
    app: App,
    /// What the program's calls share: the CPU features it detected (decision 51).
    client: connect.Client,
    rounds: Rounds,
    /// The issuer's first key, and the key it moves to between the rounds.
    first_key: issuer.Key,
    second_key: issuer.Key,
    /// The issuer's JWK Set, which the verifier reads, and the room of the token in progress.
    jwks_text: [issuer.jwks_len_max]u8,
    tokens: issuer.TokenRoom,
    status: Asked(AccountService.status),
    /// Whoami with no token, with a valid token of the first key, and with an expired one.
    missing: Asked(AccountService.whoami),
    valid: Asked(AccountService.whoami),
    expired: Asked(AccountService.whoami),
    /// Whoami with a token of the second key, refused in the first round and valid in the second.
    second: Asked(AccountService.whoami),
    /// Whoami with a token for another service.
    other_audience: Asked(AccountService.whoami),
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
    state.first_key = issuer.first_key();
    state.second_key = issuer.second_key();
    // The verifier starts with the issuer's first key alone. A real program fetches the JWK Set
    // and reads its clock.
    try service.start(&state.app.oidc, issuer.jwks(&state.jwks_text, &.{state.first_key}), now, state.app.cpu_features);
    defer state.app.oidc.deinit();
    try state.rounds.init(&state.app, init.io);
    defer state.rounds.deinit();
    try round_first_key(state);
    try change_keys(state);
    try round_both_keys(state);
    std.debug.print("oidc: every call answered as expected over h2 and h3\n", .{});
}

/// Over h2, while the verifier holds the issuer's first key alone.
fn round_first_key(state: *State) !void {
    const rounds = &state.rounds;
    try rounds.begin(.{ .h11 = false, .h3 = false });
    try ask(state, &state.status, .{ .use_get = true }, null);
    try ask(state, &state.missing, .{}, null);
    try ask(state, &state.valid, .{ .protocol = .grpc }, issuer.token(&state.tokens, &state.first_key, &.{ .subject = "ada", .audience = service.audience, .expires_unix_seconds = now + constants.hour_s, .email = "ada@example.com", .admin = true }));
    try ask(state, &state.expired, .{ .protocol = .grpc_web }, issuer.token(&state.tokens, &state.first_key, &.{ .subject = "ada", .audience = service.audience, .expires_unix_seconds = now - constants.hour_s }));
    try ask(state, &state.second, .{ .codec = .json }, issuer.token(&state.tokens, &state.second_key, &.{ .subject = "grace", .audience = service.audience, .expires_unix_seconds = now + constants.hour_s }));
    try rounds.finish(.h2);

    try expect_status(state);
    try expect_refused(state, &state.missing, "missing bearer token", challenge_bare, constants.http_unauthorized);
    try expect_caller(state, &state.valid, .{ .subject = "ada", .email = "ada@example.com", .admin = true });
    try expect_refused(state, &state.expired, "token expired", challenge_invalid, null);
    try expect_refused(state, &state.second, "invalid token", challenge_invalid, constants.http_unauthorized);
}

/// The verifier met a key it does not hold, so the program gets the issuer's keys again.
fn change_keys(state: *State) !void {
    if (!state.app.oidc.keys_stale()) return error.CallWrong;
    try state.app.oidc.set_keys(issuer.jwks(&state.jwks_text, &.{ state.first_key, state.second_key }));
    if (state.app.oidc.keys_stale()) return error.CallWrong;
    std.debug.print("oidc: the verifier asked for the issuer's keys again, and took both\n", .{});
}

/// Over h3, once the verifier holds both keys.
fn round_both_keys(state: *State) !void {
    const rounds = &state.rounds;
    try rounds.begin(.{ .h11 = false, .h2 = false });
    // An excluded path reads no token, so one that the verifier would refuse changes nothing.
    try ask(state, &state.status, .{}, "not-a-token");
    // The token of the second key that the first round refused.
    try ask(state, &state.second, .{}, issuer.token(&state.tokens, &state.second_key, &.{ .subject = "grace", .audience = service.audience, .expires_unix_seconds = now + constants.hour_s }));
    try ask(state, &state.other_audience, .{ .protocol = .grpc }, issuer.token(&state.tokens, &state.second_key, &.{ .subject = "grace", .audience = "another-service", .expires_unix_seconds = now + constants.hour_s }));
    try rounds.finish(.h3);

    try expect_status(state);
    try expect_caller(state, &state.second, .{ .subject = "grace", .email = "", .admin = false });
    try expect_refused(state, &state.other_audience, "invalid token", challenge_invalid, null);
}

/// Adds the call of `asked` to the round, with `token` as its bearer credentials when it has one.
fn ask(state: *State, asked: anytype, call_options: connect.client.Options, token: ?[]const u8) !void {
    var options = call_options;
    if (token) |text| options.headers = try asked.bearer.of(text);
    try asked.client.init(&state.client, {}, &options, &.{.{}});
    try state.rounds.request(&asked.client.call.request, &asked.client.call.response);
}

fn expect_status(state: *State) !void {
    var response = state.status.client.call.read(state.rounds.storage());
    const answer = try response.next(account.StatusResponse) orelse return error.CallWrong;
    if (!std.mem.eql(u8, answer.status, "ok")) return error.CallWrong;
    std.debug.print("oidc: status answered {s}, with no check of a token\n", .{answer.status});
}

/// What a Whoami answer states.
const Caller = struct { subject: []const u8, email: []const u8, admin: bool };

fn expect_caller(state: *State, asked: *const Asked(AccountService.whoami), expected: Caller) !void {
    var response = asked.client.call.read(state.rounds.storage());
    const answer = try response.next(account.WhoamiResponse) orelse {
        if (response.failure) |failure| std.debug.print("oidc: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.CallWrong;
    };
    if (!std.mem.eql(u8, answer.subject, expected.subject) or !std.mem.eql(u8, answer.email, expected.email)) return error.CallWrong;
    if (answer.admin != expected.admin) return error.CallWrong;
    std.debug.print("oidc: whoami answered {s}, email \"{s}\", admin {}\n", .{ answer.subject, answer.email, answer.admin });
}

/// Requires the call of `asked` to fail as unauthenticated with `message` and `challenge`, and
/// with `http_status` when the protocol states the outcome there.
fn expect_refused(state: *State, asked: *const Asked(AccountService.whoami), message: []const u8, challenge: []const u8, http_status: ?u16) !void {
    const call = &asked.client.call;
    var response = call.read(state.rounds.storage());
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
