//! oidc: the check of an OpenID Connect bearer token on the server (docs/decisions.md entry 34).
//! A `Verifier` checks a JWT's signature with chapulin's `jws` calls, then its issuer, its
//! audience and its times. `Interceptor` refuses a call whose token the verifier refuses, and
//! lets the paths a program excludes through. The module does no I/O and reads no clock: the
//! program fetches the issuer's JWK Set and passes the time.
//!
//! ```zig
//! // The program's App holds the verifier.
//! try app.oidc.init(&.{ .issuer = "https://accounts.example.com", .audience = "my-service" });
//! try app.oidc.set_keys(jwks_text); // again when `app.oidc.keys_stale()`
//! app.oidc.set_time(unix_seconds); // when the program's clock moves
//!
//! // Each call keeps its own claims, in its values (decisions 35 and 36).
//! const Values = struct { oidc: ?oidc.Claims = null };
//! const Auth = oidc.Interceptor(Values, .{ .exclude = &.{ "/grpc.health.v1.Health/", "/auth.v1.Auth/Login" } });
//! const options: rpc.RouteOptions = .{ .interceptors = &.{Auth}, .Values = Values };
//! pub const routes = Service.Routes(rpc, App, @This(), options).routes;
//!
//! // In any callback of a call behind the interceptor:
//! if (ctx.values(Values).oidc) |*claims| {
//!     const email = try claims.string("email");
//!     const admin = try claims.holds("roles", "admin");
//! }
//! ```
const std = @import("std");
const builtin = @import("builtin");

pub const constants = @import("constants.zig");

const files = struct {
    pub const verifier = @import("verifier.zig");
    pub const interceptor = @import("interceptor.zig");
};

/// The verifier of a token, what it starts from, what it returns and why it refuses.
pub const Verifier = files.verifier.Verifier;
pub const VerifierOptions = files.verifier.VerifierOptions;
pub const Claims = files.verifier.Claims;
pub const Error = files.verifier.Error;
/// The server interceptor, and the reader of an `Authorization` header's bearer token.
pub const Interceptor = files.interceptor.Interceptor;
pub const InterceptorOptions = files.interceptor.InterceptorOptions;
pub const bearer_token = files.interceptor.bearer_token;

/// chapulin's one hook, which a program that links chapulin defines. The module's own test
/// binary defines it here; a program defines its own.
fn test_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) callconv(.c) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}

comptime {
    if (builtin.is_test) @export(&test_assert_fail, .{ .name = "ch_assert_fail", .linkage = .strong });
}

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "constants", "Verifier", "VerifierOptions", "Claims", "Error", "Interceptor", "InterceptorOptions", "bearer_token",
    });
}

test {
    _ = @import("reader.zig");
    _ = @import("token.zig");
    _ = @import("claims.zig");
    _ = @import("lookup.zig");
    _ = @import("jwks.zig");
    _ = files.verifier;
    _ = files.interceptor;
    _ = @import("verifier_test.zig");
    _ = @import("claims_test.zig");
    _ = @import("jwks_test.zig");
    _ = @import("interceptor_test.zig");
    _ = @import("lookup_test.zig");
}
