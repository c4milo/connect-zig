//! The verifier's tests: tokens of each algorithm, the RFCs' known answers, and each refusal.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const verifier_file = @import("verifier.zig");
const Verifier = verifier_file.Verifier;
const Error = verifier_file.Error;
const support = @import("test_support.zig");
const Fixture = support.Fixture;
const rfc = @import("rfc_vectors.zig");
const rsa = @import("rsa_vectors.zig");

const kinds = [_]support.Kind{ .es256, .eddsa };
/// A letter of the signature that holds six of its bits: the last one holds fewer.
const signature_letter_from_end = 2;

test "a token the issuer signed verifies in ES256 and EdDSA, and gives its claims" {
    for (kinds) |kind| {
        var fixture: Fixture = undefined;
        try fixture.init(kind);
        try testing.expectEqual(@as(?*const verifier_file.Claims, null), fixture.verifier.claims());
        const claims = try fixture.check(support.good_claims);
        try testing.expectEqualStrings("user-1", claims.subject);
        try testing.expectEqualStrings(support.issuer, claims.issuer);
        try testing.expectEqual(support.good_expires, claims.expires_unix_seconds);
        try testing.expectEqualStrings(support.good_claims, claims.payload);
        try testing.expectEqual(claims, fixture.verifier.claims().?);
        try testing.expect(!fixture.verifier.keys_stale());
    }
}

fn rsa_verifier(verifier: *Verifier, modulus: []const u8, id: []const u8) !void {
    try verifier.init(&.{ .issuer = rsa.issuer, .audience = rsa.audience });
    var buffer: [support.text_bytes]u8 = undefined;
    const jwks = try std.fmt.bufPrint(&buffer, "{{\"keys\":[{{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"kid\":\"{s}\",\"n\":\"{s}\",\"e\":\"{s}\"}}]}}", .{ id, modulus, rsa.exponent });
    try verifier.set_keys(jwks);
    verifier.set_time(support.now);
}

test "an RS256 token verifies under a key of 2048 bits and one of 4096 bits" {
    const vectors = [_]struct { []const u8, []const u8, []const u8 }{
        .{ rsa.rsa_2048_modulus, rsa.rsa_2048_token, "rsa-2048" },
        .{ rsa.rsa_4096_modulus, rsa.rsa_4096_token, "rsa-4096" },
    };
    for (vectors) |vector| {
        var verifier: Verifier = undefined;
        try rsa_verifier(&verifier, vector[0], vector[2]);
        const claims = try verifier.verify(vector[1]);
        try testing.expectEqualStrings(rsa.subject, claims.subject);
        try testing.expectEqual(@as(i64, rsa.expires_unix_seconds), claims.expires_unix_seconds);
        // One octet of the signed text changed: the signature no longer verifies.
        var changed: [constants.token_bytes_max]u8 = undefined;
        @memcpy(changed[0..vector[1].len], vector[1]);
        const payload_start = std.mem.indexOfScalar(u8, vector[1], '.').? + 1;
        changed[payload_start + 2] ^= 1;
        try testing.expectError(error.InvalidSignature, verifier.verify(changed[0..vector[1].len]));
        try testing.expectEqual(@as(?*const verifier_file.Claims, null), verifier.claims());
    }
}

test "a verifier keeps no RSA key under 2048 bits" {
    // RFC 7518 §3.3. The token's signature is true under the key, and the key is not kept.
    var verifier: Verifier = undefined;
    try testing.expectError(error.NoKeys, rsa_verifier(&verifier, rsa.rsa_1024_modulus, "rsa-1024"));
    verifier.set_time(support.now);
    try testing.expectError(error.UnknownKey, verifier.verify(rsa.rsa_1024_token));
}

/// The RFC's token passes its signature, and then fails on a claim: the RFC's claims name no
/// audience. With one character of the signature changed, the signature fails first.
fn expect_known_answer(jwk: []const u8, token: []const u8, after_signature: Error) !void {
    var verifier: Verifier = undefined;
    try verifier.init(&.{ .issuer = rfc.issuer, .audience = "any" });
    var buffer: [support.text_bytes]u8 = undefined;
    try verifier.set_keys(try std.fmt.bufPrint(&buffer, "{{\"keys\":[{s}]}}", .{jwk}));
    verifier.set_time(rfc.expires_unix_seconds - 1);
    try testing.expectError(after_signature, verifier.verify(token));

    var changed: [constants.token_bytes_max]u8 = undefined;
    @memcpy(changed[0..token.len], token);
    const last = token.len - signature_letter_from_end;
    changed[last] = if (changed[last] == 'A') 'B' else 'A';
    try testing.expectError(error.InvalidSignature, verifier.verify(changed[0..token.len]));
}

test "the RFCs' tokens verify under the RFCs' keys" {
    // RFC 7515 appendix A.2 and A.3, and RFC 8037 appendix A.4, whose payload is no JSON.
    try expect_known_answer("{\"kty\":\"RSA\",\"n\":\"" ++ rfc.rs256_modulus ++ "\",\"e\":\"" ++ rfc.rs256_exponent ++ "\"}", rfc.rs256_token, error.WrongAudience);
    try expect_known_answer("{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ rfc.es256_x ++ "\",\"y\":\"" ++ rfc.es256_y ++ "\"}", rfc.es256_token, error.WrongAudience);
    try expect_known_answer("{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"" ++ rfc.eddsa_x ++ "\"}", rfc.eddsa_token, error.Malformed);
}

test "the RFC's claims pass the issuer and the time, and fail each alone" {
    const jwk = "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ rfc.es256_x ++ "\",\"y\":\"" ++ rfc.es256_y ++ "\"}]}";
    var verifier: Verifier = undefined;
    try verifier.init(&.{ .issuer = "jo", .audience = "any" });
    try verifier.set_keys(jwk);
    verifier.set_time(rfc.expires_unix_seconds - 1);
    try testing.expectError(error.WrongIssuer, verifier.verify(rfc.es256_token));
}

test "a token changed after its signature is refused" {
    for (kinds) |kind| {
        var fixture: Fixture = undefined;
        try fixture.init(kind);
        var room: [constants.token_bytes_max]u8 = undefined;
        const token = fixture.token(support.good_claims);
        const first = std.mem.indexOfScalar(u8, token, '.').?;
        const second = std.mem.lastIndexOfScalar(u8, token, '.').?;
        // A letter of the payload or of the signature changed: the signature fails.
        for ([_]usize{ first + 1, second - 1, second + 1, token.len - 2 }) |at| {
            @memcpy(room[0..token.len], token);
            room[at] = if (room[at] == 'A') 'B' else 'A';
            try testing.expectError(error.InvalidSignature, fixture.verifier.verify(room[0..token.len]));
            try testing.expectEqual(@as(?*const verifier_file.Claims, null), fixture.verifier.claims());
        }
        // A letter of the header changed: the header is refused, or the signature fails.
        for ([_]usize{ 0, first - 1 }) |at| {
            @memcpy(room[0..token.len], token);
            room[at] = if (room[at] == 'A') 'B' else 'A';
            try testing.expect(std.meta.isError(fixture.verifier.verify(room[0..token.len])));
        }
        // The payload of another token under this token's signature.
        var other_buffer: [support.text_bytes]u8 = undefined;
        var other: support.Text = .{ .buffer = &other_buffer };
        other.raw(token[0 .. first + 1]);
        other.base64url("{\"iss\":\"" ++ support.issuer ++ "\",\"sub\":\"admin\",\"aud\":\"" ++ support.audience ++ "\",\"exp\":1700003600}");
        other.raw(token[second..]);
        try testing.expectError(error.InvalidSignature, fixture.verifier.verify(other.written()));
        // A signature of 63 octets, and none.
        try testing.expectError(error.InvalidSignature, fixture.verifier.verify(token[0 .. token.len - 2]));
        try testing.expectError(error.InvalidSignature, fixture.verifier.verify(token[0 .. second + 1]));
    }
}

test "a token signed by another key under the same identifier is refused" {
    for (kinds) |kind| {
        var fixture: Fixture = undefined;
        try fixture.init(kind);
        const stranger = support.Signer.init(kind, 2);
        var header_buffer: [128]u8 = undefined;
        var text: support.Text = .{ .buffer = &fixture.buffer };
        const token = support.mint(&text, &stranger, fixture.header(&header_buffer), support.good_claims);
        try testing.expectError(error.InvalidSignature, fixture.verifier.verify(token));
    }
}

test "the header's algorithm is one the verifier takes, and the key's own" {
    var fixture: Fixture = undefined;
    try fixture.init(.es256);
    // RFC 8725 §3.2: "none", and an HMAC under the public key, are refused by name.
    const refused = [_][]const u8{ "none", "HS256", "RS384", "PS256", "ES384", "es256" };
    for (refused) |name| {
        var header: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&header, "{{\"alg\":\"{s}\",\"kid\":\"{s}\"}}", .{ name, support.key_id });
        try testing.expectError(error.UnsupportedAlgorithm, fixture.verifier.verify(fixture.token_with(text, support.good_claims)));
    }
    // RFC 8725 §3.1: the key signs with ES256 alone, so a header that names another algorithm
    // the verifier takes finds no key.
    for ([_][]const u8{ "EdDSA", "RS256" }) |name| {
        var header: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&header, "{{\"alg\":\"{s}\",\"kid\":\"{s}\"}}", .{ name, support.key_id });
        try testing.expectError(error.UnknownKey, fixture.verifier.verify(fixture.token_with(text, support.good_claims)));
    }
}

test "a verifier takes the algorithms its options state, and no other" {
    for (kinds) |kind| {
        var fixture: Fixture = undefined;
        // The key's algorithm is off: the verifier keeps no key.
        const off: verifier_file.VerifierOptions.Algorithms = .{ .es256 = kind != .es256, .eddsa = kind != .eddsa };
        try testing.expectError(error.NoKeys, fixture.init_with(kind, &.{ .issuer = support.issuer, .audience = support.audience, .algorithms = off }));
        fixture.verifier.set_time(support.now);
        try testing.expectError(error.UnsupportedAlgorithm, fixture.check(support.good_claims));
        // The key's algorithm alone is on.
        const on: verifier_file.VerifierOptions.Algorithms = .{ .rs256 = false, .es256 = kind == .es256, .eddsa = kind == .eddsa };
        try fixture.init_with(kind, &.{ .issuer = support.issuer, .audience = support.audience, .algorithms = on });
        _ = try fixture.check(support.good_claims);
    }
}

test "the header's key identifier names the key" {
    var fixture: Fixture = undefined;
    try fixture.init(.eddsa);
    try testing.expect(!fixture.verifier.keys_stale());
    // A key the verifier does not hold: the issuer changed its keys.
    try testing.expectError(error.UnknownKey, fixture.verifier.verify(fixture.token_with("{\"alg\":\"EdDSA\",\"kid\":\"key-2\"}", support.good_claims)));
    try testing.expect(fixture.verifier.keys_stale());
    // The same keys again clear the mark.
    var jwks_buffer: [support.text_bytes]u8 = undefined;
    var jwks: support.Text = .{ .buffer = &jwks_buffer };
    jwks.raw("{\"keys\":[");
    fixture.signer.jwk(&jwks, support.key_id, "");
    jwks.raw("]}");
    try fixture.verifier.set_keys(jwks.written());
    try testing.expect(!fixture.verifier.keys_stale());
    // An identifier that is a prefix of the key's, one it is a prefix of, and one too long.
    const names = [_][]const u8{ "key-", "key-11", "k" ** (constants.key_id_bytes_max + 1) };
    for (names) |name| {
        var header: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&header, "{{\"alg\":\"EdDSA\",\"kid\":\"{s}\"}}", .{name});
        try testing.expectError(error.UnknownKey, fixture.verifier.verify(fixture.token_with(text, support.good_claims)));
    }
    // With no identifier, the algorithm names the key while the set holds one key of it.
    _ = try fixture.verifier.verify(fixture.token_with("{\"alg\":\"EdDSA\"}", support.good_claims));
}

test "a token with no key identifier names no key among two of its algorithm" {
    var fixture: Fixture = undefined;
    try fixture.init(.es256);
    const second = support.Signer.init(.es256, 2);
    const other_kind = support.Signer.init(.eddsa, 3);
    var jwks_buffer: [support.text_bytes]u8 = undefined;
    var jwks: support.Text = .{ .buffer = &jwks_buffer };
    jwks.raw("{\"keys\":[");
    other_kind.jwk(&jwks, "key-3", "");
    jwks.raw(",");
    fixture.signer.jwk(&jwks, support.key_id, "");
    jwks.raw("]}");
    // One ES256 key beside a key of another algorithm: the header's algorithm names it.
    try fixture.verifier.set_keys(jwks.written());
    _ = try fixture.verifier.verify(fixture.token_with("{\"alg\":\"ES256\"}", support.good_claims));
    jwks.len -= 2;
    jwks.raw(",");
    second.jwk(&jwks, "key-2", "");
    jwks.raw("]}");
    try fixture.verifier.set_keys(jwks.written());
    try testing.expectError(error.UnknownKey, fixture.verifier.verify(fixture.token_with("{\"alg\":\"ES256\"}", support.good_claims)));
    // Each key still verifies its own token by name.
    _ = try fixture.check(support.good_claims);
    var text: support.Text = .{ .buffer = &fixture.buffer };
    _ = try fixture.verifier.verify(support.mint(&text, &second, "{\"alg\":\"ES256\",\"kid\":\"key-2\"}", support.good_claims));
}

test "a text that is no JWT is malformed" {
    var fixture: Fixture = undefined;
    try fixture.init(.es256);
    const token = fixture.token(support.good_claims);
    const first = std.mem.indexOfScalar(u8, token, '.').?;
    const second = std.mem.lastIndexOfScalar(u8, token, '.').?;
    var room: [support.text_bytes]u8 = undefined;
    // RFC 7515 §7.1: three parts.
    for ([_][]const u8{ "", ".", "..", "a.b", token[0..second], "a.b.c.d.e" }) |text| try testing.expectError(error.Malformed, fixture.verifier.verify(text));
    try testing.expectError(error.Malformed, fixture.verifier.verify(try std.fmt.bufPrint(&room, "{s}.x", .{token})));
    // RFC 7515 §2: base64url with no padding, and no other character, in the header and in the
    // signature. In the payload the signature fails first: no claim is read before it passed.
    for ([_]u8{ '=', '+', '/', ' ', '\n' }) |octet| {
        for ([_]usize{ first - 1, token.len - 1 }) |at| {
            @memcpy(room[0..token.len], token);
            room[at] = octet;
            try testing.expectError(error.Malformed, fixture.verifier.verify(room[0..token.len]));
        }
        @memcpy(room[0..token.len], token);
        room[second - 1] = octet;
        try testing.expectError(error.InvalidSignature, fixture.verifier.verify(room[0..token.len]));
    }
    try testing.expectError(error.Malformed, fixture.verifier.verify(try std.fmt.bufPrint(&room, "{s}=", .{token})));
    try testing.expectError(error.Malformed, fixture.verifier.verify(try std.fmt.bufPrint(&room, "{s}=.{s}", .{ token[0..first], token[first + 1 ..] })));
    // A payload that is not base64url, under a true signature: "e30" is "{}", and each text
    // here is refused where RFC 4648 §3.5 and §5 refuse it.
    var header_part: [128]u8 = undefined;
    @memcpy(header_part[0..first], token[0..first]);
    for ([_][]const u8{ "e30=", "e3 0", "e30+", "e31", "e" }) |payload| {
        var text: support.Text = .{ .buffer = &fixture.buffer };
        try testing.expectError(error.Malformed, fixture.verifier.verify(support.mint_parts(&text, &fixture.signer, header_part[0..first], payload)));
    }
    // A header that is not the JSON RFC 7515 §4 requires.
    for ([_][]const u8{ "", "[]", "{\"alg\":\"ES256\"", "{\"alg\":\"ES256\",\"crit\":[\"exp\"],\"kid\":\"key-1\"}", "{\"kid\":\"key-1\"}" }) |header| {
        try testing.expectError(error.Malformed, fixture.verifier.verify(fixture.token_with(header, support.good_claims)));
    }
}

test "a token's length is bounded" {
    var fixture: Fixture = undefined;
    try fixture.init(.eddsa);
    // A header of 30 octets: with it, a payload of a whole count of base64url groups makes a
    // token of exactly `token_bytes_max` characters.
    const header = "{\"alg\":\"EdDSA\",\"kid\":\"key-1\" }";
    var payload_buffer: [support.text_bytes]u8 = undefined;
    var longest: usize = 0;
    var past: usize = 0;
    for (2800..3000) |padding| {
        const payload = try std.fmt.bufPrint(&payload_buffer, "{{\"iss\":\"{s}\",\"aud\":\"{s}\",\"exp\":1700003600,\"p\":\"{s}\"}}", .{ support.issuer, support.audience, ("p" ** 3000)[0..padding] });
        const token = fixture.token_with(header, payload);
        if (token.len == constants.token_bytes_max) {
            const claims = try fixture.verifier.verify(token);
            try testing.expectEqualStrings(payload, claims.payload);
            longest = padding;
        }
        if (token.len > constants.token_bytes_max) {
            try testing.expectError(error.TokenTooLong, fixture.verifier.verify(token));
            past += 1;
        }
    }
    try testing.expect(longest != 0);
    try testing.expect(past != 0);
}

test "init copies its options, and refuses those out of range" {
    var issuer_buffer: [constants.issuer_bytes_max + 1]u8 = @splat('i');
    var verifier: Verifier = undefined;
    try testing.expectError(error.IssuerInvalid, verifier.init(&.{ .issuer = "", .audience = "a" }));
    try testing.expectError(error.IssuerInvalid, verifier.init(&.{ .issuer = &issuer_buffer, .audience = "a" }));
    try testing.expectError(error.AudienceInvalid, verifier.init(&.{ .issuer = "i", .audience = "" }));
    try testing.expectError(error.AudienceInvalid, verifier.init(&.{ .issuer = "i", .audience = &issuer_buffer }));
    try testing.expectError(error.LeewayTooLong, verifier.init(&.{ .issuer = "i", .audience = "a", .leeway_s = constants.leeway_s_max + 1 }));
    try testing.expectError(error.NoAlgorithm, verifier.init(&.{ .issuer = "i", .audience = "a", .algorithms = .{ .rs256 = false, .es256 = false, .eddsa = false } }));
    for ([_]verifier_file.VerifierOptions.Algorithms{
        .{ .rs256 = true, .es256 = false, .eddsa = false },
        .{ .rs256 = false, .es256 = true, .eddsa = false },
        .{ .rs256 = false, .es256 = false, .eddsa = true },
    }) |one| try verifier.init(&.{ .issuer = "i", .audience = "a", .algorithms = one });
    try verifier.init(&.{ .issuer = issuer_buffer[0..constants.issuer_bytes_max], .audience = issuer_buffer[0..constants.audience_bytes_max], .leeway_s = constants.leeway_s_max });
    try testing.expect(verifier.keys_stale());
    verifier.deinit();

    // The verifier keeps no pointer to the options: the caller's octets change after `init`.
    var fixture: Fixture = undefined;
    var issuer_copy: [support.issuer.len]u8 = support.issuer.*;
    var audience_copy: [support.audience.len]u8 = support.audience.*;
    try fixture.init_with(.es256, &.{ .issuer = &issuer_copy, .audience = &audience_copy });
    @memset(&issuer_copy, 'x');
    @memset(&audience_copy, 'x');
    const claims = try fixture.check(support.good_claims);
    try testing.expectEqualStrings(support.issuer, claims.issuer);
}

test "set_keys replaces the keys, and keeps the old ones after an error" {
    var fixture: Fixture = undefined;
    try fixture.init(.es256);
    const second = support.Signer.init(.eddsa, 2);
    var jwks_buffer: [support.text_bytes]u8 = undefined;
    var jwks: support.Text = .{ .buffer = &jwks_buffer };
    const refused = [_]struct { []const u8, Verifier.KeysError }{
        .{ "", error.Malformed },
        .{ "[]", error.Malformed },
        .{ "{}", error.Malformed },
        .{ "{\"keys\":{}}", error.Malformed },
        .{ "{\"keys\":[1]}", error.Malformed },
        .{ "{\"keys\":[]", error.Malformed },
        .{ "{\"keys\":[],\"keys\":[]}", error.Malformed },
        .{ "{\"keys\":[]}", error.NoKeys },
        .{ "{\"keys\":[{\"kty\":\"oct\",\"k\":\"AA\"}]}", error.NoKeys },
    };
    for (refused) |each| {
        try testing.expectError(each[1], fixture.verifier.set_keys(each[0]));
        _ = try fixture.check(support.good_claims);
    }
    // More keys than the verifier holds, after as many as it holds.
    for ([_]usize{ constants.keys_max, constants.keys_max + 1 }) |count| {
        jwks.len = 0;
        jwks.raw("{\"other\":[1,{\"keys\":2}],\"keys\":[");
        for (0..count) |index| {
            if (index != 0) jwks.raw(",");
            var id: [8]u8 = undefined;
            second.jwk(&jwks, try std.fmt.bufPrint(&id, "k{d}", .{index}), "");
        }
        jwks.raw("]}");
        var text: support.Text = .{ .buffer = &fixture.buffer };
        const last = support.mint(&text, &second, "{\"alg\":\"EdDSA\",\"kid\":\"k7\"}", support.good_claims);
        if (count > constants.keys_max) {
            try testing.expectError(error.TooManyKeys, fixture.verifier.set_keys(jwks.written()));
            _ = try fixture.verifier.verify(last);
        } else {
            try fixture.verifier.set_keys(jwks.written());
            _ = try fixture.verifier.verify(last);
            // The key the verifier held before is gone.
            try testing.expectError(error.UnknownKey, fixture.check(support.good_claims));
        }
    }
}

test "the claims stay valid until the next verify, across set_keys" {
    var fixture: Fixture = undefined;
    try fixture.init(.es256);
    const claims = try fixture.check(support.good_claims);
    var jwks_buffer: [support.text_bytes]u8 = undefined;
    var jwks: support.Text = .{ .buffer = &jwks_buffer };
    jwks.raw("{\"keys\":[");
    support.Signer.init(.eddsa, 2).jwk(&jwks, "key-2", ",\"x5c\":[\"" ++ "M" ** (2 * constants.decoded_bytes_max) ++ "\"]");
    jwks.raw("]}");
    try fixture.verifier.set_keys(jwks.written());
    try testing.expectEqualStrings("user-1", claims.subject);
    try testing.expectEqualStrings(support.good_claims, claims.payload);
    try testing.expectEqual(claims, fixture.verifier.claims().?);
    // A refused token ends them.
    try testing.expectError(error.UnknownKey, fixture.check(support.good_claims));
    try testing.expectEqual(@as(?*const verifier_file.Claims, null), fixture.verifier.claims());
}
