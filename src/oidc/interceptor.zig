//! The server interceptor that refuses a call with no valid bearer token (decision 34), and the
//! reader of the `Authorization` header it shares with a program.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const constants = @import("constants.zig");
const verifier_file = @import("verifier.zig");
const Verifier = verifier_file.Verifier;

pub const InterceptorOptions = struct {
    /// The calls the interceptor lets through with no check: a method's path, as
    /// "/package.Service/Method", or each method of a service, as "/package.Service/". A
    /// generated `Routes` gives one interceptor list to a whole service, so a login method or a
    /// health check is named here.
    exclude: []const []const u8 = &.{},
};

const scheme = "Bearer";
const space = ' ';
const path_separator = '/';
/// A path holds two separators: before the service and before the method.
const path_separators = 2;

/// The token of an `Authorization` header's value, or null when the value holds no bearer
/// credentials. RFC 6750 §2.1: credentials = "Bearer" 1*SP b64token. RFC 9110 §11.1: the
/// scheme's name is case-insensitive.
pub fn bearer_token(authorization: []const u8) ?[]const u8 {
    if (authorization.len < scheme.len) return null;
    if (!std.ascii.eqlIgnoreCase(authorization[0..scheme.len], scheme)) return null;
    const rest = authorization[scheme.len..];
    const token = std.mem.trimStart(u8, rest, &.{space});
    // One space at least follows the scheme, and a b64token holds none.
    if (token.len == rest.len or token.len == 0) return null;
    if (std.mem.indexOfScalar(u8, token, space) != null) return null;
    assert(token.len < authorization.len);
    return token;
}

/// A server interceptor for `RouteOptions.interceptors`. Its `on_call` verifies the call's
/// bearer token with the `Verifier` in the context's field `oidc`, and refuses the call with
/// `unauthenticated` when the token is missing or not valid. A handler then reads the claims
/// from `app.oidc.claims()`.
///
/// `on_call` takes any call type with `path`, `request_header` and `add_header`, as
/// `connect_colibri.Call` has them, so the module names no transport.
pub fn Interceptor(comptime options: InterceptorOptions) type {
    comptime check(options);
    return struct {
        pub fn on_call(app: anytype, call: anytype) ?connect.RpcError {
            if (comptime !@hasField(@TypeOf(app.*), "oidc")) @compileError("oidc.Interceptor: the context needs a field `oidc`, an `oidc.Verifier`");
            const verifier: *Verifier = &app.oidc;
            // A call starts with no claims, so no handler reads those of another call.
            verifier.verified = false;
            if (excluded(options.exclude, call.path)) return null;
            const authorization = call.request_header("authorization") orelse return refuse(call, .missing);
            const token = bearer_token(authorization) orelse return refuse(call, .missing);
            _ = verifier.verify(token) catch |failure| return refuse(call, if (failure == error.Expired) .expired else .invalid);
            return null;
        }
    };
}

/// An entry names a service and may name a method. An entry that named neither would exclude
/// every call.
fn check(comptime options: InterceptorOptions) void {
    if (options.exclude.len > constants.excluded_paths_max) @compileError("oidc.Interceptor: more excluded paths than constants.excluded_paths_max");
    for (options.exclude) |entry| {
        const service_start = 1;
        const shortest = "/s/";
        if (entry.len < shortest.len or entry[0] != path_separator or entry[service_start] == path_separator or std.mem.count(u8, entry, &.{path_separator}) != path_separators) {
            @compileError("oidc.Interceptor: an excluded path is \"/package.Service/Method\" or \"/package.Service/\", not \"" ++ entry ++ "\"");
        }
    }
}

fn excluded(comptime entries: []const []const u8, path: []const u8) bool {
    inline for (entries) |entry| {
        if (comptime entry[entry.len - 1] == path_separator) {
            if (std.mem.startsWith(u8, path, entry)) return true;
        } else if (std.mem.eql(u8, path, entry)) return true;
    }
    return false;
}

const Refusal = enum { missing, expired, invalid };

/// Answers `unauthenticated`, which Connect writes as HTTP 401 (Connect protocol, "Error
/// Codes"), with RFC 6750 §3's challenge. §3.1: a request with no credentials gets no error
/// code, and one whose token is expired, malformed or invalid for another reason gets
/// "invalid_token".
fn refuse(call: anytype, refusal: Refusal) connect.RpcError {
    const challenge = if (refusal == .missing) scheme else scheme ++ " error=\"invalid_token\"";
    // The refusal goes out without the challenge when the call has no room for a header.
    call.add_header("www-authenticate", challenge) catch {};
    return .{
        .code = .unauthenticated,
        .message = switch (refusal) {
            .missing => "missing bearer token",
            .expired => "token expired",
            .invalid => "invalid token",
        },
    };
}
