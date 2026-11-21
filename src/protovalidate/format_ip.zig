//! IP addresses and prefixes as text (validate.proto, StringRules.ip to ipv6_prefix): an IPv4
//! address in dotted decimal and an IPv6 address in its text form, "well-defined in the
//! internet standard RFC 3986", with a zone identifier after "%" for IPv6.
const std = @import("std");
const octet_search = @import("octet_search.zig");
const constants = @import("constants.zig");

/// The versions a rule asks for: CEL's `isIp()` and `isIp(0)` take either.
pub const Version = enum { any, v4, v6 };

/// RFC 3986 §3.2.2, IPv4address: four dec-octets separated by dots, each 0 to 255 with no
/// leading zero. Returns the address, most significant octet first.
pub fn parse_ipv4(text: []const u8) ?u32 {
    var address: u32 = 0;
    var parts = octet_search.split(text, '.');
    for (0..constants.ipv4_len) |_| {
        const octet = parse_dec_octet(parts.next() orelse return null) orelse return null;
        address = address << @bitSizeOf(u8) | octet;
    }
    if (parts.next() != null) return null;
    return address;
}

/// RFC 3986 §3.2.2, dec-octet: "0", or one to three digits that start with 1 to 9, at most 255.
fn parse_dec_octet(part: []const u8) ?u8 {
    if (part.len == 0 or part.len > constants.dec_octet_digits_max) return null;
    if (part.len > 1 and part[0] == '0') return null;
    var octet: u32 = 0;
    for (part) |digit| {
        if (!std.ascii.isDigit(digit)) return null;
        octet = octet * constants.decimal_base + (digit - '0');
    }
    return if (octet <= std.math.maxInt(u8)) @intCast(octet) else null;
}

/// The groups of an IPv6 address as its text gives them: those before "::" and those after.
const Groups = struct {
    values: [constants.ipv6_groups]u16 = @splat(0),
    count: usize = 0,
    /// The count of groups before "::", or null when the text holds none.
    elided_at: ?usize = null,

    fn add(groups: *Groups, value: u16) bool {
        if (groups.count == constants.ipv6_groups) return false;
        groups.values[groups.count] = value;
        groups.count += 1;
        return true;
    }

    /// The address: the groups before "::", zeros, then the groups after.
    fn address(groups: *const Groups) ?u128 {
        // RFC 3986 §3.2.2: "::" stands for one group of zeros or more, and an address without
        // it holds all eight.
        const elided = groups.elided_at orelse return if (groups.count == constants.ipv6_groups) groups.join(groups.count) else null;
        if (groups.count == constants.ipv6_groups) return null;
        return groups.join(elided);
    }

    fn join(groups: *const Groups, leading: usize) u128 {
        var result: u128 = 0;
        const trailing = groups.count - leading;
        for (0..constants.ipv6_groups) |index| {
            const value: u16 = if (index < leading) groups.values[index] else if (index >= constants.ipv6_groups - trailing) groups.values[index - (constants.ipv6_groups - groups.count)] else 0;
            result = result << @bitSizeOf(u16) | value;
        }
        return result;
    }
};

/// What stands for one group of zeros or more in an IPv6 address (RFC 3986 §3.2.2).
const elision = "::";

/// RFC 3986 §3.2.2, IPv6address: groups of one to four hexadecimal digits separated by ":",
/// with at most one "::", and with the last two groups optionally as an IPv4 address.
pub fn parse_ipv6(text: []const u8) ?u128 {
    var groups: Groups = .{};
    var rest = text;
    if (std.mem.startsWith(u8, rest, elision)) {
        groups.elided_at = 0;
        rest = rest[elision.len..];
    }
    for (0..constants.ipv6_groups + 1) |_| {
        if (rest.len == 0) return groups.address();
        rest = next_group(&groups, rest) orelse return null;
    }
    return null;
}

/// Reads one group, or the IPv4 address that ends the text, and the separator after it. Returns
/// what follows, or null for text that is no address.
fn next_group(groups: *Groups, text: []const u8) ?[]const u8 {
    const end = octet_search.index_of(text, ':') orelse text.len;
    const part = text[0..end];
    if (octet_search.index_of(part, '.') != null) {
        // ls32: an IPv4 address takes the place of the last two groups, at the text's end. A
        // ":" after it starts an empty group, which the next read refuses.
        const ipv4 = parse_ipv4(part) orelse return null;
        if (!groups.add(@truncate(ipv4 >> @bitSizeOf(u16))) or !groups.add(@truncate(ipv4))) return null;
        return text[end..];
    }
    if (!groups.add(parse_h16(part) orelse return null)) return null;
    if (end == text.len) return text[end..];
    if (std.mem.startsWith(u8, text[end..], elision)) {
        if (groups.elided_at != null) return null;
        groups.elided_at = groups.count;
        return text[end + elision.len ..];
    }
    // A single ":" separates two groups, so a group follows it.
    if (end + 1 == text.len) return null;
    return text[end + 1 ..];
}

/// RFC 3986 §3.2.2, h16: one to four hexadecimal digits.
fn parse_h16(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > constants.h16_digits_max) return null;
    return std.fmt.parseInt(u16, text, constants.hexadecimal_base) catch null;
}

/// Whether `text` is an IP address of `version`. An IPv6 address may end with a zone
/// identifier: "%" and one character or more, none of them NUL (validate.proto,
/// StringRules.ip: "Zone identifiers for IPv6 addresses (for example, "fe80::a%en1") are
/// supported").
pub fn is_ip(text: []const u8, version: Version) bool {
    if (version != .v6 and parse_ipv4(text) != null) return true;
    if (version == .v4) return false;
    const percent = octet_search.index_of(text, '%') orelse return parse_ipv6(text) != null;
    const zone = text[percent + 1 ..];
    if (zone.len == 0 or octet_search.index_of(zone, 0) != null) return false;
    return parse_ipv6(text[0..percent]) != null;
}

/// Whether `text` is an IP address of `version`, "/" and a prefix length. With `strict` the
/// bits after the prefix are zero (validate.proto, StringRules.ip_prefix: "The prefix must have
/// all zeros for the unmasked bits"). A prefix takes no zone identifier.
pub fn is_ip_prefix(text: []const u8, version: Version, strict: bool) bool {
    const slash = octet_search.index_of(text, '/') orelse return false;
    const length = parse_prefix_len(text[slash + 1 ..]) orelse return false;
    const address = text[0..slash];
    if (version != .v6) {
        if (parse_ipv4(address)) |ipv4| return length <= @bitSizeOf(u32) and (!strict or host_bits(u32, ipv4, length) == 0);
    }
    if (version == .v4) return false;
    const ipv6 = parse_ipv6(address) orelse return false;
    return !strict or host_bits(u128, ipv6, length) == 0;
}

/// A prefix length: decimal digits with no leading zero, at most 128.
fn parse_prefix_len(text: []const u8) ?u8 {
    // An empty length is no number, which the parse refuses.
    if (text.len > constants.prefix_len_digits_max) return null;
    if (text.len > 1 and text[0] == '0') return null;
    const length = std.fmt.parseInt(u8, text, constants.decimal_base) catch return null;
    return if (length <= @bitSizeOf(u128)) length else null;
}

/// The bits of `address` after its first `prefix_len`.
fn host_bits(comptime Address: type, address: Address, prefix_len: u8) Address {
    if (prefix_len >= @bitSizeOf(Address)) return 0;
    const all: Address = std.math.maxInt(Address);
    return address & (all >> @intCast(prefix_len));
}

const testing = std.testing;

test "an IPv4 address is four decimal octets with no leading zero" {
    try testing.expectEqual(@as(?u32, 0xc0a80515), parse_ipv4("192.168.5.21"));
    try testing.expectEqual(@as(?u32, 0), parse_ipv4("0.0.0.0"));
    try testing.expectEqual(@as(?u32, 0xffffffff), parse_ipv4("255.255.255.255"));
    for ([_][]const u8{ "", "127.0.1", "127.0.1.", "127..0.1", "127.0.0.0.1", "256.0.0.0", "0x0.0.0.0", "01.0.0.0", "1.2.3.4 ", " 1.2.3.4", "1.2.3.-4", "1.2.3.1000", "1.2.3.a", "1.2.3.99999999999" }) |text| try testing.expect(parse_ipv4(text) == null);
}

test "an IPv6 address is eight groups, or fewer around one double colon" {
    try testing.expectEqual(@as(?u128, 1), parse_ipv6("::1"));
    try testing.expectEqual(@as(?u128, 0), parse_ipv6("::"));
    try testing.expectEqual(@as(?u128, 0x0001_0000_0000_0000_0000_0000_0000_0000), parse_ipv6("1::"));
    try testing.expectEqual(@as(?u128, 0x0001_0002_0003_0004_0005_0006_0007_0008), parse_ipv6("1:2:3:4:5:6:7:8"));
    try testing.expectEqual(@as(?u128, 0x2001_0db8_abcd_0012_0000_0000_0000_00f1), parse_ipv6("2001:0DB8:ABCD:0012::F1"));
    try testing.expectEqual(@as(?u128, 0x0001_0002_0000_0000_0000_0000_0007_0008), parse_ipv6("1:2::7:8"));
    try testing.expectEqual(@as(?u128, 0xffff_c001_380a), parse_ipv6("0:0:0:0:0:ffff:192.1.56.10"));
    try testing.expectEqual(@as(?u128, 0xffff_c001_0000), parse_ipv6("::ffff:192.1.0.0"));
    for ([_][]const u8{ "1:2:3:4:5:6:7::", "::1:2:3:4:5:6:7", "1:2:3:4:5:6::1", "0:00::000:0000" }) |text| try testing.expect(parse_ipv6(text) != null);
    for ([_][]const u8{ "", ":", ":2:3:4:5:6:7:8", "12345:2:3:4:5:6:7:8", "g:2:3:4:5:6:7:8", ":::1", "1::3:4::6:7:8", ":0::0", "0::0:", "::0000ffff", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8::", "::1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7::1", "1::1:2:3:4:5:6:7", "0:0:0:0:0:ffff:256.1.56.10", "0:0:0:0:0:ffff:192.1.56", "0:0:0:0:0:ffff:192.1.56.", "1:2:3:4:5:6:7:1.2.3.4", "1.2.3.4::", "::1.2.3.4:1" }) |text| try testing.expect(parse_ipv6(text) == null);
}

test "an IP address is of the version asked for, and an IPv6 one may name a zone" {
    try testing.expect(is_ip("127.0.0.1", .any) and is_ip("::1", .any));
    try testing.expect(is_ip("127.0.0.1", .v4) and !is_ip("::1", .v4));
    try testing.expect(is_ip("::1", .v6) and !is_ip("127.0.0.1", .v6));
    try testing.expect(is_ip("::1%foo", .any) and is_ip("::1%% :x\x1f", .v6));
    for ([_][]const u8{ "", "::1%", "::1%a\x00", "127.0.0.1%foo", "127.0.0.1/16", "::1/64", "[::1]", " ::1", "::1 " }) |text| try testing.expect(!is_ip(text, .any));
    try testing.expect(!is_ip("::1%foo", .v4));
}

test "a prefix is an address, a slash and a length, with no bit after it when strict" {
    for ([_][]const u8{ "192.168.5.21/16", "127.0.0.1/0", "255.255.255.255/32", "::1/64", "2001:0DB8:ABCD:0012:FFFF:FFFF:FFFF:FFFF/128", "::/0" }) |text| try testing.expect(is_ip_prefix(text, .any, false));
    for ([_][]const u8{ "", "192.168.1.0", "192.168.1.0/", "192.168.1.0/33", "192.168.1.0/024", "192.168.1.0/12345678901234567890", "::1/129", "::1/", "::1%en1/64", "::1/64%en1", " ::1/64", "::1/64 ", "1.2.3.4/-1" }) |text| try testing.expect(!is_ip_prefix(text, .any, false));
    try testing.expect(is_ip_prefix("127.0.0.1/16", .v4, false) and !is_ip_prefix("127.0.0.1/16", .v6, false));
    try testing.expect(is_ip_prefix("::1/64", .v6, false) and !is_ip_prefix("::1/64", .v4, false));
    // A length an IPv4 address cannot have is no IPv4 prefix, whatever the version asked for.
    try testing.expect(!is_ip_prefix("1.2.3.4/64", .any, false));
    for ([_][]const u8{ "192.168.0.0/16", "0.0.0.0/0", "128.0.0.0/1", "255.255.255.254/31", "255.255.255.255/32", "2001:0DB8:ABCD:0012::0/64", "8000::/1", "::/0", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe/127", "::ffff:192.1.0.0/112" }) |text| try testing.expect(is_ip_prefix(text, .any, true));
    for ([_][]const u8{ "255.255.128.0/16", "1.0.0.0/0", "129.0.0.0/1", "255.255.255.255/31", "2001:0DB8:ABCD:0012:FFFF:FFFF:FFFF:FFFF/64", "c000::/1", "1::/0", "::ffff:192.1.128.0/112" }) |text| try testing.expect(!is_ip_prefix(text, .any, true));
}
