//! The JWK Set reader's tests: which keys a set keeps (RFC 7517, RFC 7518 §6, RFC 8037 §2), and
//! the key a header finds.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const jwks = @import("jwks.zig");
const token = @import("token.zig");
const support = @import("test_support.zig");
const rsa = @import("rsa_vectors.zig");

const all: token.Algorithms = .{};
/// The tokens' worth of room for a JWK Set with a certificate chain past the reader's storage.
const set_texts = 4;

const Sets = struct {
    set: jwks.KeySet = .{},
    scratch: [constants.decoded_bytes_max]u8 = undefined,
    buffer: [set_texts * support.text_bytes]u8 = undefined,

    /// The keys the set keeps from a JWK Set that holds `key` alone.
    fn count_of(sets: *Sets, key: []const u8) !usize {
        const text = try std.fmt.bufPrint(&sets.buffer, "{{\"keys\":[{s}]}}", .{key});
        try sets.set.read(text, &sets.scratch, all);
        return sets.set.count;
    }
};

/// base64url of `count` octets of `octet`, as text the compiler knows.
fn encoded(comptime octet: u8, comptime count: usize) *const [std.base64.url_safe_no_pad.Encoder.calcSize(count)]u8 {
    return comptime text: {
        const octets: [count]u8 = @splat(octet);
        var letters: [std.base64.url_safe_no_pad.Encoder.calcSize(count)]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&letters, &octets);
        const final = letters;
        break :text &final;
    };
}

const ec_x = encoded(1, constants.coordinate_bytes);
const ec = "\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ ec_x ++ "\"";
const okp = "\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"" ++ ec_x ++ "\"";
const rsa_key = "\"kty\":\"RSA\",\"e\":\"AQAB\",\"n\":\"" ++ rsa.rsa_2048_modulus ++ "\"";

test "a set keeps a key of each family, in the form chapulin takes" {
    var sets: Sets = .{};
    try testing.expectEqual(@as(usize, 1), try sets.count_of("{" ++ ec ++ "}"));
    try testing.expectEqual(token.Algorithm.es256, sets.set.keys[0].algorithm);
    try testing.expectEqualSlices(u8, &(@as([2 * constants.coordinate_bytes]u8, @splat(1))), sets.set.keys[0].bytes());
    try testing.expectEqual(@as(?[]const u8, null), sets.set.keys[0].key_id());

    try testing.expectEqual(@as(usize, 1), try sets.count_of("{" ++ okp ++ ",\"kid\":\"a\"}"));
    try testing.expectEqual(token.Algorithm.eddsa, sets.set.keys[0].algorithm);
    try testing.expectEqualSlices(u8, &(@as([constants.coordinate_bytes]u8, @splat(1))), sets.set.keys[0].bytes());
    try testing.expectEqualStrings("a", sets.set.keys[0].key_id().?);

    // RFC 3110 §2: the exponent's length, the exponent, then the modulus.
    try testing.expectEqual(@as(usize, 1), try sets.count_of("{" ++ rsa_key ++ "}"));
    const key = sets.set.keys[0].bytes();
    try testing.expectEqual(token.Algorithm.rs256, sets.set.keys[0].algorithm);
    try testing.expectEqual(@as(usize, 1 + 3 + constants.rsa_modulus_bytes_min), key.len);
    try testing.expectEqualSlices(u8, &.{ 3, 1, 0, 1 }, key[0..4]);
    var modulus: [constants.rsa_modulus_bytes_min]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&modulus, rsa.rsa_2048_modulus);
    try testing.expectEqualSlices(u8, &modulus, key[4..]);
}

test "a set keeps a key that verifies signatures, and no other" {
    var sets: Sets = .{};
    const kept = [_][]const u8{
        // RFC 7517 §4.2, §4.3 and §4.4: the members that say what a key is for.
        "{" ++ ec ++ ",\"use\":\"sig\",\"alg\":\"ES256\",\"key_ops\":[\"verify\"]}",
        "{" ++ ec ++ ",\"key_ops\":[\"sign\",\"verify\"]}",
        "{" ++ okp ++ ",\"alg\":\"EdDSA\"}",
        "{" ++ rsa_key ++ ",\"alg\":\"RS256\"}",
        // Members the verifier does not read, a certificate chain longer than its storage among
        // them (RFC 7517 §4.7).
        "{\"x5c\":[\"" ++ "M" ** (2 * constants.decoded_bytes_max) ++ "\"],\"x5t\":\"a\",\"ext\":true," ++ ec ++ ",\"" ++ "m" ** (2 * constants.decoded_bytes_max) ++ "\":{\"a\":[1]}}",
        // The longest key identifier.
        "{" ++ ec ++ ",\"kid\":\"" ++ "k" ** constants.key_id_bytes_max ++ "\"}",
    };
    for (kept) |key| try testing.expectEqual(@as(usize, 1), try sets.count_of(key));

    const passed_over = [_][]const u8{
        // RFC 7517 §4.1: a "kty", of a family the verifier reads.
        "{}",
        "{\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"oct\",\"k\":\"AAAA\"}",
        "{\"kty\":\"ec\",\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":7,\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ ec_x ++ "\"}",
        // RFC 7517 §4.2: a key for encryption.
        "{" ++ ec ++ ",\"use\":\"enc\"}",
        "{" ++ ec ++ ",\"use\":7}",
        // RFC 7517 §4.3: operations with no "verify".
        "{" ++ ec ++ ",\"key_ops\":[\"sign\"]}",
        "{" ++ ec ++ ",\"key_ops\":[]}",
        "{" ++ ec ++ ",\"key_ops\":\"verify\"}",
        "{" ++ ec ++ ",\"key_ops\":{\"verify\":true}}",
        "{" ++ ec ++ ",\"key_ops\":[[\"verify\"],{\"verify\":1},7,null]}",
        // RFC 7517 §4.4: a key for another algorithm.
        "{" ++ ec ++ ",\"alg\":\"ES384\"}",
        "{" ++ ec ++ ",\"alg\":\"EdDSA\"}",
        "{" ++ okp ++ ",\"alg\":\"ES256\"}",
        "{" ++ rsa_key ++ ",\"alg\":\"RS384\"}",
        "{" ++ rsa_key ++ ",\"alg\":\"PS256\"}",
        "{" ++ rsa_key ++ ",\"alg\":\"RSA-OAEP\"}",
        // A key identifier the verifier has no room for, so no token names the key.
        "{" ++ ec ++ ",\"kid\":\"" ++ "k" ** (constants.key_id_bytes_max + 1) ++ "\"}",
        "{" ++ ec ++ ",\"kid\":7}",
    };
    for (passed_over) |key| try testing.expectEqual(@as(usize, 0), try sets.count_of(key));
}

test "a set keeps an elliptic key on its curve's own lengths alone" {
    var sets: Sets = .{};
    const short = encoded(1, constants.coordinate_bytes - 1);
    const long = encoded(1, constants.coordinate_bytes + 1);
    const passed_over = [_][]const u8{
        // RFC 7518 §6.2.1.1: the curve, P-256 alone.
        "{\"kty\":\"EC\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"EC\",\"crv\":\"P-384\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"EC\",\"crv\":\"Ed25519\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ ec_x ++ "\"}",
        // RFC 7518 §6.2.1.2 and §6.2.1.3: each coordinate is the curve's full 32 octets.
        "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"EC\",\"crv\":\"P-256\",\"y\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ short ++ "\",\"y\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ short ++ "\"}",
        "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ long ++ "\",\"y\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ long ++ "\"}",
        // RFC 7518 §2: base64url with no padding.
        "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "=\",\"y\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "\",\"y\":\"" ++ "+" ** ec_x.len ++ "\"}",
        "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":7,\"y\":\"" ++ ec_x ++ "\"}",
        // RFC 8037 §2: the curve, Ed25519 alone, and its 32 octets.
        "{\"kty\":\"OKP\",\"x\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"OKP\",\"crv\":\"X25519\",\"x\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"OKP\",\"crv\":\"P-256\",\"x\":\"" ++ ec_x ++ "\"}",
        "{\"kty\":\"OKP\",\"crv\":\"Ed25519\"}",
        "{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"" ++ short ++ "\"}",
        "{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"" ++ long ++ "\"}",
    };
    for (passed_over) |key| try testing.expectEqual(@as(usize, 0), try sets.count_of(key));
}

test "a set keeps an RSA key of 2048 to 4096 bits, written in the least octets" {
    var sets: Sets = .{};
    const kept = [_][]const u8{
        "{\"kty\":\"RSA\",\"e\":\"AQAB\",\"n\":\"" ++ encoded(0x81, constants.rsa_modulus_bytes_min) ++ "\"}",
        "{\"kty\":\"RSA\",\"e\":\"AQAB\",\"n\":\"" ++ encoded(0x81, constants.rsa_modulus_bytes_max) ++ "\"}",
        "{\"kty\":\"RSA\",\"e\":\"Aw\",\"n\":\"" ++ rsa.rsa_4096_modulus ++ "\"}",
        "{\"kty\":\"RSA\",\"e\":\"" ++ encoded(1, constants.rsa_exponent_bytes_max) ++ "\",\"n\":\"" ++ rsa.rsa_2048_modulus ++ "\"}",
    };
    for (kept) |key| try testing.expectEqual(@as(usize, 1), try sets.count_of(key));
    // The longest key fills the key's storage.
    _ = try sets.count_of("{\"kty\":\"RSA\",\"e\":\"" ++ encoded(1, constants.rsa_exponent_bytes_max) ++ "\",\"n\":\"" ++ encoded(0x81, constants.rsa_modulus_bytes_max) ++ "\"}");
    try testing.expectEqual(@as(usize, constants.key_bytes_max), sets.set.keys[0].bytes().len);
    try testing.expectEqual(@as(u8, constants.rsa_exponent_bytes_max), sets.set.keys[0].bytes()[0]);

    const passed_over = [_][]const u8{
        // RFC 7518 §3.3: 2048 bits or more. chapulin's bound: 4096 bits at most.
        "{\"kty\":\"RSA\",\"e\":\"AQAB\",\"n\":\"" ++ rsa.rsa_1024_modulus ++ "\"}",
        "{\"kty\":\"RSA\",\"e\":\"AQAB\",\"n\":\"" ++ encoded(0x81, constants.rsa_modulus_bytes_min - 1) ++ "\"}",
        "{\"kty\":\"RSA\",\"e\":\"AQAB\",\"n\":\"" ++ encoded(0x81, constants.rsa_modulus_bytes_max + 1) ++ "\"}",
        // RFC 7518 §6.3.1: both "n" and "e".
        "{\"kty\":\"RSA\",\"e\":\"AQAB\"}",
        "{\"kty\":\"RSA\",\"n\":\"" ++ rsa.rsa_2048_modulus ++ "\"}",
        "{\"kty\":\"RSA\",\"e\":\"\",\"n\":\"" ++ rsa.rsa_2048_modulus ++ "\"}",
        "{\"kty\":\"RSA\",\"e\":\"" ++ encoded(1, constants.rsa_exponent_bytes_max + 1) ++ "\",\"n\":\"" ++ rsa.rsa_2048_modulus ++ "\"}",
        // RFC 7518 §2, Base64urlUInt: no leading zero octet.
        "{\"kty\":\"RSA\",\"e\":\"AQAB\",\"n\":\"" ++ encoded(0, constants.rsa_modulus_bytes_min) ++ "\"}",
        "{\"kty\":\"RSA\",\"e\":\"AAEAAQ\",\"n\":\"" ++ rsa.rsa_2048_modulus ++ "\"}",
        "{\"kty\":\"RSA\",\"e\":\"AQAB\",\"n\":[\"" ++ rsa.rsa_2048_modulus ++ "\"]}",
    };
    for (passed_over) |key| try testing.expectEqual(@as(usize, 0), try sets.count_of(key));
}

test "a set refuses a text that is no JWK Set" {
    var sets: Sets = .{};
    const refused = [_][]const u8{
        // RFC 7517 §4: a JWK is an object, and a member appears once.
        "7",
        "\"key\"",
        "[]",
        "{" ++ ec ++ ",\"kty\":\"EC\"}",
        "{" ++ ec ++ ",\"kid\":\"a\",\"kid\":\"b\"}",
        "{" ++ ec ++ ",\"key_ops\":[\"verify\"],\"key_ops\":[]}",
        "{" ++ ec,
    };
    for (refused) |key| {
        try testing.expectError(error.Malformed, sets.count_of(key));
        try testing.expectEqual(@as(usize, 0), sets.set.count);
    }
    // After a key it kept, an error leaves the set with no key.
    try testing.expectError(error.Malformed, sets.count_of("{" ++ ec ++ "},{" ++ ec ++ ",\"kty\":\"EC\"}"));
    try testing.expectEqual(@as(usize, 0), sets.set.count);
}

test "a set keeps the keys of the algorithms its caller takes" {
    var sets: Sets = .{};
    const text = "{\"keys\":[{" ++ ec ++ "},{" ++ okp ++ "},{" ++ rsa_key ++ "}]}";
    const cases = [_]struct { token.Algorithms, usize }{
        .{ .{}, 3 },
        .{ .{ .rs256 = false }, 2 },
        .{ .{ .es256 = false }, 2 },
        .{ .{ .eddsa = false }, 2 },
        .{ .{ .rs256 = false, .es256 = false }, 1 },
    };
    for (cases) |case| {
        try sets.set.read(text, &sets.scratch, case[0]);
        try testing.expectEqual(case[1], sets.set.count);
        for (sets.set.keys[0..sets.set.count]) |*key| try testing.expect(token.allows(case[0], key.algorithm));
    }
}

test "find takes the key of the header's algorithm and identifier" {
    var sets: Sets = .{};
    const text = "{\"keys\":[{" ++ ec ++ ",\"kid\":\"a\"},{" ++ okp ++ ",\"kid\":\"a\"},{" ++ ec ++ ",\"kid\":\"b\"},{" ++ rsa_key ++ "}]}";
    try sets.set.read(text, &sets.scratch, all);
    const set = &sets.set;
    try testing.expectEqual(@as(usize, 4), set.count);
    // RFC 7517 §4.5: keys of two families may share an identifier, and the algorithm tells them
    // apart.
    try testing.expectEqual(&set.keys[0], set.find(.es256, .{ .present = "a" }).?);
    try testing.expectEqual(&set.keys[1], set.find(.eddsa, .{ .present = "a" }).?);
    try testing.expectEqual(&set.keys[2], set.find(.es256, .{ .present = "b" }).?);
    try testing.expectEqual(@as(?*const jwks.Key, null), set.find(.eddsa, .{ .present = "b" }));
    try testing.expectEqual(@as(?*const jwks.Key, null), set.find(.es256, .{ .present = "" }));
    // A key with no identifier answers a header with none, and no header that names one.
    try testing.expectEqual(@as(?*const jwks.Key, null), set.find(.rs256, .{ .present = "a" }));
    try testing.expectEqual(@as(?*const jwks.Key, null), set.find(.rs256, .{ .present = "" }));
    try testing.expectEqual(&set.keys[3], set.find(.rs256, .absent).?);
    try testing.expectEqual(&set.keys[1], set.find(.eddsa, .absent).?);
    try testing.expectEqual(@as(?*const jwks.Key, null), set.find(.es256, .absent));
    for ([_]token.Algorithm{ .rs256, .es256, .eddsa }) |algorithm| try testing.expectEqual(@as(?*const jwks.Key, null), set.find(algorithm, .too_long));
}
