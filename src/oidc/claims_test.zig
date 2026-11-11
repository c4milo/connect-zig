//! The claim checks, through the verifier: the issuer, the audience and the times (RFC 7519
//! §4.1), and the claims a token must hold.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const claims_file = @import("claims.zig");
const verifier_file = @import("verifier.zig");
const support = @import("test_support.zig");
const Fixture = support.Fixture;

const payload_bytes = 256;
const head = "{\"iss\":\"" ++ support.issuer ++ "\",\"aud\":\"" ++ support.audience ++ "\"";

test "the issuer equals the verifier's, octet for octet" {
    var fixture: Fixture = undefined;
    try fixture.init(.es256);
    const tail = ",\"aud\":\"" ++ support.audience ++ "\",\"exp\":1700003600}";
    // OpenID Connect Core 1.0 §3.1.3.7 rule 2: an exact match. No case folding, no trailing
    // slash, no prefix.
    const others = [_][]const u8{ "https://issuer.example/", "https://issuer.exampl", "https://Issuer.example", "https://issuer.example.evil", "" };
    for (others) |other| {
        var payload: [256]u8 = undefined;
        try testing.expectError(error.WrongIssuer, fixture.check(try std.fmt.bufPrint(&payload, "{{\"iss\":\"{s}\"{s}", .{ other, tail })));
    }
    // A token that names no issuer.
    try testing.expectError(error.WrongIssuer, fixture.check("{\"aud\":\"" ++ support.audience ++ "\",\"exp\":1700003600}"));
    // An escape is the same octets: JSON text, not its spelling, is compared.
    _ = try fixture.check("{\"iss\":\"https:\\/\\/issuer.example\"" ++ tail);
    // RFC 7519 §4.1.1: a string.
    for ([_][]const u8{ "7", "null", "[\"" ++ support.issuer ++ "\"]" }) |value| {
        var payload: [256]u8 = undefined;
        try testing.expectError(error.Malformed, fixture.check(try std.fmt.bufPrint(&payload, "{{\"iss\":{s}{s}", .{ value, tail })));
    }
}

test "the audience is the verifier's, alone or among others" {
    var fixture: Fixture = undefined;
    try fixture.init(.eddsa);
    const start = "{\"iss\":\"" ++ support.issuer ++ "\",\"exp\":1700003600";
    // RFC 7519 §4.1.3: one string, or an array of strings.
    const taken = [_][]const u8{ "\"service\"", "[\"service\"]", "[\"other\",\"service\"]", "[\"service\",\"other\"]", "[\"a\",\"b\",\"service\",\"c\"]" };
    for (taken) |value| {
        var payload: [256]u8 = undefined;
        _ = try fixture.check(try std.fmt.bufPrint(&payload, "{s},\"aud\":{s}}}", .{ start, value }));
    }
    const refused = [_][]const u8{ "\"other\"", "\"servic\"", "\"service2\"", "\"Service\"", "\"\"", "[]", "[\"other\"]", "[\"servic\",\"service2\"]" };
    for (refused) |value| {
        var payload: [256]u8 = undefined;
        try testing.expectError(error.WrongAudience, fixture.check(try std.fmt.bufPrint(&payload, "{s},\"aud\":{s}}}", .{ start, value })));
    }
    // A token that names no audience is for no one.
    try testing.expectError(error.WrongAudience, fixture.check(start ++ "}"));
    for ([_][]const u8{ "7", "null", "{\"service\":1}", "[\"service\",7]", "[7,\"service\"]", "[[\"service\"]]" }) |value| {
        var payload: [256]u8 = undefined;
        try testing.expectError(error.Malformed, fixture.check(try std.fmt.bufPrint(&payload, "{s},\"aud\":{s}}}", .{ start, value })));
    }
}

fn expect_at(fixture: *Fixture, comptime leeway_s: u32, claims: []const u8, at: i64, expected: ?verifier_file.Error) !void {
    try fixture.init_with(.eddsa, &.{ .issuer = support.issuer, .audience = support.audience, .leeway_s = leeway_s });
    fixture.verifier.set_time(at);
    var payload: [payload_bytes]u8 = undefined;
    const outcome = fixture.check(try std.fmt.bufPrint(&payload, "{s},{s}}}", .{ head, claims }));
    if (expected) |failure| try testing.expectError(failure, outcome) else _ = try outcome;
}

test "a token ends at its expiration time, and the leeway moves the end" {
    var fixture: Fixture = undefined;
    // RFC 7519 §4.1.4: the current time MUST be before "exp".
    try expect_at(&fixture, 0, "\"exp\":1700000100", 1_700_000_099, null);
    try expect_at(&fixture, 0, "\"exp\":1700000100", 1_700_000_100, error.Expired);
    try expect_at(&fixture, 0, "\"exp\":1700000100", 1_700_000_101, error.Expired);
    try expect_at(&fixture, 60, "\"exp\":1700000100", 1_700_000_159, null);
    try expect_at(&fixture, 60, "\"exp\":1700000100", 1_700_000_160, error.Expired);
    // RFC 7519 §2: a NumericDate may hold a part of a second. At the whole second the time is
    // still before it.
    try expect_at(&fixture, 0, "\"exp\":1700000100.5", 1_700_000_100, null);
    try expect_at(&fixture, 0, "\"exp\":1700000100.5", 1_700_000_101, error.Expired);
    try expect_at(&fixture, 0, "\"exp\":1700000100.000", 1_700_000_100, error.Expired);
    // A clock that the program set before 1970, and one at the end of the range.
    try expect_at(&fixture, 60, "\"exp\":1700000100", -5, null);
    try expect_at(&fixture, 60, "\"exp\":1700000100", std.math.maxInt(i64), error.Expired);
    try expect_at(&fixture, 60, "\"exp\":1700000100,\"nbf\":5", std.math.minInt(i64), error.NotYetValid);
}

test "a token starts at its not-before time, and the leeway moves the start" {
    var fixture: Fixture = undefined;
    const exp = "\"exp\":1800000000,";
    // RFC 7519 §4.1.5: the current time MUST be after or equal to "nbf".
    try expect_at(&fixture, 0, exp ++ "\"nbf\":1700000100", 1_700_000_099, error.NotYetValid);
    try expect_at(&fixture, 0, exp ++ "\"nbf\":1700000100", 1_700_000_100, null);
    try expect_at(&fixture, 60, exp ++ "\"nbf\":1700000100", 1_700_000_039, error.NotYetValid);
    try expect_at(&fixture, 60, exp ++ "\"nbf\":1700000100", 1_700_000_040, null);
    try expect_at(&fixture, 0, exp ++ "\"nbf\":1700000100.25", 1_700_000_100, error.NotYetValid);
    try expect_at(&fixture, 0, exp ++ "\"nbf\":1700000100.25", 1_700_000_101, null);
    // A token past its end and before its start is expired: the end is checked first.
    try expect_at(&fixture, 0, "\"exp\":1700000100,\"nbf\":1700000200", 1_700_000_150, error.Expired);
}

test "a token holds an expiration time, and its claims are the JSON the RFC requires" {
    var fixture: Fixture = undefined;
    try fixture.init(.es256);
    const refused = [_][]const u8{
        // No "exp": a bearer token that never ends.
        head ++ "}",
        head ++ ",\"nbf\":1}",
        // RFC 7519 §4.1.4 and §4.1.5: numbers.
        head ++ ",\"exp\":\"1700003600\"}",
        head ++ ",\"exp\":null}",
        head ++ ",\"exp\":[1700003600]}",
        head ++ ",\"exp\":1700003600,\"nbf\":\"1\"}",
        // A date the verifier does not read: before 1970, with an exponent, too long.
        head ++ ",\"exp\":-1}",
        head ++ ",\"exp\":1.8e9}",
        head ++ ",\"exp\":18e8}",
        head ++ ",\"exp\":1800000000.5e0}",
        head ++ ",\"exp\":1800000000000}",
        // RFC 7519 §4: a claim appears once.
        head ++ ",\"exp\":1700003600,\"exp\":1900000000}",
        head ++ ",\"exp\":1700003600,\"sub\":\"a\",\"sub\":\"b\"}",
        head ++ ",\"exp\":1700003600,\"aud\":\"service\"}",
        head ++ ",\"exp\":1700003600,\"iss\":\"" ++ support.issuer ++ "\"}",
        head ++ ",\"exp\":1700003600,\"nbf\":1,\"nbf\":2}",
        // RFC 7519 §4.1.2: "sub" is a string, of 255 characters at most.
        head ++ ",\"exp\":1700003600,\"sub\":7}",
        head ++ ",\"exp\":1700003600,\"sub\":\"" ++ "s" ** (constants.subject_bytes_max + 1) ++ "\"}",
        // RFC 7519 §3: one JSON object.
        "[]",
        "\"claims\"",
        "",
        head ++ ",\"exp\":1700003600",
        head ++ ",\"exp\":1700003600}{}",
    };
    for (refused) |payload| try testing.expectError(error.Malformed, fixture.check(payload));

    const longest = try fixture.check(head ++ ",\"exp\":999999999999,\"sub\":\"" ++ "s" ** constants.subject_bytes_max ++ "\"}");
    try testing.expectEqualStrings("s" ** constants.subject_bytes_max, longest.subject());
    try testing.expectEqual(@as(i64, 999_999_999_999), longest.expires_unix_seconds);
    // A token that names no subject, and claims the verifier does not read.
    const bare = try fixture.check(head ++ ",\"exp\":1700003600,\"scope\":[\"a\",{\"exp\":1}],\"azp\":\"client\"}");
    try testing.expectEqualStrings("", bare.subject());
}

test "parse_numeric_date reads whole seconds and a fraction" {
    const cases = [_]struct { []const u8, i64, bool }{
        .{ "0", 0, false },
        .{ "7", 7, false },
        .{ "1700000000", 1_700_000_000, false },
        .{ "1700000000.0", 1_700_000_000, false },
        .{ "1700000000.001", 1_700_000_000, true },
        .{ "1700000000.50", 1_700_000_000, true },
        .{ "0.9", 0, true },
        .{ "999999999999", 999_999_999_999, false },
    };
    for (cases) |case| {
        const date = try claims_file.parse_numeric_date(case[0]);
        try testing.expectEqual(case[1], date.seconds);
        try testing.expectEqual(case[2], date.fraction);
        try testing.expectEqual(case[1] + @intFromBool(case[2]), date.ceiling());
    }
    for ([_][]const u8{ "-1", "-0", "1e3", "1E3", "1.5e3", "1000000000000", "" }) |text| try testing.expectError(error.Malformed, claims_file.parse_numeric_date(text));
}
