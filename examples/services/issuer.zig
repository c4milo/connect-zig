//! A test-only OpenID provider for the examples: it stands where a real issuer would be. It
//! holds ES256 keys made from fixed seeds, writes their public halves as a JWK Set (RFC 7517
//! §5), and signs the tokens the example's client sends (RFC 7519). Anyone can read the seeds
//! here, so a token of this issuer proves nothing outside the examples.
//!
//! A real program has no part of this file: its provider signs the tokens, and the program
//! fetches the provider's JWK Set from the "jwks_uri" of its discovery document.
const std = @import("std");

const P256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const base64url = std.base64.url_safe_no_pad.Encoder;

/// What the provider calls itself, in each token's "iss".
pub const name = "https://issuer.example";

/// The longest JWK Set and the longest token this issuer writes.
pub const jwks_len_max = 1024;
pub const token_len_max = 1024;

/// SEC 1 §2.3.3: an uncompressed point is one octet, then X, then Y, 32 octets each on P-256.
const coordinate_len = 32;
const x_start = 1;
const y_start = x_start + coordinate_len;
const point_len = y_start + coordinate_len;
const seed_len = 32;

/// One signing key, and the "kid" its tokens and its JWK name it by.
pub const Key = struct {
    id: []const u8,
    pair: P256.KeyPair,

    /// The key a seed gives: the same one each run, so the examples replay.
    pub fn init(id: []const u8, seed: u8) Key {
        const octets: [seed_len]u8 = @splat(seed);
        return .{ .id = id, .pair = P256.KeyPair.generateDeterministic(octets) catch unreachable };
    }
};

/// The key the example servers start with, and the key the issuer moves to later, as a provider
/// changes its keys.
pub fn first_key() Key {
    return .init("key-1", 1);
}

pub fn second_key() Key {
    return .init("key-2", 2);
}

/// Text written into a buffer its caller owns.
const Text = struct {
    buffer: []u8,
    len: usize = 0,

    fn raw(text: *Text, octets: []const u8) void {
        @memcpy(text.buffer[text.len..][0..octets.len], octets);
        text.len += octets.len;
    }

    fn print(text: *Text, comptime format: []const u8, arguments: anytype) void {
        text.len += (std.fmt.bufPrint(text.buffer[text.len..], format, arguments) catch unreachable).len;
    }

    fn encoded(text: *Text, octets: []const u8) void {
        text.len += base64url.encode(text.buffer[text.len..], octets).len;
    }

    fn written(text: *const Text) []const u8 {
        return text.buffer[0..text.len];
    }
};

/// The JWK Set of `keys`, as the provider serves it at its "jwks_uri": each key's public point
/// (RFC 7518 §6.2.1), with the use and the algorithm it signs with (RFC 7517 §4.2 and §4.4).
pub fn jwks(buffer: []u8, keys: []const Key) []const u8 {
    var text: Text = .{ .buffer = buffer };
    text.raw("{\"keys\":[");
    for (keys, 0..) |key, index| {
        if (index != 0) text.raw(",");
        const point = key.pair.public_key.toUncompressedSec1();
        text.print("{{\"kty\":\"EC\",\"crv\":\"P-256\",\"use\":\"sig\",\"alg\":\"ES256\",\"kid\":\"{s}\",\"x\":\"", .{key.id});
        text.encoded(point[x_start..y_start]);
        text.raw("\",\"y\":\"");
        text.encoded(point[y_start..point_len]);
        text.raw("\"}");
    }
    text.raw("]}");
    return text.written();
}

/// What a token states.
pub const Claims = struct {
    subject: []const u8,
    audience: []const u8,
    /// "exp", in seconds since 1970-01-01T00:00:00Z.
    expires_unix_seconds: i64,
    email: []const u8 = "",
    /// The token's "roles" hold "admin".
    admin: bool = false,
};

/// A token `key` signed: the header, the claims and the signature, each in base64url, with a
/// '.' between them (RFC 7515 §7.1).
pub fn token(buffer: []u8, key: *const Key, claims: *const Claims) []const u8 {
    var text: Text = .{ .buffer = buffer };
    // Each part is written as JSON into the scratch room, then encoded into the token.
    text.encoded(std.fmt.bufPrint(&scratch, "{{\"alg\":\"ES256\",\"typ\":\"JWT\",\"kid\":\"{s}\"}}", .{key.id}) catch unreachable);
    text.raw(".");
    text.encoded(payload_of(claims));
    // RFC 7515 §5.1: the signature is over the first two parts and the '.' between them. With
    // no noise the signature is RFC 6979's, so the same token comes out each run.
    const signature = (key.pair.sign(text.written(), null) catch unreachable).toBytes();
    text.raw(".");
    text.encoded(&signature);
    return text.written();
}

/// The claims as JSON, in the scratch room.
fn payload_of(claims: *const Claims) []const u8 {
    var text: Text = .{ .buffer = &scratch };
    text.print("{{\"iss\":\"{s}\",\"sub\":\"{s}\",\"aud\":\"{s}\",\"exp\":{d}", .{ name, claims.subject, claims.audience, claims.expires_unix_seconds });
    if (claims.email.len != 0) text.print(",\"email\":\"{s}\"", .{claims.email});
    text.print(",\"roles\":[{s}]}}", .{if (claims.admin) "\"reader\",\"admin\"" else "\"reader\""});
    return text.written();
}

var scratch: [token_len_max]u8 = undefined;
