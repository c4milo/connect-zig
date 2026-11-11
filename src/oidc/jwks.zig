//! The keys of a JWK Set (RFC 7517 §5), each in the form chapulin's `jws.verify` takes.
const std = @import("std");
const assert = std.debug.assert;
const chapulin = @import("chapulin");
const constants = @import("constants.zig");
const reader_file = @import("reader.zig");
const Reader = reader_file.Reader;
const token = @import("token.zig");
const Algorithm = token.Algorithm;

pub const Error = error{ Malformed, TooManyKeys };

/// One public key and the one algorithm it signs with (RFC 8725 §3.1).
pub const Key = struct {
    algorithm: Algorithm,
    has_id: bool,
    id_len: u8,
    octets_len: u16,
    id: [constants.key_id_bytes_max]u8,
    /// RS256: RFC 3110 §2's form, which is one octet of exponent length, the exponent and the
    /// modulus. ES256: X then Y. EdDSA: the 32 octets of the key.
    octets: [constants.key_bytes_max]u8,

    pub fn bytes(key: *const Key) []const u8 {
        return key.octets[0..key.octets_len];
    }

    /// The JWK's "kid" (RFC 7517 §4.5), or null for a key with none.
    pub fn key_id(key: *const Key) ?[]const u8 {
        return if (key.has_id) key.id[0..key.id_len] else null;
    }
};

pub const KeySet = struct {
    keys: [constants.keys_max]Key = undefined,
    count: usize = 0,

    /// Replaces the set with the keys of `text` that verify a signature in one of `algorithms`.
    /// RFC 7517 §5: a reader passes over a key of a type it does not know, one that lacks a
    /// member, and one whose values are out of range. More than `keys_max` keys that remain is
    /// `error.TooManyKeys`. After an error the set holds no key.
    pub fn read(set: *KeySet, text: []const u8, scratch: []u8, algorithms: token.Algorithms) Error!void {
        set.count = 0;
        errdefer set.count = 0;
        var reader: Reader = undefined;
        reader.init(text, scratch);
        // RFC 7517 §5: a JWK Set is a JSON object.
        try reader.expect(.begin_object);
        var members: reader_file.Members(enum { keys }) = .{ .reader = &reader };
        // Bounded: each member takes at least one octet of the input.
        for (0..text.len + 1) |_| {
            _ = try members.next() orelse break;
            try set.read_keys(&reader, algorithms);
        } else unreachable;
        try reader.expect(.end);
        // RFC 7517 §5.1: "keys" MUST be present.
        if (!members.seen.contains(.keys)) return error.Malformed;
    }

    /// RFC 7517 §5.1: the value of "keys" is an array of JWK values, and a JWK is an object (§4).
    fn read_keys(set: *KeySet, reader: *Reader, algorithms: token.Algorithms) Error!void {
        try reader.expect(.begin_array);
        // Bounded: each key takes at least one octet of the input.
        for (0..reader.input.len + 1) |_| {
            switch (try reader.next()) {
                .end_array => return,
                .begin_object => {},
                else => return error.Malformed,
            }
            var draft: Draft = .{};
            try draft.read(reader);
            const algorithm = draft.algorithm() orelse continue;
            if (!token.allows(algorithms, algorithm)) continue;
            if (set.count == set.keys.len) return error.TooManyKeys;
            draft.write(algorithm, &set.keys[set.count]);
            set.count += 1;
        }
        unreachable;
    }

    /// The key a header names. With a "kid", the key of that algorithm with that identifier.
    /// With none, the key of that algorithm when the set holds exactly one: the header's
    /// algorithm alone then names it.
    pub fn find(set: *const KeySet, algorithm: Algorithm, key_id: token.Header.KeyId) ?*const Key {
        assert(set.count <= set.keys.len);
        var only: ?*const Key = null;
        for (set.keys[0..set.count]) |*key| {
            if (key.algorithm != algorithm) continue;
            switch (key_id) {
                .present => |id| if (key.has_id and std.mem.eql(u8, key.id[0..key.id_len], id)) return key,
                .absent => {
                    if (only != null) return null;
                    only = key;
                },
                .too_long => return null,
            }
        }
        return only;
    }
};

/// The members of a JWK the verifier reads (RFC 7517 §4, RFC 7518 §6.2.1 and §6.3.1, RFC 8037
/// §2). A private key's members pass unread.
const Member = enum { kty, crv, alg, use, key_ops, kid, n, e, x, y };

const KeyType = enum { RSA, EC, OKP };
const Curve = enum { @"P-256", Ed25519 };

/// What a JWK's members said, before the key is known to be one the verifier keeps.
const Draft = struct {
    /// False once a member holds a value that no key the verifier keeps has.
    usable: bool = true,
    key_type: ?KeyType = null,
    curve: ?Curve = null,
    algorithm_named: bool = false,
    algorithm_name: ?Algorithm = null,
    has_id: bool = false,
    id_len: usize = 0,
    modulus_len: usize = 0,
    exponent_len: usize = 0,
    x_len: usize = 0,
    y_len: usize = 0,
    id: [constants.key_id_bytes_max]u8 = @splat(0),
    modulus: [constants.rsa_modulus_bytes_max]u8 = @splat(0),
    exponent: [constants.rsa_exponent_bytes_max]u8 = @splat(0),
    x: [constants.coordinate_bytes]u8 = @splat(0),
    y: [constants.coordinate_bytes]u8 = @splat(0),

    /// Reads the members of the JWK whose `{` the reader took.
    fn read(draft: *Draft, reader: *Reader) Error!void {
        var members: reader_file.Members(Member) = .{ .reader = reader };
        // Bounded: each member takes at least one octet of the input.
        for (0..reader.input.len + 1) |_| {
            const member = try members.next() orelse return;
            if (member == .key_ops) {
                if (!try verifies(reader)) draft.usable = false;
                continue;
            }
            // Each other member the verifier reads is a string.
            const text = try reader.string_or_skip() orelse {
                draft.usable = false;
                continue;
            };
            draft.take(member, text);
        }
        unreachable;
    }

    fn take(draft: *Draft, member: Member, text: []const u8) void {
        switch (member) {
            // RFC 7517 §4.1: "kty" names the key's family, case-sensitive.
            .kty => draft.key_type = std.meta.stringToEnum(KeyType, text),
            // RFC 7518 §6.2.1.1 and RFC 8037 §2: "crv" names the curve.
            .crv => draft.curve = std.meta.stringToEnum(Curve, text),
            .alg => {
                draft.algorithm_named = true;
                draft.algorithm_name = token.algorithm_of(text);
            },
            // RFC 7517 §4.2: a key whose "use" is not "sig" does not verify a signature.
            .use => draft.usable = draft.usable and std.mem.eql(u8, text, "sig"),
            .kid => {
                draft.has_id = true;
                draft.id_len = text.len;
                if (text.len > draft.id.len) draft.usable = false else @memcpy(draft.id[0..text.len], text);
            },
            .n => draft.modulus_len = decode(&draft.modulus, text),
            .e => draft.exponent_len = decode(&draft.exponent, text),
            .x => draft.x_len = decode(&draft.x, text),
            .y => draft.y_len = decode(&draft.y, text),
            .key_ops => unreachable,
        }
    }

    /// RFC 7518 §2 and §6.2.1.2: an integer and a coordinate are base64url. A text that is not,
    /// or that decodes to more octets than the member's bound, leaves the member with no octet,
    /// as if the JWK did not hold it.
    fn decode(out: []u8, text: []const u8) usize {
        const octets = chapulin.jws.base64url_decode(out, text) catch return 0;
        return octets.len;
    }

    /// The one algorithm the key verifies with, or null for a key the verifier does not keep.
    fn algorithm(draft: *const Draft) ?Algorithm {
        if (!draft.usable) return null;
        const of_type = draft.family_algorithm() orelse return null;
        // RFC 7517 §4.4: an "alg" names the one algorithm the key is for. A key for another
        // algorithm of its family, RS384 or PS256 among them, is not kept.
        if (draft.algorithm_named and draft.algorithm_name != of_type) return null;
        return of_type;
    }

    /// The algorithm of the key's family, when the family's own members are in range.
    fn family_algorithm(draft: *const Draft) ?Algorithm {
        // RFC 7517 §4.1: "kty" MUST be present.
        const in_range, const of_type: Algorithm = switch (draft.key_type orelse return null) {
            .RSA => .{ draft.rsa_in_range(), .rs256 },
            // RFC 7518 §6.2.1.2 and §6.2.1.3: "x" and "y" are each the full coordinate of P-256.
            .EC => .{ draft.curve == .@"P-256" and draft.x_len == draft.x.len and draft.y_len == draft.y.len, .es256 },
            // RFC 8037 §2: "x" is the 32 octets of an Ed25519 public key.
            .OKP => .{ draft.curve == .Ed25519 and draft.x_len == draft.x.len, .eddsa },
        };
        return if (in_range) of_type else null;
    }

    fn rsa_in_range(draft: *const Draft) bool {
        // RFC 7518 §3.3: a key of 2048 bits or more. The upper bound is chapulin's.
        if (draft.modulus_len < constants.rsa_modulus_bytes_min) return false;
        // RFC 7518 §2, Base64urlUInt: the least octets that hold the value, so no zero leads. An
        // exponent the JWK does not hold has no octet, and the draft's first octet is then zero.
        return draft.modulus[0] != 0 and draft.exponent[0] != 0;
    }

    fn write(draft: *const Draft, of_type: Algorithm, key: *Key) void {
        assert(draft.usable);
        assert(draft.id_len <= key.id.len);
        key.algorithm = of_type;
        key.has_id = draft.has_id;
        key.id_len = @intCast(draft.id_len);
        @memcpy(key.id[0..draft.id_len], draft.id[0..draft.id_len]);
        var writer: std.Io.Writer = .fixed(&key.octets);
        switch (of_type) {
            .rs256 => {
                // RFC 3110 §2: one octet holds the length of an exponent under 256 octets.
                writer.writeByte(@intCast(draft.exponent_len)) catch unreachable;
                writer.writeAll(draft.exponent[0..draft.exponent_len]) catch unreachable;
                writer.writeAll(draft.modulus[0..draft.modulus_len]) catch unreachable;
            },
            .es256 => {
                writer.writeAll(&draft.x) catch unreachable;
                writer.writeAll(&draft.y) catch unreachable;
            },
            .eddsa => writer.writeAll(&draft.x) catch unreachable,
        }
        key.octets_len = @intCast(writer.end);
    }
};

/// RFC 7517 §4.3: "key_ops" is an array of strings, and a key that verifies names "verify".
fn verifies(reader: *Reader) Error!bool {
    switch (try reader.next()) {
        .begin_array => {},
        .begin_object => {
            try reader.skip_container();
            return false;
        },
        .string, .number, .literal, .long => return false,
        .end_object, .end_array, .name, .end => return error.Malformed,
    }
    var found = false;
    // Bounded: each element takes at least one octet of the input.
    for (0..reader.input.len + 1) |_| {
        switch (try reader.next()) {
            .end_array => return found,
            .string => |operation| found = found or std.mem.eql(u8, operation, "verify"),
            .number, .literal, .long => {},
            .begin_object, .begin_array => try reader.skip_container(),
            .end_object, .name, .end => unreachable,
        }
    }
    unreachable;
}
