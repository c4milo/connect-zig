//! The claims the verifier reads from a token's payload (RFC 7519 §4.1).
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const reader_file = @import("reader.zig");
const Reader = reader_file.Reader;

pub const Error = error{Malformed};

/// What a verified token states. The slices point into the verifier, and stay valid until its
/// next `verify`.
pub const Claims = struct {
    /// "sub" (RFC 7519 §4.1.2): whom the token is about. Empty when the token names no one.
    subject: []const u8,
    /// "iss" (RFC 7519 §4.1.1): the verifier's issuer, which the token's equals.
    issuer: []const u8,
    /// "exp" (RFC 7519 §4.1.4), in whole seconds since 1970-01-01T00:00:00Z.
    expires_unix_seconds: i64,
    /// The JWT Claims Set as the token carries it (RFC 7519 §3): the JSON text of one object. A
    /// program reads its own claims from it.
    payload: []const u8,
};

/// A NumericDate (RFC 7519 §2): seconds since 1970-01-01T00:00:00Z, which may hold a part of a
/// second.
pub const NumericDate = struct {
    seconds: i64,
    /// Whether a part of a second follows the whole seconds.
    fraction: bool,

    /// The first whole second at or after the date. A clock in whole seconds is before the date
    /// while it is below this second, and at or after the date from it on.
    pub fn ceiling(date: NumericDate) i64 {
        return date.seconds + @intFromBool(date.fraction);
    }
};

/// The issuer and the audience a token must name.
pub const Expected = struct { issuer: []const u8, audience: []const u8 };

/// What `read` found in a payload.
pub const Found = struct {
    issuer_matches: bool,
    audience_matches: bool,
    subject: []const u8,
    expires: NumericDate,
    not_before: ?NumericDate,
};

/// The claims the verifier reads. A claim outside this list passes unread.
const Name = enum { iss, sub, aud, exp, nbf };

/// Reads the claims from `reader`, whose text is the token's second part after its base64url
/// decoding. The octets of "sub" go to `subject_storage`.
pub fn read(reader: *Reader, expected: *const Expected, subject_storage: *[constants.subject_bytes_max]u8) Error!Found {
    // RFC 7519 §3: the JWT Claims Set is a JSON object.
    try reader.expect(.begin_object);
    var issuer_matches = false;
    var audience_matches = false;
    var subject: []const u8 = "";
    var expires: ?NumericDate = null;
    var not_before: ?NumericDate = null;
    var members: reader_file.Members(Name) = .{ .reader = reader };
    // Bounded: each member takes at least one octet of the input.
    for (0..reader.input.len + 1) |_| {
        const name = try members.next() orelse break;
        switch (name) {
            // RFC 7519 §4.1.1: "iss" is a string. OpenID Connect Core 1.0 §3.1.3.7 rule 2: it
            // MUST exactly match the issuer, so the octets are compared as they are.
            .iss => issuer_matches = std.mem.eql(u8, try reader.string(), expected.issuer),
            .sub => subject = try subject_of(reader, subject_storage),
            .aud => audience_matches = try holds(reader, expected.audience),
            .exp => expires = try numeric_date(reader),
            .nbf => not_before = try numeric_date(reader),
        }
    } else unreachable;
    try reader.expect(.end);
    return .{
        .issuer_matches = issuer_matches,
        .audience_matches = audience_matches,
        .subject = subject,
        // A bearer token with no "exp" never ends, so the verifier requires one, as OpenID
        // Connect Core 1.0 §2 and RFC 9068 §2.2 do.
        .expires = expires orelse return error.Malformed,
        .not_before = not_before,
    };
}

/// RFC 7519 §4.1.2: "sub" is a string. OpenID Connect Core 1.0 §2 holds it to 255 characters.
fn subject_of(reader: *Reader, storage: *[constants.subject_bytes_max]u8) Error![]const u8 {
    const octets = try reader.string();
    if (octets.len > storage.len) return error.Malformed;
    @memcpy(storage[0..octets.len], octets);
    return storage[0..octets.len];
}

/// RFC 7519 §4.1.3: "aud" is an array of strings, or one string. The token is for the audience
/// when one of them equals it.
fn holds(reader: *Reader, audience: []const u8) Error!bool {
    switch (try reader.next()) {
        .string => |octets| return std.mem.eql(u8, octets, audience),
        .begin_array => {},
        else => return error.Malformed,
    }
    var found = false;
    // Bounded: each element takes at least one octet of the input.
    for (0..reader.input.len + 1) |_| {
        switch (try reader.next()) {
            .end_array => return found,
            .string => |octets| found = found or std.mem.eql(u8, octets, audience),
            else => return error.Malformed,
        }
    }
    unreachable;
}

/// RFC 7519 §4.1.4 and §4.1.5: "exp" and "nbf" are numbers that hold a NumericDate.
fn numeric_date(reader: *Reader) Error!NumericDate {
    return switch (try reader.next()) {
        .number => |text| parse_numeric_date(text),
        else => error.Malformed,
    };
}

const decimal_base = 10;

/// Reads a JSON number (RFC 8259 §6) as a NumericDate: digits, then an optional '.' and digits.
/// A date before 1970, one with an exponent and one of more than `numeric_date_digits_max`
/// digits are refused: no issuer writes them.
pub fn parse_numeric_date(text: []const u8) Error!NumericDate {
    var seconds: i64 = 0;
    var whole_len: usize = 0;
    for (text) |octet| {
        if (!std.ascii.isDigit(octet)) break;
        if (whole_len == constants.numeric_date_digits_max) return error.Malformed;
        seconds = seconds * decimal_base + (octet - '0');
        whole_len += 1;
    }
    // A number that starts with no digit starts with '-'.
    if (whole_len == 0) return error.Malformed;
    const rest = text[whole_len..];
    if (rest.len == 0) return .{ .seconds = seconds, .fraction = false };
    // What follows the digits is a fraction, or an exponent.
    if (rest[0] != '.') return error.Malformed;
    var fraction = false;
    for (rest[1..]) |octet| {
        if (!std.ascii.isDigit(octet)) return error.Malformed;
        fraction = fraction or octet != '0';
    }
    return .{ .seconds = seconds, .fraction = fraction };
}
