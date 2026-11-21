//! The string forms that are names: a hostname, an email address, a host with a port, and the
//! identifiers validate.proto states as fixed patterns: UUID, trimmed UUID, ULID, a Protobuf
//! name and an HTTP header's name and value (validate.proto, StringRules).
const std = @import("std");
const constants = @import("constants.zig");
const format_ip = @import("format_ip.zig");

/// validate.proto, StringRules.hostname: labels separated by dots, each of 1 to 63 letters,
/// digits and hyphens, with no hyphen first or last; the last label not digits alone; an
/// optional trailing dot; and at most 253 characters without that dot.
pub fn is_hostname(value: []const u8) bool {
    const name = if (std.mem.endsWith(u8, value, ".")) value[0 .. value.len - 1] else value;
    if (name.len > constants.hostname_len_max) return false;
    var labels = std.mem.splitScalar(u8, name, '.');
    var last: []const u8 = "";
    while (labels.next()) |label| {
        if (!is_label(label)) return false;
        last = label;
    }
    // "The right-most label must not be digits only."
    return !all_digits(last);
}

/// A label of a hostname: 1 to 63 letters, digits and hyphens, with no hyphen first or last.
fn is_label(label: []const u8) bool {
    if (label.len == 0 or label.len > constants.hostname_label_len_max) return false;
    if (label[0] == '-' or label[label.len - 1] == '-') return false;
    for (label) |octet| {
        if (!std.ascii.isAlphanumeric(octet) and octet != '-') return false;
    }
    return true;
}

fn all_digits(text: []const u8) bool {
    for (text) |octet| {
        if (!std.ascii.isDigit(octet)) return false;
    }
    return true;
}

/// validate.proto, StringRules.email: "the definition for a valid email address from the HTML
/// standard": one or more characters of atext or ".", then "@", then labels separated by dots,
/// each as a hostname's (https://html.spec.whatwg.org/multipage/input.html#valid-e-mail-address).
pub fn is_email(value: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, value, '@') orelse return false;
    const local = value[0..at];
    if (local.len == 0) return false;
    for (local) |octet| {
        if (!is_email_local(octet)) return false;
    }
    // An empty domain is one empty label, which `is_label` refuses.
    var labels = std.mem.splitScalar(u8, value[at + 1 ..], '.');
    while (labels.next()) |label| {
        if (!is_label(label)) return false;
    }
    return true;
}

/// The HTML standard's characters before the "@": RFC 5322's atext, and ".".
fn is_email_local(octet: u8) bool {
    return std.ascii.isAlphanumeric(octet) or std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", octet) != null;
}

/// validate.proto, StringRules.host_and_port: a hostname, an IPv4 address or an IPv6 address
/// in square brackets, then ":" and a port: "a decimal number in the range of 0-65535". Without
/// `port_required` the port may be absent.
pub fn is_host_and_port(value: []const u8, port_required: bool) bool {
    if (value.len == 0) return false;
    if (value[0] == '[') {
        const close = std.mem.lastIndexOfScalar(u8, value, ']') orelse return false;
        if (!format_ip.is_ip(value[1..close], .v6)) return false;
        const rest = value[close + 1 ..];
        if (rest.len == 0) return !port_required;
        return rest[0] == ':' and is_port(rest[1..]);
    }
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return !port_required and is_host(value);
    return is_host(value[0..colon]) and is_port(value[colon + 1 ..]);
}

fn is_host(value: []const u8) bool {
    return is_hostname(value) or format_ip.is_ip(value, .v4);
}

/// A port: decimal digits with no leading zero, at most 65535.
fn is_port(text: []const u8) bool {
    if (text.len == 0 or text.len > constants.port_digits_max) return false;
    if (text.len > 1 and text[0] == '0') return false;
    var port: u32 = 0;
    for (text) |octet| {
        if (!std.ascii.isDigit(octet)) return false;
        port = port * constants.decimal_base + (octet - '0');
    }
    return port <= std.math.maxInt(u16);
}

/// validate.proto, string.uuid: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-
/// [0-9a-fA-F]{12}$".
pub fn is_uuid(value: []const u8) bool {
    if (value.len != constants.uuid_text_len) return false;
    for (value, 0..) |octet, index| {
        const hyphen = std.mem.indexOfScalar(usize, &constants.uuid_hyphens, index) != null;
        if (hyphen and octet != '-') return false;
        if (!hyphen and !std.ascii.isHex(octet)) return false;
    }
    return true;
}

/// validate.proto, string.tuuid: "^[0-9a-fA-F]{32}$".
pub fn is_tuuid(value: []const u8) bool {
    if (value.len != constants.tuuid_text_len) return false;
    for (value) |octet| {
        if (!std.ascii.isHex(octet)) return false;
    }
    return true;
}

/// validate.proto, string.ulid: "^[0-7][0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{25}$".
pub fn is_ulid(value: []const u8) bool {
    if (value.len != constants.ulid_text_len) return false;
    if (value[0] < '0' or value[0] > '7') return false;
    for (value[1..]) |octet| {
        const upper = std.ascii.toUpper(octet);
        // Crockford's base 32 leaves out I, L, O and U.
        if (!std.ascii.isAlphanumeric(octet) or std.mem.indexOfScalar(u8, "ILOU", upper) != null) return false;
    }
    return true;
}

/// validate.proto, string.protobuf_fqn: "^[A-Za-z_][A-Za-z_0-9]*(\.[A-Za-z_][A-Za-z_0-9]*)*$".
pub fn is_protobuf_fqn(value: []const u8) bool {
    // An empty name is one empty part, which the loop refuses.
    var parts = std.mem.splitScalar(u8, value, '.');
    while (parts.next()) |part| {
        if (part.len == 0 or std.ascii.isDigit(part[0])) return false;
        for (part) |octet| {
            if (!std.ascii.isAlphanumeric(octet) and octet != '_') return false;
        }
    }
    return true;
}

/// validate.proto, string.protobuf_dot_fqn: a Protobuf name after a leading dot.
pub fn is_protobuf_dot_fqn(value: []const u8) bool {
    return value.len > 1 and value[0] == '.' and is_protobuf_fqn(value[1..]);
}

/// validate.proto, string.well_known_regex.header_name: "^:?[0-9a-zA-Z!#$%&'*+-.^_|~\x60]+$"
/// when strict, where "+-." names "+", ",", "-" and "."; else "^[^\u0000\u000A\u000D]+$".
pub fn is_header_name(value: []const u8, strict: bool) bool {
    if (!strict) return value.len != 0 and is_loose_header(value);
    const name = if (value.len != 0 and value[0] == ':') value[1..] else value;
    if (name.len == 0) return false;
    for (name) |octet| {
        if (!std.ascii.isAlphanumeric(octet) and std.mem.indexOfScalar(u8, "!#$%&'*+,-.^_|~`", octet) == null) return false;
    }
    return true;
}

/// validate.proto, string.well_known_regex.header_value:
/// "^[^\u0000-\u0008\u000A-\u001F\u007F]*$" when strict; else "^[^\u0000\u000A\u000D]*$".
pub fn is_header_value(value: []const u8, strict: bool) bool {
    if (!strict) return is_loose_header(value);
    for (value) |octet| {
        // Every control character but the tab, and DEL.
        if ((std.ascii.isControl(octet) and octet != '\t')) return false;
    }
    return true;
}

/// No NUL, no line feed and no carriage return.
fn is_loose_header(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\x00\n\r") == null;
}

const testing = std.testing;

test "a hostname is labels of letters, digits and inner hyphens, the last not digits alone" {
    for ([_][]const u8{ "example.com", "A.ISI.EDU", "SRI-NIC.ARPA", "a.", "a-b.a--b", "com1", "0.1.2.com", "0a.9a" }) |name| try testing.expect(is_hostname(name));
    for ([_][]const u8{ "", ".", "..", ".a", "a..b", "-a", "a-", "a.1", "1", "foo_bar.com", " example.com", "example.com ", "你好.com", "İ" }) |name| try testing.expect(!is_hostname(name));
    const label_63 = "a" ** 63;
    try testing.expect(is_hostname(label_63 ++ ".com"));
    try testing.expect(!is_hostname(label_63 ++ "a.com"));
    // 253 characters pass, with a trailing dot too, and 254 do not.
    const name_253 = ("123456789." ** 25) ++ "abc";
    try testing.expectEqual(@as(usize, 253), name_253.len);
    try testing.expect(is_hostname(name_253));
    try testing.expect(is_hostname(name_253 ++ "."));
    try testing.expect(!is_hostname(name_253 ++ "d"));
}

test "an email address is the HTML standard's: atext and dots, an at sign, then labels" {
    for ([_][]const u8{ "foo@example.com", "foo+x@example.com", "foo@example", ".@example.com", "...@example.com", "foo@a-b.a--b", "foo@0.1.2", "a!#$%&'*+-/=?^_`{|}~@b" }) |address| try testing.expect(is_email(address));
    for ([_][]const u8{ "", "example.com", "@example.com", "foo@", "foo@example.com.", "foo@.a", "foo@-a", "foo@a-", " foo@example.com", "foo@example.com ", "foo @example.com", "foobar@example.com\n", "µ@example.com", "foo@你好.com", "\"foo bar\"@example.com", "a@b@c", "postmaster@[123.123.123.123]", "John Doe <john@example.com>" }) |address| try testing.expect(!is_email(address));
    try testing.expect(is_email("foo@" ++ "a" ** 63 ++ ".com"));
    try testing.expect(!is_email("foo@" ++ "a" ** 64 ++ ".com"));
}

test "a host and port is a name or an address, with a port of 0 to 65535 and no leading zero" {
    for ([_][]const u8{ "example.com:8080", "example.com:0", "example.com:65535", "192.168.0.1:0", "[::1]:8080", "[::1%foo]:1", "a.:1" }) |pair| try testing.expect(is_host_and_port(pair, true));
    for ([_][]const u8{ "", "example.com", "example.com:", "example.com:00", "example.com:080", "example.com:+0", "example.com:0xFA", "example.com:65536", "192.168.0.1", "[::1]", "[::1]:", "[::1]:65536", "[::1]8080", "[::1]x80", " example.com:1", "example.com:8a", "example.com:a", "example.com:99999999999" }) |pair| try testing.expect(!is_host_and_port(pair, true));
    for ([_][]const u8{ "example.com", "a.", "192.168.0.1", "255.255.255.255", "[::1]", "[::1%foo]", "[::0%00]]", "[0:0:0:0:0:ffff:192.1.56.10]", "example.com:65535", "192.168.0.1:8080" }) |pair| try testing.expect(is_host_and_port(pair, false));
    for ([_][]const u8{ "", "example.com:", "example.com:65536", "256.0.0.0", "127.0.0", "127..0.1", "[::1%]", "[127.0.0.1]", "[example.com]", "192.168.0.1:", "你好.com", "[::1" }) |pair| try testing.expect(!is_host_and_port(pair, false));
}

test "the identifiers match validate.proto's patterns and nothing longer or shorter" {
    try testing.expect(is_uuid("8b72987b-024a-43b3-b4cf-647a1f925c5d"));
    try testing.expect(is_uuid("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"));
    for ([_][]const u8{ "", "8b72987b024a43b3b4cf647a1f925c5d", "8b72987b-024a-43b3-b4cf-647a1f925c5", "8b72987b-024a-43b3-b4cf-647a1f925c5dd", "8b72987b-024a-43b3-b4cf-647a1f925c5g", "8b72987b0024a-43b3-b4cf-647a1f925c5d", "8b72987b-024a-43b3-b4cf-647a1f925-5d" }) |text| try testing.expect(!is_uuid(text));
    try testing.expect(is_tuuid("8b72987b024a43b3b4cf647a1f925c5d"));
    for ([_][]const u8{ "", "8b72987b-024a-43b3-b4cf-647a1f925c5d", "8b72987b024a43b3b4cf647a1f925c5", "8b72987b024a43b3b4cf647a1f925c5dd", "8b72987b024a43b3b4cf647a1f925c5g" }) |text| try testing.expect(!is_tuuid(text));
    try testing.expect(is_ulid("01ARZ3NDEKTSV4RRFFQ69G5FAV"));
    try testing.expect(is_ulid("7zzzzzzzzzzzzzzzzzzzzzzzzz"));
    for ([_][]const u8{ "", "81ARZ3NDEKTSV4RRFFQ69G5FAV", "01ARZ3NDEKTSV4RRFFQ69G5FA", "01ARZ3NDEKTSV4RRFFQ69G5FAVV", "01ARZ3NDEKTSV4RRFFQ69G5FAI", "01ARZ3NDEKTSV4RRFFQ69G5FAL", "01ARZ3NDEKTSV4RRFFQ69G5FAO", "01ARZ3NDEKTSV4RRFFQ69G5FAu", "01ARZ3NDEKTSV4RRFFQ69G5FA-" }) |text| try testing.expect(!is_ulid(text));
    for ([_][]const u8{ "a", "_", "foo.Bar_9", "a.b.c" }) |text| try testing.expect(is_protobuf_fqn(text));
    for ([_][]const u8{ "", ".a", "a.", "a..b", "9a", "a.9", "a-b", "a b" }) |text| try testing.expect(!is_protobuf_fqn(text));
    try testing.expect(is_protobuf_dot_fqn(".a.b"));
    for ([_][]const u8{ "", ".", "a.b", "xa.b", "..a", ".a." }) |text| try testing.expect(!is_protobuf_dot_fqn(text));
}

test "an HTTP header's name and value follow the strict pattern or the loose one" {
    for ([_][]const u8{ "content-type", ":path", "X_1", "a!#$%&'*+,-.^_|~`" }) |name| try testing.expect(is_header_name(name, true));
    for ([_][]const u8{ "", ":", "a b", "a:b", "::a", "a\x00", "a/b", "é" }) |name| try testing.expect(!is_header_name(name, true));
    for ([_][]const u8{ "a b", "a:b", "é", "\t" }) |name| try testing.expect(is_header_name(name, false));
    for ([_][]const u8{ "", "a\x00", "a\nb", "a\rb" }) |name| try testing.expect(!is_header_name(name, false));
    for ([_][]const u8{ "", "a b", "a\tb", "é" }) |value| try testing.expect(is_header_value(value, true));
    for ([_][]const u8{ "a\x00", "a\nb", "a\x08", "a\x1f", "a\x7f" }) |value| try testing.expect(!is_header_value(value, true));
    for ([_][]const u8{ "", "a\x08", "a\x7f" }) |value| try testing.expect(is_header_value(value, false));
    for ([_][]const u8{ "a\x00", "a\n", "\r" }) |value| try testing.expect(!is_header_value(value, false));
}
