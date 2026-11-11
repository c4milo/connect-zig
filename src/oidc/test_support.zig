//! What the module's tests share: tokens signed by Zig's standard library, so the signatures
//! chapulin verifies come from another implementation, and a verifier that holds their key.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const verifier_file = @import("verifier.zig");
const Verifier = verifier_file.Verifier;

const Ed25519 = std.crypto.sign.Ed25519;
const P256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const issuer = "https://issuer.example";
pub const audience = "service";
pub const key_id = "key-1";
/// The time of the fixture's verifier.
pub const now: i64 = 1_700_000_000;
/// Room for a token past the longest the verifier takes, and for a JWK Set of a few keys.
const text_tokens = 3;
pub const text_bytes = text_tokens * constants.token_bytes_max;
const seed_bytes = 32;
/// R then S, for both algorithms (RFC 7518 §3.4, RFC 8037 §3.1).
const signature_bytes = 64;
/// SEC 1 §2.3.3: an uncompressed point is one octet, then X, then Y.
const point_x_start = 1;
const point_y_start = point_x_start + constants.coordinate_bytes;
const point_end = point_y_start + constants.coordinate_bytes;
const header_bytes = 128;

/// Text written into a buffer the test owns.
pub const Text = struct {
    buffer: []u8,
    len: usize = 0,

    pub fn raw(text: *Text, octets: []const u8) void {
        @memcpy(text.buffer[text.len..][0..octets.len], octets);
        text.len += octets.len;
    }

    pub fn print(text: *Text, comptime format: []const u8, arguments: anytype) void {
        text.len += (std.fmt.bufPrint(text.buffer[text.len..], format, arguments) catch unreachable).len;
    }

    pub fn base64url(text: *Text, octets: []const u8) void {
        text.len += std.base64.url_safe_no_pad.Encoder.encode(text.buffer[text.len..], octets).len;
    }

    pub fn written(text: *const Text) []const u8 {
        return text.buffer[0..text.len];
    }
};

pub const Kind = enum { es256, eddsa };

/// A key pair made from a seed, which signs with ES256 or with EdDSA.
pub const Signer = union(Kind) {
    es256: P256.KeyPair,
    eddsa: Ed25519.KeyPair,

    pub fn init(kind: Kind, seed: u8) Signer {
        const octets: [seed_bytes]u8 = @splat(seed);
        return switch (kind) {
            .es256 => .{ .es256 = P256.KeyPair.generateDeterministic(octets) catch unreachable },
            .eddsa => .{ .eddsa = Ed25519.KeyPair.generateDeterministic(octets) catch unreachable },
        };
    }

    pub fn algorithm_name(signer: *const Signer) []const u8 {
        return switch (signer.*) {
            .es256 => "ES256",
            .eddsa => "EdDSA",
        };
    }

    /// The signature in the form a JWS carries: R then S, 64 octets, for both algorithms (RFC
    /// 7518 §3.4, RFC 8037 §3.1).
    pub fn sign(signer: *const Signer, input: []const u8) [signature_bytes]u8 {
        return switch (signer.*) {
            .es256 => |pair| (pair.sign(input, null) catch unreachable).toBytes(),
            .eddsa => |pair| (pair.sign(input, null) catch unreachable).toBytes(),
        };
    }

    /// Writes the public key as a JWK, with `extra` members before its end: "" or text that
    /// starts with a comma.
    pub fn jwk(signer: *const Signer, text: *Text, id: ?[]const u8, extra: []const u8) void {
        switch (signer.*) {
            .es256 => |pair| {
                const point = pair.public_key.toUncompressedSec1();
                text.raw("{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"");
                text.base64url(point[point_x_start..point_y_start]);
                text.raw("\",\"y\":\"");
                text.base64url(point[point_y_start..point_end]);
            },
            .eddsa => |pair| {
                text.raw("{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\"");
                text.base64url(&pair.public_key.toBytes());
            },
        }
        text.raw("\"");
        if (id) |octets| text.print(",\"kid\":\"{s}\"", .{octets});
        text.raw(extra);
        text.raw("}");
    }
};

/// Writes the token of `header` and `payload`, which are JSON text, signed by `signer`.
pub fn mint(text: *Text, signer: *const Signer, header: []const u8, payload: []const u8) []const u8 {
    const start = text.len;
    text.base64url(header);
    text.raw(".");
    text.base64url(payload);
    return sealed(text, signer, start);
}

/// Writes a token whose first two parts are `header` and `payload` as they are, with no
/// encoding, signed by `signer`: a true signature over parts an issuer does not write.
pub fn mint_parts(text: *Text, signer: *const Signer, header: []const u8, payload: []const u8) []const u8 {
    const start = text.len;
    text.raw(header);
    text.raw(".");
    text.raw(payload);
    return sealed(text, signer, start);
}

fn sealed(text: *Text, signer: *const Signer, start: usize) []const u8 {
    const signature = signer.sign(text.buffer[start..text.len]);
    text.raw(".");
    text.base64url(&signature);
    return text.buffer[start..text.len];
}

/// A verifier for `issuer` and `audience` at the time `now`, which holds one key, `key_id`.
pub const Fixture = struct {
    verifier: Verifier,
    claims: verifier_file.Claims,
    signer: Signer,
    buffer: [text_bytes]u8,

    pub fn init(fixture: *Fixture, kind: Kind) !void {
        try fixture.init_with(kind, &.{ .issuer = issuer, .audience = audience });
    }

    pub fn init_with(fixture: *Fixture, kind: Kind, options: *const verifier_file.VerifierOptions) !void {
        fixture.signer = Signer.init(kind, 1);
        fixture.claims = .{};
        try fixture.verifier.init(options);
        var text: Text = .{ .buffer = &fixture.buffer };
        text.raw("{\"keys\":[");
        fixture.signer.jwk(&text, key_id, "");
        text.raw("]}");
        try fixture.verifier.set_keys(text.written());
        fixture.verifier.set_time(now);
    }

    /// The header that names the fixture's key.
    pub fn header(fixture: *const Fixture, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{{\"alg\":\"{s}\",\"typ\":\"JWT\",\"kid\":\"{s}\"}}", .{ fixture.signer.algorithm_name(), key_id }) catch unreachable;
    }

    /// A token the fixture's key signed, with the header that names it.
    pub fn token(fixture: *Fixture, payload: []const u8) []const u8 {
        var header_buffer: [header_bytes]u8 = undefined;
        return fixture.token_with(fixture.header(&header_buffer), payload);
    }

    pub fn token_with(fixture: *Fixture, header_text: []const u8, payload: []const u8) []const u8 {
        var text: Text = .{ .buffer = &fixture.buffer };
        return mint(&text, &fixture.signer, header_text, payload);
    }

    /// Verifies `text`, a token, into the fixture's claims, and returns them.
    pub fn verify(fixture: *Fixture, text: []const u8) verifier_file.Error!*verifier_file.Claims {
        try fixture.verifier.verify(text, &fixture.claims);
        return &fixture.claims;
    }

    /// What `verify` answers for a token of `payload`.
    pub fn check(fixture: *Fixture, payload: []const u8) verifier_file.Error!*verifier_file.Claims {
        return fixture.verify(fixture.token(payload));
    }
};

/// Claims that the fixture's verifier takes: its issuer and its audience, an hour to live.
pub const good_claims = "{\"iss\":\"" ++ issuer ++ "\",\"sub\":\"user-1\",\"aud\":\"" ++ audience ++ "\",\"exp\":1700003600}";
pub const good_expires: i64 = 1_700_003_600;
