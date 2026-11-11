//! A token's three parts (RFC 7515 §7.1) and its header (RFC 7515 §4).
const std = @import("std");
const assert = std.debug.assert;
const chapulin = @import("chapulin");
const constants = @import("constants.zig");
const reader_file = @import("reader.zig");
const Reader = reader_file.Reader;

pub const Error = error{Malformed};

/// The signature algorithms the verifier reads: RS256 and ES256 (RFC 7518 §3.1) and EdDSA with
/// Ed25519 (RFC 8037 §3.1).
pub const Algorithm = chapulin.jws.Algorithm;

/// The algorithms a verifier takes (RFC 8725 §3.1: the caller states them, and no other is
/// used). Each key signs with one algorithm, which its JWK fixes, so a token cannot move a key to
/// another one; the default takes all three.
pub const Algorithms = struct {
    /// RSASSA-PKCS1-v1_5 with SHA-256, which every OpenID provider signs with (OpenID Connect
    /// Core 1.0 §15.1).
    rs256: bool = true,
    /// ECDSA with P-256 and SHA-256.
    es256: bool = true,
    /// EdDSA with Ed25519.
    eddsa: bool = true,
};

pub fn allows(algorithms: Algorithms, algorithm: Algorithm) bool {
    return switch (algorithm) {
        .rs256 => algorithms.rs256,
        .es256 => algorithms.es256,
        .eddsa => algorithms.eddsa,
    };
}

/// The algorithm an "alg" value names, or null for one the verifier does not read: "none", an
/// HMAC and each other name. The names are case-sensitive (RFC 7515 §4.1.1).
pub fn algorithm_of(name: []const u8) ?Algorithm {
    const Name = enum { RS256, ES256, EdDSA };
    return switch (std.meta.stringToEnum(Name, name) orelse return null) {
        .RS256 => .rs256,
        .ES256 => .es256,
        .EdDSA => .eddsa,
    };
}

/// A token's parts, in base64url as the token carries them.
pub const Parts = struct {
    header: []const u8,
    payload: []const u8,
    signature: []const u8,
    /// The JWS Signing Input (RFC 7515 §5.2): the header, '.', and the payload.
    signing_input: []const u8,
};

const separator = '.';

/// RFC 7515 §7.1: the JWS Compact Serialization is three parts with a '.' between them. A text
/// with another count of parts is no JWS; a JWE has five (RFC 7516 §7.1).
pub fn split(token: []const u8) Error!Parts {
    const first = std.mem.indexOfScalar(u8, token, separator) orelse return error.Malformed;
    const second = std.mem.indexOfScalarPos(u8, token, first + 1, separator) orelse return error.Malformed;
    if (std.mem.indexOfScalarPos(u8, token, second + 1, separator) != null) return error.Malformed;
    return .{
        .header = token[0..first],
        .payload = token[first + 1 .. second],
        .signature = token[second + 1 ..],
        .signing_input = token[0..second],
    };
}

pub const Header = struct {
    /// The "alg" (RFC 7515 §4.1.1), or null for an algorithm the verifier does not read.
    algorithm: ?Algorithm,
    key_id: KeyId,

    /// The "kid" (RFC 7515 §4.1.4): the hint that names the key.
    pub const KeyId = union(enum) {
        absent,
        present: []const u8,
        /// Longer than `key_id_bytes_max`, so it names no key the verifier holds.
        too_long,
    };
};

/// The header parameters the verifier reads. It reads no key from a token: "jwk", "jku", "x5c"
/// and "x5u" pass unread, and the key comes from the verifier's own set (RFC 8725 §3.10).
const Parameter = enum { alg, kid, crit };

/// Reads the header from `reader`, whose text is the first part after its base64url decoding.
/// The octets of a "kid" go to `key_id_storage`.
pub fn read_header(reader: *Reader, key_id_storage: *[constants.key_id_bytes_max]u8) Error!Header {
    // RFC 7515 §4: the JOSE Header is a JSON object.
    try reader.expect(.begin_object);
    var header: Header = .{ .algorithm = null, .key_id = .absent };
    var members: reader_file.Members(Parameter) = .{ .reader = reader };
    // Bounded: each member takes at least one octet of the input.
    for (0..reader.input.len + 1) |_| {
        const parameter = try members.next() orelse break;
        switch (parameter) {
            // RFC 7515 §4.1.1: "alg" is a string.
            .alg => header.algorithm = algorithm_of(try reader.string()),
            .kid => header.key_id = try key_id_of(reader, key_id_storage),
            // RFC 7515 §4.1.11: a JWS that names a critical extension its reader does not
            // implement is invalid. The verifier implements none.
            .crit => return error.Malformed,
        }
    } else unreachable;
    try reader.expect(.end);
    // RFC 7515 §4.1.1: "alg" MUST be present.
    if (!members.seen.contains(.alg)) return error.Malformed;
    return header;
}

/// RFC 7515 §4.1.4: "kid" is a string.
fn key_id_of(reader: *Reader, storage: *[constants.key_id_bytes_max]u8) Error!Header.KeyId {
    switch (try reader.next()) {
        .string => |octets| {
            if (octets.len > storage.len) return .too_long;
            @memcpy(storage[0..octets.len], octets);
            return .{ .present = storage[0..octets.len] };
        },
        .long => return .too_long,
        else => return error.Malformed,
    }
}

const testing = std.testing;

test "split takes three parts, and refuses another count" {
    const parts = try split("aa.bbb.c");
    try testing.expectEqualStrings("aa", parts.header);
    try testing.expectEqualStrings("bbb", parts.payload);
    try testing.expectEqualStrings("c", parts.signature);
    try testing.expectEqualStrings("aa.bbb", parts.signing_input);

    const empty = try split("..");
    try testing.expectEqualStrings("", empty.header);
    try testing.expectEqualStrings("", empty.payload);
    try testing.expectEqualStrings("", empty.signature);

    // RFC 7515 §7.1, and RFC 7516 §7.1 for the five parts of a JWE.
    for ([_][]const u8{ "", "a", "a.b", "a.b.c.d", "a.b.c.d.e" }) |text| try testing.expectError(error.Malformed, split(text));
}

const header_storage_bytes = 256;

fn header_of(text: []const u8, key_id_storage: *[constants.key_id_bytes_max]u8) Error!Header {
    var storage: [header_storage_bytes]u8 = undefined;
    var reader: Reader = undefined;
    reader.init(text, &storage);
    return read_header(&reader, key_id_storage);
}

test "read_header reads the algorithm and the key identifier" {
    var key_id: [constants.key_id_bytes_max]u8 = undefined;
    const names = [_]struct { []const u8, ?Algorithm }{
        .{ "RS256", .rs256 }, .{ "ES256", .es256 }, .{ "EdDSA", .eddsa },
        // RFC 8725 §3.2: "none" is no algorithm the verifier takes. A name is case-sensitive.
        .{ "none", null },    .{ "HS256", null },   .{ "rs256", null },
        .{ "RS384", null },   .{ "", null },
    };
    for (names) |each| {
        var text: [64]u8 = undefined;
        const header = try header_of(try std.fmt.bufPrint(&text, "{{\"typ\":\"JWT\",\"alg\":\"{s}\"}}", .{each[0]}), &key_id);
        try testing.expectEqual(each[1], header.algorithm);
        try testing.expectEqual(Header.KeyId.absent, header.key_id);
    }

    const named = try header_of("{\"kid\":\"key-1\",\"alg\":\"ES256\",\"jwk\":{\"kty\":\"EC\"},\"x5c\":[\"a\"]}", &key_id);
    try testing.expectEqual(Algorithm.es256, named.algorithm.?);
    try testing.expectEqualStrings("key-1", named.key_id.present);

    const longest = "{\"alg\":\"ES256\",\"kid\":\"" ++ "k" ** constants.key_id_bytes_max ++ "\"}";
    try testing.expectEqualStrings("k" ** constants.key_id_bytes_max, (try header_of(longest, &key_id)).key_id.present);
    const too_long = "{\"alg\":\"ES256\",\"kid\":\"" ++ "k" ** (constants.key_id_bytes_max + 1) ++ "\"}";
    try testing.expectEqual(Header.KeyId.too_long, (try header_of(too_long, &key_id)).key_id);
    const past_storage = "{\"alg\":\"ES256\",\"kid\":\"" ++ "k" ** 300 ++ "\"}";
    try testing.expectEqual(Header.KeyId.too_long, (try header_of(past_storage, &key_id)).key_id);
}

test "read_header refuses a header the RFC does not allow" {
    var key_id: [constants.key_id_bytes_max]u8 = undefined;
    const refused = [_][]const u8{
        // RFC 7515 §4: an object.
        "[]",
        "\"RS256\"",
        "",
        // RFC 7515 §4.1.1: "alg" is present, and is a string.
        "{}",
        "{\"kid\":\"a\"}",
        "{\"alg\":1}",
        "{\"alg\":null}",
        "{\"alg\":[\"RS256\"]}",
        // RFC 7515 §4.1.4: "kid" is a string.
        "{\"alg\":\"RS256\",\"kid\":7}",
        // RFC 7515 §4.1.11: a critical extension the reader does not implement.
        "{\"alg\":\"RS256\",\"crit\":[\"b64\"],\"b64\":false}",
        "{\"alg\":\"RS256\",\"crit\":[]}",
        // RFC 7515 §4: a parameter appears once.
        "{\"alg\":\"none\",\"alg\":\"RS256\"}",
        "{\"alg\":\"RS256\",\"kid\":\"a\",\"kid\":\"b\"}",
        // RFC 8259 §2: one value, and no more.
        "{\"alg\":\"RS256\"} {}",
        "{\"alg\":\"RS256\"",
    };
    for (refused) |text| try testing.expectError(error.Malformed, header_of(text, &key_id));
}

test "allows reads each algorithm's own field" {
    const algorithms = [_]Algorithm{ .rs256, .es256, .eddsa };
    const sets = [_]Algorithms{
        .{ .rs256 = true, .es256 = false, .eddsa = false },
        .{ .rs256 = false, .es256 = true, .eddsa = false },
        .{ .rs256 = false, .es256 = false, .eddsa = true },
    };
    for (sets, 0..) |set, allowed| {
        for (algorithms, 0..) |algorithm, index| try testing.expectEqual(index == allowed, allows(set, algorithm));
    }
}
