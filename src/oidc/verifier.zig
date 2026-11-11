//! The verifier of an OpenID Connect token: a JWT that an issuer signed (RFC 7519, RFC 7515). It
//! does no I/O and reads no clock. The program fetches the issuer's JWK Set and passes its text
//! to `set_keys`, and passes the time to `set_time`.
const std = @import("std");
const assert = std.debug.assert;
const chapulin = @import("chapulin");
const constants = @import("constants.zig");
const claims_file = @import("claims.zig");
const jwks = @import("jwks.zig");
const token_file = @import("token.zig");
const Reader = @import("reader.zig").Reader;

pub const Claims = claims_file.Claims;

pub const VerifierOptions = struct {
    /// The issuer whose tokens the verifier takes, as its discovery document names it (OpenID
    /// Connect Discovery 1.0 §3): a token's "iss" must equal it, octet for octet.
    issuer: []const u8 = "",
    /// The name of this service among the issuer's audiences: a token's "aud" must hold it.
    audience: []const u8 = "",
    /// The seconds the verifier's clock may differ from the issuer's (RFC 7519 §4.1.4), at most
    /// `constants.leeway_s_max`.
    leeway_s: u32 = 0,
    algorithms: Algorithms = .{},

    pub const Algorithms = token_file.Algorithms;
};

/// Why `verify` refused a token.
pub const Error = error{
    /// The text is not a JWT the verifier reads: not three parts of base64url, a header or
    /// claims that are not the JSON the RFCs require, a "crit" header, or no "exp".
    Malformed,
    /// The header's "alg" is one the verifier does not take: "none" and an HMAC among them.
    UnsupportedAlgorithm,
    /// The verifier holds no key that the header names. `keys_stale` then returns true.
    UnknownKey,
    InvalidSignature,
    Expired,
    NotYetValid,
    WrongIssuer,
    WrongAudience,
    /// The token is longer than `constants.token_bytes_max`.
    TokenTooLong,
};

/// The key sets a verifier holds: the one `verify` reads, and the one `set_keys` reads into, so
/// a JWK Set that is refused leaves the keys as they were.
const key_sets = 2;

pub const Verifier = struct {
    algorithms: VerifierOptions.Algorithms,
    leeway_s: u32,
    issuer_len: usize,
    audience_len: usize,
    now_unix_seconds: i64,
    time_set: bool,
    stale: bool,
    /// Whether `current` holds the claims of the last token `verify` took.
    verified: bool,
    /// The index in `sets` of the keys `verify` reads. `set_keys` reads into the other one.
    active: u1,
    current: Claims,
    sets: [key_sets]jwks.KeySet,
    issuer_storage: [constants.issuer_bytes_max]u8,
    audience_storage: [constants.audience_bytes_max]u8,
    subject_storage: [constants.subject_bytes_max]u8,
    /// A token's parts after their base64url decoding, one at a time: the header, then the
    /// signature, then the payload, which stays for `current`.
    decoded: [constants.decoded_bytes_max]u8,
    /// The storage of the JSON readers.
    scratch: [constants.decoded_bytes_max]u8,

    pub const InitError = error{ IssuerInvalid, AudienceInvalid, LeewayTooLong, NoAlgorithm };
    pub const KeysError = error{ Malformed, TooManyKeys, NoKeys };

    /// Starts a verifier with no key and no time. It copies what it keeps from `options`. An
    /// empty issuer or audience, or one longer than its bound, is refused.
    pub fn init(verifier: *Verifier, options: *const VerifierOptions) InitError!void {
        // The object's build record matches the headers this module compiled with (chapulin's
        // build.h).
        assert(chapulin.build_matches());
        if (options.issuer.len == 0 or options.issuer.len > constants.issuer_bytes_max) return error.IssuerInvalid;
        if (options.audience.len == 0 or options.audience.len > constants.audience_bytes_max) return error.AudienceInvalid;
        if (options.leeway_s > constants.leeway_s_max) return error.LeewayTooLong;
        // RFC 8725 §3.1: the caller states the algorithms, and one at least.
        const algorithms = options.algorithms;
        if (!algorithms.rs256 and !algorithms.es256 and !algorithms.eddsa) return error.NoAlgorithm;
        verifier.* = .{
            .algorithms = algorithms,
            .leeway_s = options.leeway_s,
            .issuer_len = options.issuer.len,
            .audience_len = options.audience.len,
            .now_unix_seconds = 0,
            .time_set = false,
            .stale = true,
            .verified = false,
            .active = 0,
            .current = undefined,
            .sets = .{ .{}, .{} },
            .issuer_storage = undefined,
            .audience_storage = undefined,
            .subject_storage = undefined,
            .decoded = undefined,
            .scratch = undefined,
        };
        @memcpy(verifier.issuer_storage[0..options.issuer.len], options.issuer);
        @memcpy(verifier.audience_storage[0..options.audience.len], options.audience);
    }

    pub fn deinit(verifier: *Verifier) void {
        verifier.* = undefined;
    }

    /// Replaces the keys with those of `jwks_text`, the issuer's JWK Set (RFC 7517 §5), which
    /// the program fetched from the "jwks_uri" of the issuer's discovery document. The verifier
    /// keeps the keys that verify a signature in one of its algorithms, `constants.keys_max` at
    /// most, and no pointer to the text. After an error it holds the keys it held before.
    pub fn set_keys(verifier: *Verifier, jwks_text: []const u8) KeysError!void {
        const spare: u1 = ~verifier.active;
        try verifier.sets[spare].read(jwks_text, &verifier.scratch, verifier.algorithms);
        assert(verifier.sets[spare].count <= constants.keys_max);
        if (verifier.sets[spare].count == 0) return error.NoKeys;
        verifier.active = spare;
        verifier.stale = false;
    }

    /// Sets the time `verify` compares "exp" and "nbf" with, in seconds since
    /// 1970-01-01T00:00:00Z. The program calls it when its clock moves: once in each turn of its
    /// event loop is enough.
    pub fn set_time(verifier: *Verifier, unix_seconds: i64) void {
        verifier.now_unix_seconds = unix_seconds;
        verifier.time_set = true;
    }

    /// True when the verifier needs the issuer's keys again: it holds none yet, or a token named
    /// a key it does not hold, as after the issuer changed its keys. Anyone can send such a
    /// token, so the program bounds how often it fetches.
    pub fn keys_stale(verifier: *const Verifier) bool {
        return verifier.stale;
    }

    /// The claims of the last token `verify` took, or null when it refused the last one.
    pub fn claims(verifier: *const Verifier) ?*const Claims {
        return if (verifier.verified) &verifier.current else null;
    }

    /// Checks `token`, a JWT in the JWS Compact Serialization, as RFC 7519 §7.2 orders the
    /// checks: its form, its header, its signature under the key the header names, then its
    /// issuer, its audience and its times. The claims it returns stay valid until the next call.
    /// The program calls `set_time` first.
    pub fn verify(verifier: *Verifier, token: []const u8) Error!*const Claims {
        assert(verifier.time_set);
        verifier.verified = false;
        if (token.len > constants.token_bytes_max) return error.TokenTooLong;
        const parts = try token_file.split(token);
        const key = try verifier.key_of(&parts);
        const payload = try verifier.signed_payload(&parts, key);
        try verifier.check(payload);
        assert(verifier.current.payload.ptr == &verifier.decoded);
        assert(verifier.current.expires_unix_seconds >= 0);
        verifier.verified = true;
        return &verifier.current;
    }

    /// The key the token's header names, among the algorithms the verifier takes.
    fn key_of(verifier: *Verifier, parts: *const token_file.Parts) Error!*const jwks.Key {
        // RFC 7515 §5.2 steps 2 and 3: the header is base64url, with no padding (§2), of UTF-8
        // JSON. chapulin's decoder refuses a text that is not canonical.
        const text = chapulin.jws.base64url_decode(&verifier.decoded, parts.header) catch return error.Malformed;
        var key_id: [constants.key_id_bytes_max]u8 = @splat(0);
        var reader: Reader = undefined;
        reader.init(text, &verifier.scratch);
        const header = try token_file.read_header(&reader, &key_id);
        const algorithm = header.algorithm orelse return error.UnsupportedAlgorithm;
        // RFC 8725 §3.1: no algorithm but those the caller stated.
        if (!token_file.allows(verifier.algorithms, algorithm)) return error.UnsupportedAlgorithm;
        return verifier.sets[verifier.active].find(algorithm, header.key_id) orelse {
            verifier.stale = true;
            return error.UnknownKey;
        };
    }

    /// Checks the signature, and returns the payload after its base64url decoding. No claim is
    /// read before the signature passed.
    fn signed_payload(verifier: *Verifier, parts: *const token_file.Parts, key: *const jwks.Key) Error![]const u8 {
        assert(parts.signing_input.len < constants.token_bytes_max);
        const signature = chapulin.jws.base64url_decode(&verifier.decoded, parts.signature) catch return error.Malformed;
        // RFC 7515 §5.2 step 8: the signature is over the JWS Signing Input. RFC 8725 §3.1: the
        // algorithm is the key's own, which `find` matched with the header's "alg". A key that
        // chapulin refuses verifies nothing.
        chapulin.jws.verify(&.{
            .algorithm = key.algorithm,
            .key = key.bytes(),
            .input = parts.signing_input,
            .signature = signature,
        }) catch return error.InvalidSignature;
        return chapulin.jws.base64url_decode(&verifier.decoded, parts.payload) catch return error.Malformed;
    }

    /// Checks the claims of `payload`, and keeps them as `current`.
    fn check(verifier: *Verifier, payload: []const u8) Error!void {
        const issuer = verifier.issuer_storage[0..verifier.issuer_len];
        var reader: Reader = undefined;
        reader.init(payload, &verifier.scratch);
        const found = try claims_file.read(&reader, &.{
            .issuer = issuer,
            .audience = verifier.audience_storage[0..verifier.audience_len],
        }, &verifier.subject_storage);
        // RFC 7519 §4.1.1 and OpenID Connect Core 1.0 §3.1.3.7 rule 2.
        if (!found.issuer_matches) return error.WrongIssuer;
        // RFC 7519 §4.1.3: a token that does not name this service among its audiences MUST be
        // refused.
        if (!found.audience_matches) return error.WrongAudience;
        const now = verifier.now_unix_seconds;
        const leeway: i64 = verifier.leeway_s;
        assert(leeway <= constants.leeway_s_max);
        // RFC 7519 §4.1.4: the current time MUST be before the expiration time. A date holds
        // `numeric_date_digits_max` digits at most, so the sum stays far inside an i64.
        if (now >= found.expires.ceiling() + leeway) return error.Expired;
        // RFC 7519 §4.1.5: the current time MUST be after or equal to the not-before time. The
        // time is below the token's end here, so this sum stays inside an i64 too.
        if (found.not_before) |not_before| {
            if (now + leeway < not_before.ceiling()) return error.NotYetValid;
        }
        verifier.current = .{
            .subject = found.subject,
            .issuer = issuer,
            .expires_unix_seconds = found.expires.seconds,
            .payload = payload,
        };
    }
};
