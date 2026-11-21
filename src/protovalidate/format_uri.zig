//! A URI and a URI reference as RFC 3986 states them (validate.proto, StringRules.uri and
//! uri_ref), with a zone identifier in an IPv6 literal as RFC 6874 states it.
//!
//! The text is split as RFC 3986 Appendix B splits it, at the first "#", then the first "?",
//! and each part is then checked against the rule of §3 that names it.
const std = @import("std");
const octet_class = @import("octet_class.zig");
const constants = @import("constants.zig");
const format_ip = @import("format_ip.zig");

/// RFC 3986 §3: URI = scheme ":" hier-part [ "?" query ] [ "#" fragment ].
pub fn is_uri(text: []const u8) bool {
    const main = without_query_and_fragment(text) orelse return false;
    const colon = std.mem.indexOfScalar(u8, main, ':') orelse return false;
    return is_scheme(main[0..colon]) and is_hier_part(main[colon + 1 ..], .any);
}

/// RFC 3986 §4.1: URI-reference = URI / relative-ref, where §4.2 states relative-ref =
/// relative-part [ "?" query ] [ "#" fragment ].
pub fn is_uri_ref(text: []const u8) bool {
    if (is_uri(text)) return true;
    const main = without_query_and_fragment(text) orelse return false;
    return is_hier_part(main, .no_scheme);
}

/// The text before its query and its fragment, or null when either is not well formed.
fn without_query_and_fragment(text: []const u8) ?[]const u8 {
    var main = text;
    if (std.mem.indexOfScalar(u8, main, '#')) |hash| {
        // RFC 3986 §3.5: fragment = *( pchar / "/" / "?" ).
        if (!is_part(main[hash + 1 ..], .query)) return null;
        main = main[0..hash];
    }
    if (std.mem.indexOfScalar(u8, main, '?')) |mark| {
        // RFC 3986 §3.4: query = *( pchar / "/" / "?" ).
        if (!is_part(main[mark + 1 ..], .query)) return null;
        main = main[0..mark];
    }
    return main;
}

/// RFC 3986 §3.1: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ).
fn is_scheme(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..]) |octet| {
        if (!octet_class.has(octet_class.alphanumeric ++ "+-.", octet)) return false;
    }
    return true;
}

/// Which first segment a path with no authority takes.
const First = enum {
    /// hier-part: path-absolute, path-rootless or path-empty.
    any,
    /// relative-part: path-absolute, path-noscheme or path-empty. RFC 3986 §3.3: the first
    /// segment of path-noscheme holds no ":".
    no_scheme,
};

/// RFC 3986 §3: hier-part = "//" authority path-abempty / path-absolute / path-rootless /
/// path-empty, and §4.2: relative-part, the same with path-noscheme for path-rootless.
fn is_hier_part(text: []const u8, first: First) bool {
    const authority_mark = "//";
    if (std.mem.startsWith(u8, text, authority_mark)) {
        const rest = text[authority_mark.len..];
        const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        // RFC 3986 §3.3: path-abempty = *( "/" segment ).
        return is_authority(rest[0..path_start]) and is_part(rest[path_start..], .path);
    }
    if (first == .no_scheme) {
        const segment_end = std.mem.indexOfScalar(u8, text, '/') orelse text.len;
        if (std.mem.indexOfScalar(u8, text[0..segment_end], ':') != null) return false;
    }
    return is_part(text, .path);
}

/// RFC 3986 §3.2: authority = [ userinfo "@" ] host [ ":" port ].
fn is_authority(text: []const u8) bool {
    var rest = text;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        // RFC 3986 §3.2.1: userinfo = *( unreserved / pct-encoded / sub-delims / ":" ).
        if (!is_part(rest[0..at], .userinfo)) return false;
        rest = rest[at + 1 ..];
    }
    if (std.mem.startsWith(u8, rest, "[")) {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return false;
        if (!is_ip_literal(rest[1..close])) return false;
        const after = rest[close + 1 ..];
        return after.len == 0 or (after[0] == ':' and is_port(after[1..]));
    }
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return is_reg_name(rest);
    return is_reg_name(rest[0..colon]) and is_port(rest[colon + 1 ..]);
}

/// RFC 3986 §3.2.3: port = *DIGIT.
fn is_port(text: []const u8) bool {
    for (text) |octet| {
        if (!std.ascii.isDigit(octet)) return false;
    }
    return true;
}

/// RFC 3986 §3.2.2: IP-literal = "[" ( IPv6address / IPvFuture ) "]", and RFC 6874 §2:
/// IPv6addrz = IPv6address "%25" ZoneID, ZoneID = 1*( unreserved / pct-encoded ). `text` is
/// what lies between the brackets.
fn is_ip_literal(text: []const u8) bool {
    if (text.len != 0 and text[0] == 'v') return is_ip_future(text[1..]);
    const percent = std.mem.indexOfScalar(u8, text, '%') orelse return format_ip.parse_ipv6(text) != null;
    const zone_mark = "%25";
    if (!std.mem.startsWith(u8, text[percent..], zone_mark)) return false;
    const zone = text[percent + zone_mark.len ..];
    return zone.len != 0 and is_part(zone, .zone) and decodes_to_utf8(zone) and format_ip.parse_ipv6(text[0..percent]) != null;
}

/// RFC 3986 §3.2.2: IPvFuture = "v" 1*HEXDIG "." 1*( unreserved / sub-delims / ":" ). `text`
/// is what follows the "v".
fn is_ip_future(text: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return false;
    if (dot == 0 or dot + 1 == text.len) return false;
    for (text[0..dot]) |octet| {
        if (!std.ascii.isHex(octet)) return false;
    }
    for (text[dot + 1 ..]) |octet| {
        if (!is_unreserved(octet) and !is_sub_delim(octet) and octet != ':') return false;
    }
    return true;
}

/// RFC 3986 §3.2.2: reg-name = *( unreserved / pct-encoded / sub-delims ), whose octets "should
/// be" UTF-8 once decoded: protovalidate refuses a name that is not. An IPv4address is a
/// reg-name too.
fn is_reg_name(text: []const u8) bool {
    return is_part(text, .reg_name) and decodes_to_utf8(text);
}

/// The parts of a URI that are runs of characters, by the characters each takes beside
/// unreserved, pct-encoded and sub-delims.
const Part = enum {
    /// RFC 3986 §3.2.2, reg-name: none.
    reg_name,
    /// RFC 6874 §2, ZoneID: none, and no sub-delims.
    zone,
    /// RFC 3986 §3.2.1, userinfo: ":".
    userinfo,
    /// RFC 3986 §3.3, a path: pchar, ":" and "@", and "/" between segments.
    path,
    /// RFC 3986 §3.4 and §3.5, query and fragment: pchar, "/" and "?".
    query,

    fn takes(part: Part, octet: u8) bool {
        if (is_unreserved(octet)) return true;
        if (part == .zone) return false;
        if (is_sub_delim(octet)) return true;
        return switch (part) {
            .reg_name, .zone => false,
            .userinfo => octet == ':',
            .path => octet == ':' or octet == '@' or octet == '/',
            .query => octet == ':' or octet == '@' or octet == '/' or octet == '?',
        };
    }
};

/// Whether each octet of `text` is one `part` takes, or starts a pct-encoded octet (RFC 3986
/// §2.1: pct-encoded = "%" HEXDIG HEXDIG).
fn is_part(text: []const u8, part: Part) bool {
    var rest = text;
    for (0..text.len) |_| {
        if (rest.len == 0) return true;
        rest = rest[taken_len(rest, part) orelse return false ..];
    }
    return rest.len == 0;
}

/// The octets of what `text` starts with: one that `part` takes, or the three of a pct-encoded
/// octet. Null when it starts with neither.
fn taken_len(text: []const u8, part: Part) ?usize {
    if (text[0] != '%') return if (part.takes(text[0])) 1 else null;
    if (text.len <= constants.pct_encoded_digits) return null;
    for (text[1..][0..constants.pct_encoded_digits]) |digit| {
        if (!std.ascii.isHex(digit)) return null;
    }
    return constants.pct_encoded_digits + 1;
}

/// RFC 3986 §2.3: unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~".
fn is_unreserved(octet: u8) bool {
    return octet_class.has(octet_class.alphanumeric ++ "-._~", octet);
}

/// RFC 3986 §2.2: sub-delims = "!" / "$" / "&" / "'" / "(" / ")" / "*" / "+" / "," / ";" / "=".
fn is_sub_delim(octet: u8) bool {
    return octet_class.has("!$&'()*+,;=", octet);
}

/// Whether `text`, whose pct-encoded octets are well formed, is UTF-8 once they are decoded.
/// It decodes one octet at a time into a sequence of at most four, so it keeps no copy.
fn decodes_to_utf8(text: []const u8) bool {
    var sequence: Sequence = .{};
    var rest = text;
    for (0..text.len) |_| {
        if (rest.len == 0) break;
        const encoded = rest[0] == '%';
        const octet = if (encoded) std.fmt.parseInt(u8, rest[1..][0..constants.pct_encoded_digits], constants.hexadecimal_base) catch unreachable else rest[0];
        rest = rest[if (encoded) constants.pct_encoded_digits + 1 else 1..];
        if (!sequence.take(octet)) return false;
    }
    // A sequence the text ends inside of is not whole.
    return sequence.held == 0;
}

/// The octets of one UTF-8 sequence as they arrive.
const Sequence = struct {
    octets: [constants.utf8_sequence_len_max]u8 = @splat(0),
    held: usize = 0,
    wanted: usize = 0,

    /// Takes the next octet. Returns false when it starts no sequence, or ends one that is not
    /// well formed (RFC 3629 §3).
    fn take(sequence: *Sequence, octet: u8) bool {
        if (sequence.held == 0) sequence.wanted = std.unicode.utf8ByteSequenceLength(octet) catch return false;
        sequence.octets[sequence.held] = octet;
        sequence.held += 1;
        if (sequence.held < sequence.wanted) return true;
        _ = std.unicode.utf8Decode(sequence.octets[0..sequence.held]) catch return false;
        sequence.held = 0;
        return true;
    }
};

const testing = std.testing;

test "a URI is a scheme, a colon and the rest, each part of its own characters" {
    for ([_][]const u8{
        "https://example.com",         "https://example.com/foo/bar?baz=quux#frag", "https://joe@example.com/foo",  "ftp://example.com",
        "foo0123456789azAZ+-.://a",    "https://user:password@example.com",         "https://:::@example.com",      "https:///@example.com",
        "https://?@example.com",       "https://#@example.com",                     "https://:8080",                "https://:",
        "https://example.com:",        "https://example.com:65536",                 "https://256.0.0.1",            "foo:/nz//segment//segment/",
        "foo:nz",                      "foo:",                                      "foo:?q#f",                     "A://",
        "https://example.com?/?",      "https://example.com#/?",                    "https://%c3x%963@example.com", "foo:/%c3x%96",
        "https://example.com?%c3x%96", "https://foo%c3%96",
    }) |uri| try testing.expect(is_uri(uri));
    for ([_][]const u8{
        "",                       " ",                       " https://example.com",  "https://example.com ",  "./",                       "//example.com/foo",
        "1foo://example.com",     "-foo://example.com",      ":foo://example.com",    "foo%20bar://a",         "foo^bar://example.com",    "https://[@example.com",
        "https://@@example.com",  "https://%@example.com",   "https://%2x@a",         "https://^@example.com", "https://foo%",             "https://foo%2x",
        "https://foo%c3x%96",     "https://\x1f.com",        "https://^.com",
        "https://foo@你好.com",
        "https://example.com:8a", "https://example.com: 1",  "https://^:80",          "foo:/^",                "foo:/%x",                  "foo:nz/\x1f",
        "https://example.com?^",  "https://example.com?%2x", "https://example.com##", "https://example.com#%", "https://example.com#\x1f", "https://foo%c3",
    }) |uri| try testing.expect(!is_uri(uri));
}

test "a URI's host in brackets is an IPv6 address, with a zone after %25, or an IPvFuture" {
    for ([_][]const u8{ "https://[2001:0db8:85a3:0000:0000:8a2e:0370:7334]", "https://[::1]:8080", "https://[::1%25eth0]", "https://[::1%25foo%61%20%23]", "https://[::1%25foo%c3%96]", "https://[v1.x]", "https://[v1234AF.x]", "https://[vF.-!$&'()*+,;=._~:aZ9]" }) |uri| try testing.expect(is_uri(uri));
    for ([_][]const u8{ "https://2001:0db8:85a3:0000:0000:8a2e:0370:7334", "https://[2001::0370::7334]", "https://[v1x]", "https://[v.x]", "https://[v1.]", "https://[vg.x]", "https://[v1.^]", "https://[::1%25]", "https://[::1%eth0]", "https://[::1%25foo%]", "https://[::1%25foo%2x]", "https://[::1%25foo%c3x%96]", "https://[::1%25a!]", "https://[::1", "https://[::1]x", "https://[::1]x80", "https://[127.0.0.1]", "https://[xyz%25eth0]" }) |uri| try testing.expect(!is_uri(uri));
}

test "a URI reference is a URI, or a relative reference whose first segment holds no colon" {
    for ([_][]const u8{ "", "./foo", "./foo/bar?baz=quux#frag", "//host", "//host/foo?baz=quux#frag", "//host//", "//host:8080", "//[::1]", "/", "/nz", "/:", "*", ".///", ".?baz=quux", ".#frag", "%c3x%96", "https://example.com", "a/b:c" }) |reference| try testing.expect(is_uri_ref(reference));
    for ([_][]const u8{ " ", " ./foo", "./foo ", ":", "1foo://example.com", "//host/\x1f", "//host/%x", "//host##", "//host?^", "/^", "/#%", "^", "%x", "./^", ".##", "?\x1f", "a:b^" }) |reference| try testing.expect(!is_uri_ref(reference));
}

test "pct-encoded octets of a host decode to whole UTF-8 sequences" {
    try testing.expect(decodes_to_utf8("") and decodes_to_utf8("abc") and decodes_to_utf8("%c3%96") and decodes_to_utf8("a%e4%bd%a0b") and decodes_to_utf8("%f0%9f%98%80"));
    try testing.expect(!decodes_to_utf8("%c3x%96") and !decodes_to_utf8("%c3") and !decodes_to_utf8("%96") and !decodes_to_utf8("%ff") and !decodes_to_utf8("%ed%a0%80") and !decodes_to_utf8("%c0%80"));
}
