//! The interceptor's tests, with a call type of the test's own: the paths it excludes, the
//! refusals it answers and their challenge (RFC 6750 §3), and the claims it leaves.
const std = @import("std");
const testing = std.testing;
const connect = @import("connect");
const interceptor = @import("interceptor.zig");
const verifier_file = @import("verifier.zig");
const support = @import("test_support.zig");

/// What the interceptor reads of a call, as `connect_colibri.Call` names it.
const Call = struct {
    path: []const u8,
    authorization: ?[]const u8 = null,
    challenge: ?[]const u8 = null,
    /// Whether the call has room for one more header.
    room: bool = true,

    pub fn request_header(call: *const Call, name: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, name, "authorization")) call.authorization else null;
    }

    pub fn add_header(call: *Call, name: []const u8, value: []const u8) error{TooManyHeaders}!void {
        if (!call.room) return error.TooManyHeaders;
        std.debug.assert(std.mem.eql(u8, name, "www-authenticate"));
        call.challenge = value;
    }
};

const App = struct {
    oidc: verifier_file.Verifier,
};

/// The call's request context, as a program declares it in `RouteOptions.RequestContext`.
const RequestContext = struct {
    oidc: ?verifier_file.Claims = null,
};

const Auth = interceptor.Interceptor(.{ .exclude = &.{ "/auth.v1.Auth/Login", "/grpc.health.v1.Health/" } });
const Strict = interceptor.Interceptor(.{});

const Bench = struct {
    fixture: support.Fixture,
    app: App,
    header: [support.text_bytes]u8,

    fn init(bench: *Bench) !void {
        try bench.fixture.init(.es256);
        bench.app.oidc = bench.fixture.verifier;
    }

    /// An `Authorization` value with a token of `payload`.
    fn bearer(bench: *Bench, payload: []const u8) []const u8 {
        return std.fmt.bufPrint(&bench.header, "Bearer {s}", .{bench.fixture.token(payload)}) catch unreachable;
    }
};

fn expect_refused(refusal: ?connect.RpcError, call: *const Call, message: []const u8, challenge: []const u8) !void {
    try testing.expectEqual(connect.Code.unauthenticated, refusal.?.code);
    try testing.expectEqualStrings(message, refusal.?.message);
    try testing.expectEqualStrings(challenge, call.challenge.?);
}

const head = "{\"iss\":\"" ++ support.issuer ++ "\",\"aud\":\"";

test "a call with a valid token passes, and its request context holds the claims" {
    var bench: Bench = undefined;
    try bench.init();
    var call: Call = .{ .path = "/demo.v1.Demo/Add", .authorization = bench.bearer(support.good_claims) };
    var context: RequestContext = .{};
    try testing.expectEqual(@as(?connect.RpcError, null), Auth.on_call(&bench.app, &call, &context));
    try testing.expectEqual(@as(?[]const u8, null), call.challenge);
    try testing.expectEqualStrings("user-1", context.oidc.?.subject());
    try testing.expectEqualStrings(support.good_claims, context.oidc.?.payload());
}

test "two calls keep their own claims, whatever the order of their callbacks" {
    var bench: Bench = undefined;
    try bench.init();
    var first_call: Call = .{ .path = "/demo.v1.Demo/Chat", .authorization = bench.bearer(support.good_claims) };
    var first: RequestContext = .{};
    try testing.expectEqual(@as(?connect.RpcError, null), Auth.on_call(&bench.app, &first_call, &first));
    const later = head ++ support.audience ++ "\",\"sub\":\"user-2\",\"exp\":1700003600}";
    var second_call: Call = .{ .path = "/demo.v1.Demo/Chat", .authorization = bench.bearer(later) };
    var second: RequestContext = .{};
    try testing.expectEqual(@as(?connect.RpcError, null), Auth.on_call(&bench.app, &second_call, &second));
    // A third call that the verifier refuses leaves the first two as they were.
    var third_call: Call = .{ .path = "/demo.v1.Demo/Chat", .authorization = "Bearer a.b.c" };
    var third: RequestContext = .{};
    try testing.expect(Auth.on_call(&bench.app, &third_call, &third) != null);
    try testing.expectEqualStrings("user-1", first.oidc.?.subject());
    try testing.expectEqualStrings("user-2", second.oidc.?.subject());
    try testing.expectEqual(@as(?verifier_file.Claims, null), third.oidc);
}

test "a call with no bearer credentials is refused with a bare challenge" {
    var bench: Bench = undefined;
    try bench.init();
    // RFC 6750 §3.1: a request with no authentication information gets no error code.
    const values = [_]?[]const u8{ null, "", "Basic dXNlcjpwYXNz", "Bearer", "Bearer ", "Token abc" };
    for (values) |value| {
        var call: Call = .{ .path = "/demo.v1.Demo/Add", .authorization = value };
        var context: RequestContext = .{};
        try expect_refused(Auth.on_call(&bench.app, &call, &context), &call, "missing bearer token", "Bearer");
        try testing.expectEqual(@as(?verifier_file.Claims, null), context.oidc);
    }
}

test "a call whose token the verifier refuses is refused with invalid_token" {
    var bench: Bench = undefined;
    try bench.init();
    // RFC 6750 §3.1: an expired, malformed or otherwise invalid token.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ head ++ support.audience ++ "\",\"exp\":1700000000}", "token expired" },
        .{ head ++ support.audience ++ "\",\"exp\":1800000000,\"nbf\":1750000000}", "invalid token" },
        .{ head ++ "other\",\"exp\":1800000000}", "invalid token" },
        .{ head ++ support.audience ++ "\"}", "invalid token" },
    };
    for (cases) |case| {
        var call: Call = .{ .path = "/demo.v1.Demo/Add", .authorization = bench.bearer(case[0]) };
        var context: RequestContext = .{};
        try expect_refused(Auth.on_call(&bench.app, &call, &context), &call, case[1], "Bearer error=\"invalid_token\"");
        try testing.expectEqual(@as(?verifier_file.Claims, null), context.oidc);
    }
    var call: Call = .{ .path = "/demo.v1.Demo/Add", .authorization = "Bearer not-a-token" };
    var context: RequestContext = .{};
    try expect_refused(Auth.on_call(&bench.app, &call, &context), &call, "invalid token", "Bearer error=\"invalid_token\"");
}

test "a call with no room for a header is still refused" {
    var bench: Bench = undefined;
    try bench.init();
    var call: Call = .{ .path = "/demo.v1.Demo/Add", .room = false };
    var context: RequestContext = .{};
    try testing.expectEqual(connect.Code.unauthenticated, Auth.on_call(&bench.app, &call, &context).?.code);
    try testing.expectEqual(@as(?[]const u8, null), call.challenge);
}

test "an excluded path passes with no token and no claims, and each other path is checked" {
    var bench: Bench = undefined;
    try bench.init();
    const excluded = [_][]const u8{ "/auth.v1.Auth/Login", "/grpc.health.v1.Health/Check", "/grpc.health.v1.Health/Watch", "/grpc.health.v1.Health/" };
    for (excluded) |path| {
        // A token on an excluded path is not read: the claims stay null.
        var call: Call = .{ .path = path, .authorization = bench.bearer(support.good_claims) };
        var context: RequestContext = .{};
        try testing.expectEqual(@as(?connect.RpcError, null), Auth.on_call(&bench.app, &call, &context));
        try testing.expectEqual(@as(?verifier_file.Claims, null), context.oidc);
        // With no list, the same path is checked.
        var bare: Call = .{ .path = path };
        try testing.expectEqual(connect.Code.unauthenticated, Strict.on_call(&bench.app, &bare, &context).?.code);
    }
    // A method beside the excluded one, a path the entry is a prefix of, and a service whose
    // name the excluded service's starts.
    const checked = [_][]const u8{
        "/auth.v1.Auth/Logout",              "/auth.v1.Auth/LoginAdmin", "/auth.v1.Auth/Logi",    "/auth.v1.Auth/",
        "/grpc.health.v1.HealthAdmin/Check", "/grpc.health.v1.Health",   "/grpc.health.v1/Check", "/x/grpc.health.v1.Health/Check",
        "/Auth.v1.Auth/Login",               "",
    };
    for (checked) |path| {
        var call: Call = .{ .path = path };
        var context: RequestContext = .{};
        try testing.expectEqual(connect.Code.unauthenticated, Auth.on_call(&bench.app, &call, &context).?.code);
    }
}

test "the interceptor clears a request context that held claims" {
    var bench: Bench = undefined;
    try bench.init();
    var call: Call = .{ .path = "/demo.v1.Demo/Add", .authorization = bench.bearer(support.good_claims) };
    var context: RequestContext = .{};
    try testing.expectEqual(@as(?connect.RpcError, null), Auth.on_call(&bench.app, &call, &context));
    var login: Call = .{ .path = "/auth.v1.Auth/Login" };
    try testing.expectEqual(@as(?connect.RpcError, null), Auth.on_call(&bench.app, &login, &context));
    try testing.expectEqual(@as(?verifier_file.Claims, null), context.oidc);
    try testing.expectEqual(@as(?connect.RpcError, null), Auth.on_call(&bench.app, &call, &context));
    var bare: Call = .{ .path = "/demo.v1.Demo/Add" };
    try testing.expect(Auth.on_call(&bench.app, &bare, &context) != null);
    try testing.expectEqual(@as(?verifier_file.Claims, null), context.oidc);
}

test "bearer_token reads the credentials RFC 6750 writes" {
    const read = [_]struct { []const u8, []const u8 }{
        .{ "Bearer abc", "abc" },
        // RFC 9110 §11.1: the scheme's name is case-insensitive.
        .{ "bearer abc", "abc" },
        .{ "BEARER abc", "abc" },
        // RFC 6750 §2.1: one space or more.
        .{ "Bearer   a.b-c_d~e+f/g==", "a.b-c_d~e+f/g==" },
        .{ "Bearer x", "x" },
    };
    for (read) |case| try testing.expectEqualStrings(case[1], interceptor.bearer_token(case[0]).?);
    const refused = [_][]const u8{ "", "B", "Bearer", "Bearer ", "Bearer    ", "Bearerabc", "Bearer\tabc", "Basic abc", "Bearex abc", " Bearer abc", "Bearer a b", "Bearer abc ", "abc" };
    for (refused) |value| try testing.expectEqual(@as(?[]const u8, null), interceptor.bearer_token(value));
}
