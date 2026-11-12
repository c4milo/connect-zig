//! The account service: each method of account.v1.AccountService behind an OpenID Connect bearer
//! token, but Status, which the interceptor excludes (docs/decisions.md entries 34 to 36).
//!
//! - The `App` holds the verifier, `app.oidc`. `start` gives it the issuer's keys and the time,
//!   which a real program fetches and reads itself: the library does no I/O and reads no clock.
//! - `Auth` checks each call's token, and writes its claims into the call's values.
//! - A handler reads the claims from `ctx.values(Values).oidc`.
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const oidc = @import("oidc");
const account = @import("account");
const issuer = @import("issuer.zig");
const app_file = @import("app.zig");
const App = app_file.App;
const Service = account.AccountService;

/// The name the issuer knows this service by: a token is for it when its "aud" holds this name.
pub const audience = "account-service";

/// The seconds the service's clock may differ from the issuer's.
const leeway_s = 30;

/// What each call keeps for itself (decision 35): the claims of its token, or null on a path
/// the interceptor excludes.
pub const Values = struct {
    oidc: ?oidc.Claims = null,
};

/// Refuses a call with no valid bearer token as `unauthenticated`. A generated `Routes` gives
/// one interceptor list to each method of the service, so the one public method is excluded
/// here, by its path.
const Auth = oidc.Interceptor(Values, .{ .exclude = &.{Service.status.path()} });

/// Starts the `App`'s verifier with `keys_text`, the issuer's JWK Set, at `unix_seconds`. A
/// program calls `set_keys` again when `keys_stale` says a token named a key it does not hold,
/// and `set_time` when its clock moves.
pub fn start(app: *App, keys_text: []const u8, unix_seconds: i64) !void {
    try app.oidc.init(&.{ .issuer = issuer.name, .audience = audience, .leeway_s = leeway_s });
    try app.oidc.set_keys(keys_text);
    app.oidc.set_time(unix_seconds);
}

/// Status needs no token. Its path is excluded, so its call has no claims, whatever it carries.
pub fn status(_: *App, ctx: *rpc.Context, _: *const rpc.Request(account.StatusRequest), response: *rpc.Response(account.StatusResponse)) ?connect.RpcError {
    response.message.status = if (ctx.values(Values).oidc == null) "ok" else "claims on an excluded path";
    return null;
}

/// Whoami answers with what the caller's token states.
pub fn whoami(_: *App, ctx: *rpc.Context, _: *const rpc.Request(account.WhoamiRequest), response: *rpc.Response(account.WhoamiResponse)) ?connect.RpcError {
    // `Auth` let the call through, so its values hold the token's claims. They last as long as
    // the call, so the response may point into them.
    const claims = if (ctx.values(Values).oidc) |*claims| claims else return .{ .code = .internal, .message = "no claims" };
    response.message.subject = claims.subject();
    response.message.admin = claims.holds("roles", "admin") catch false;
    // A lookup's string stays valid until the next lookup on the same claims, so it comes last.
    response.message.email = (claims.string("email") catch null) orelse "";
    return null;
}

const options: rpc.RouteOptions = .{
    .message_bytes = app_file.text_len_max,
    .token_bytes = app_file.text_len_max,
    .interceptors = &.{Auth},
    .Values = Values,
};

/// The service's entries in the route table of `routes.zig`.
pub const routes = Service.Routes(rpc, App, @This(), options).routes;
