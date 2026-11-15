//! The account service, account.v1.AccountService: each method behind an OpenID Connect bearer
//! token, but Status, which the interceptor excludes (docs/decisions.md entries 34 to 36).
//!
//! - A program's `App` holds the verifier in its field `oidc`, which `oidc.Interceptor` reads by
//!   that name. So one route table may serve this service beside other services (decision 41).
//! - `start` gives the verifier the issuer's keys and the time. A real program fetches the keys
//!   and reads its clock itself: the library does no I/O and reads no clock.
//! - `Auth` checks the token of each call, and writes its claims into the values of the call.
//! - A handler reads the claims from `ctx.values(Values).oidc`.
//! - `issuer` is the test issuer, which signs the tokens of the example's client.
const connect = @import("connect");
const rpc = @import("connect_colibri");
const oidc = @import("oidc");
const account = @import("account");
const constants = @import("constants.zig");
const AccountService = account.AccountService;

/// The test-only OpenID provider: its keys, their JWK Set and the tokens it signs.
pub const issuer = @import("issuer.zig");

/// The name the issuer knows this service by: a token is for it when its "aud" holds this name.
pub const audience = "account-service";

/// What each call keeps for itself (decision 35): the claims of its token, or null on a path
/// the interceptor excludes.
pub const Values = struct {
    oidc: ?oidc.Claims = null,
};

/// Refuses a call with no valid bearer token as `unauthenticated`. A generated `Routes` gives
/// one interceptor list to each method of the service, so the one public method is excluded
/// here, by its path.
const Auth = oidc.Interceptor(Values, .{ .exclude = &.{AccountService.status.path()} });

/// The route options of each method: room for a message and a JSON token of the longest text,
/// and `Auth` around the handler.
pub const route_options: rpc.RouteOptions = .{
    .message_bytes = constants.message_len_max,
    .token_bytes = constants.message_len_max,
    .interceptors = &.{Auth},
    .Values = Values,
};

/// Starts `verifier`, the field `oidc` of a program's `App`, with `keys_text`, the issuer's JWK
/// Set, at `unix_seconds`. The program calls this before the server takes a call. It calls
/// `set_keys` again when `keys_stale` says a token named a key the verifier does not hold, and
/// `set_time` when its clock moves. `deinit` on the verifier ends it.
pub fn start(verifier: *oidc.Verifier, keys_text: []const u8, unix_seconds: i64) !void {
    try verifier.init(&.{ .issuer = issuer.name, .audience = audience, .leeway_s = constants.leeway_s });
    errdefer verifier.deinit();
    try verifier.set_keys(keys_text);
    verifier.set_time(unix_seconds);
}

/// The account service's handlers over `App`, and their entries in a route table:
/// `Service(App).routes`. Each handler passes the call to the function below of the same name.
pub fn Service(comptime App: type) type {
    return struct {
        pub const routes = AccountService.Routes(rpc, App, @This(), route_options).routes;

        pub fn status(_: *App, ctx: *rpc.Context, _: *const rpc.Request(account.StatusRequest), response: *rpc.Response(account.StatusResponse)) ?connect.RpcError {
            return status_in(ctx, response);
        }

        pub fn whoami(_: *App, ctx: *rpc.Context, _: *const rpc.Request(account.WhoamiRequest), response: *rpc.Response(account.WhoamiResponse)) ?connect.RpcError {
            return whoami_in(ctx, response);
        }
    };
}

/// Status needs no token. Its path is excluded, so its call has no claims, whatever it carries.
fn status_in(ctx: *rpc.Context, response: *rpc.Response(account.StatusResponse)) ?connect.RpcError {
    response.message.status = if (ctx.values(Values).oidc == null) "ok" else "claims on an excluded path";
    return null;
}

/// Whoami answers with what the caller's token states.
fn whoami_in(ctx: *rpc.Context, response: *rpc.Response(account.WhoamiResponse)) ?connect.RpcError {
    // `Auth` let the call through, so its values hold the token's claims. They last as long as
    // the call, so the response may point into them.
    const claims = if (ctx.values(Values).oidc) |*claims| claims else return .{ .code = .internal, .message = "no claims" };
    response.message.subject = claims.subject();
    response.message.admin = claims.holds("roles", "admin") catch false;
    // A lookup's string stays valid until the next lookup on the same claims, so it comes last.
    response.message.email = (claims.string("email") catch null) orelse "";
    return null;
}
