//! The lookups of a program's own claims: `Claims.string`, `integer` and `holds`, over the
//! payload `verify` kept.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const Claims = @import("claims.zig").Claims;
const support = @import("test_support.zig");

/// Claims whose payload is `text`, which the test writes as `verify` would keep it.
fn fill(claims: *Claims, text: []const u8) void {
    claims.* = .{};
    @memcpy(claims.payload_storage[0..text.len], text);
    claims.payload_len = text.len;
}

test "string reads a claim's string, with its escapes, and the last of two" {
    var claims: Claims = undefined;
    fill(&claims, "{\"email\":\"a@example.com\",\"pic\":\"https:\\/\\/x\\u00e9\",\"n\\u0061me\":\"Ann\",\"twice\":\"first\",\"twice\":\"last\"}");
    try testing.expectEqualStrings("a@example.com", (try claims.string("email")).?);
    try testing.expectEqualStrings("https://x\u{e9}", (try claims.string("pic")).?);
    // A name is compared after its escapes, as JSON reads it (RFC 8259 §7).
    try testing.expectEqualStrings("Ann", (try claims.string("name")).?);
    // RFC 7519 §4: the lexically last member of a name that appears twice.
    try testing.expectEqualStrings("last", (try claims.string("twice")).?);
    for ([_][]const u8{ "absent", "Email", "emai", "email ", "" }) |name| try testing.expectEqual(@as(?[]const u8, null), try claims.string(name));
}

test "string reads the members of the claims set alone, not those nested in a value" {
    var claims: Claims = undefined;
    fill(&claims, "{\"address\":{\"email\":\"nested@example.com\"},\"list\":[{\"email\":\"x\"}],\"note\":\"email\"}");
    try testing.expectEqual(@as(?[]const u8, null), try claims.string("email"));
}

test "string refuses a value of another type, and one longer than its storage" {
    var claims: Claims = undefined;
    fill(&claims, "{\"n\":7,\"t\":true,\"z\":null,\"a\":[\"x\"],\"o\":{\"x\":\"y\"}}");
    for ([_][]const u8{ "n", "t", "z", "a", "o" }) |name| try testing.expectError(error.WrongType, claims.string(name));

    const longest = "s" ** constants.claim_bytes_max;
    fill(&claims, "{\"long\":\"" ++ longest ++ "\",\"longer\":\"" ++ longest ++ "s\"}");
    try testing.expectEqualStrings(longest, (try claims.string("long")).?);
    try testing.expectError(error.ClaimTooLong, claims.string("longer"));
}

test "integer reads a claim's whole number, and refuses another number" {
    var claims: Claims = undefined;
    fill(&claims, "{\"auth_time\":1700000000,\"zero\":0,\"below\":-42,\"max\":9223372036854775807,\"past\":9223372036854775808," ++
        "\"fraction\":1.5,\"whole_fraction\":1.0,\"exponent\":1e3,\"text\":\"5\",\"flag\":false}");
    try testing.expectEqual(@as(?i64, 1_700_000_000), try claims.integer("auth_time"));
    try testing.expectEqual(@as(?i64, 0), try claims.integer("zero"));
    try testing.expectEqual(@as(?i64, -42), try claims.integer("below"));
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), try claims.integer("max"));
    try testing.expectEqual(@as(?i64, null), try claims.integer("absent"));
    for ([_][]const u8{ "past", "fraction", "whole_fraction", "exponent", "text", "flag" }) |name| {
        try testing.expectError(error.WrongType, claims.integer(name));
    }
}

test "holds finds a string equal to the value, alone or in an array" {
    var claims: Claims = undefined;
    fill(&claims, "{\"role\":\"admin\",\"roles\":[\"reader\",7,null,[\"admin\"],{\"admin\":1},\"admin\"],\"groups\":[\"reader\"],\"none\":[]," ++
        "\"n\":7,\"o\":{\"roles\":\"admin\"},\"twice\":[\"admin\"],\"twice\":[\"reader\"]}");
    try testing.expect(try claims.holds("role", "admin"));
    try testing.expect(!try claims.holds("role", "admi"));
    try testing.expect(!try claims.holds("role", "admin2"));
    // An array's other values, a nested array and an object among them, pass unread.
    try testing.expect(try claims.holds("roles", "admin"));
    try testing.expect(try claims.holds("roles", "reader"));
    try testing.expect(!try claims.holds("roles", "7"));
    try testing.expect(!try claims.holds("groups", "admin"));
    try testing.expect(!try claims.holds("none", "admin"));
    try testing.expect(!try claims.holds("absent", "admin"));
    try testing.expectError(error.WrongType, claims.holds("n", "7"));
    try testing.expectError(error.WrongType, claims.holds("o", "admin"));
    // RFC 7519 §4: the last member of a name that appears twice.
    try testing.expect(!try claims.holds("twice", "admin"));
    try testing.expect(try claims.holds("twice", "reader"));
}

test "holds reads an array's own strings, not those nested in its values" {
    var claims: Claims = undefined;
    fill(&claims, "{\"nested\":[[\"admin\"],{\"admin\":\"admin\"}],\"after\":[[\"x\"],\"admin\"]}");
    try testing.expect(!try claims.holds("nested", "admin"));
    try testing.expect(try claims.holds("after", "admin"));
    try testing.expect(!try claims.holds("after", "x"));
}

test "holds compares a string longer than its storage with no value" {
    var claims: Claims = undefined;
    const longer = "a" ** (constants.claim_bytes_max + 1);
    fill(&claims, "{\"role\":\"" ++ longer ++ "\",\"roles\":[\"" ++ longer ++ "\",\"admin\"]}");
    try testing.expect(!try claims.holds("role", "admin"));
    try testing.expect(try claims.holds("roles", "admin"));
}

test "claims that no verify filled hold no claim" {
    var claims: Claims = .{};
    try testing.expectEqual(@as(?[]const u8, null), try claims.string("sub"));
    try testing.expectEqual(@as(?i64, null), try claims.integer("exp"));
    try testing.expect(!try claims.holds("roles", "admin"));
    try testing.expectEqualStrings("", claims.subject());
    try testing.expectEqualStrings("", claims.payload());
}

test "a verified token's own claims read through the lookups" {
    var fixture: support.Fixture = undefined;
    try fixture.init(.eddsa);
    const payload = "{\"iss\":\"" ++ support.issuer ++ "\",\"aud\":\"" ++ support.audience ++ "\",\"exp\":1700003600," ++
        "\"sub\":\"user-1\",\"email\":\"user@example.com\",\"roles\":[\"admin\"],\"auth_time\":1699999000}";
    const claims = try fixture.check(payload);
    try testing.expectEqualStrings("user@example.com", (try claims.string("email")).?);
    try testing.expect(try claims.holds("roles", "admin"));
    try testing.expectEqual(@as(?i64, 1_699_999_000), try claims.integer("auth_time"));
    // The claims verify reads are members too.
    try testing.expectEqualStrings("user-1", (try claims.string("sub")).?);
    try testing.expectEqual(@as(?i64, 1_700_003_600), try claims.integer("exp"));
    try testing.expect(try claims.holds("aud", support.audience));
}
