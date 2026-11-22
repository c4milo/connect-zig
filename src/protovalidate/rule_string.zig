//! The rules of a string: `const`, its length in characters and in octets, `prefix`, `suffix`,
//! `contains`, `not_contains`, `in`, `not_in`, and the well-known forms (validate.proto,
//! StringRules).
const std = @import("std");
const pb = @import("buf_validate_validate");
const text = @import("text.zig");
const walk_file = @import("walk.zig");
const rule_scalar = @import("rule_scalar.zig");
const format_name = @import("format_name.zig");
const format_ip = @import("format_ip.zig");
const format_uri = @import("format_uri.zig");
const pattern_file = @import("pattern.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const Broken = walk_file.Broken;

/// The rules this file checks, by their names in validate.proto. `strict` is read with
/// `well_known_regex`.
pub const handled = [_][]const u8{
    "const",               "len",                 "min_len",      "max_len",     "len_bytes",   "min_bytes",     "max_bytes", "prefix",
    "suffix",              "contains",            "not_contains", "in",          "not_in",      "email",         "hostname",  "ip",
    "ipv4",                "ipv6",                "uri",          "uri_ref",     "address",     "uuid",          "tuuid",     "ip_with_prefixlen",
    "ipv4_with_prefixlen", "ipv6_with_prefixlen", "ip_prefix",    "ipv4_prefix", "ipv6_prefix", "host_and_port", "ulid",      "protobuf_fqn",
    "protobuf_dot_fqn",    "well_known_regex",    "strict",       "example",     "pattern",
};

fn broken(comptime site: Site, comptime rule: []const u8, comptime id: []const u8, comptime message: []const u8) Broken {
    return walk_file.rule_broken(pb.StringRules, "string", site, rule, id, message);
}

pub fn check(comptime rules: pb.StringRules, comptime site: Site, value: []const u8, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, string.const: "this != getField(rules, 'const')".
    if (comptime rules.@"const") |wanted| {
        if (!std.mem.eql(u8, value, wanted)) try walk_file.violate(walk, path, comptime broken(site, "const", "const", "must equal `" ++ wanted ++ "`"), site.for_key);
    }
    try check_characters(rules, site, value, walk, path);
    try check_octets(rules, site, value.len, walk, path);
    // validate.proto, string.pattern: "!this.matches(rules.pattern)".
    if (comptime rules.pattern) |pattern| {
        if (!pattern_file.matches(pattern, value)) try walk_file.violate(walk, path, comptime broken(site, "pattern", "pattern", "does not match regex pattern `" ++ pattern ++ "`"), site.for_key);
    }
    try check_parts(rules, site, value, walk, path);
    // validate.proto, string.in: "!(this in getField(rules, 'in'))".
    if (comptime rules.in.items.len != 0) {
        if (!rule_scalar.names(rules.in.items, value)) try walk_file.violate(walk, path, comptime broken(site, "in", "in", "must be in list " ++ text.list(rules.in.items)), site.for_key);
    }
    // validate.proto, string.not_in: "this in rules.not_in".
    if (comptime rules.not_in.items.len != 0) {
        if (rule_scalar.names(rules.not_in.items, value)) try walk_file.violate(walk, path, comptime broken(site, "not_in", "not_in", "must not be in list " ++ text.list(rules.not_in.items)), site.for_key);
    }
    if (comptime rules.well_known) |known| try check_known(known, rules.strict orelse true, site, value, walk, path);
}

/// The characters of a string: its Unicode code points, which CEL's `size()` counts. Each code
/// point of UTF-8 starts with one octet that is no continuation octet (RFC 3629 §3).
pub fn characters(value: []const u8) usize {
    var count: usize = 0;
    for (value) |octet| {
        if (starts_character(octet)) count += 1;
    }
    return count;
}

/// Whether `value` holds `least` characters or more. A string holds no more characters than
/// octets, so a shorter one holds fewer, and the count stops at `least`.
fn has_characters(value: []const u8, least: u64) bool {
    if (value.len < least) return false;
    var count: u64 = 0;
    for (value) |octet| {
        if (count == least) return true;
        if (starts_character(octet)) count += 1;
    }
    return count == least;
}

fn starts_character(octet: u8) bool {
    const continuation_mask = 0b1100_0000;
    const continuation_bits = 0b1000_0000;
    return octet & continuation_mask != continuation_bits;
}

fn check_characters(comptime rules: pb.StringRules, comptime site: Site, value: []const u8, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, string.len: "uint(this.size()) != rules.len".
    if (comptime rules.len) |exact| {
        if (characters(value) != exact) try walk_file.violate(walk, path, comptime broken(site, "len", "len", "must be " ++ text.of(exact) ++ " characters"), site.for_key);
    }
    // validate.proto, string.min_len: "uint(this.size()) < rules.min_len".
    if (comptime rules.min_len) |least| {
        if (!has_characters(value, least)) try walk_file.violate(walk, path, comptime broken(site, "min_len", "min_len", "must be at least " ++ text.of(least) ++ " characters"), site.for_key);
    }
    // validate.proto, string.max_len: "uint(this.size()) > rules.max_len".
    if (comptime rules.max_len) |most| {
        if (has_characters(value, most +| 1)) try walk_file.violate(walk, path, comptime broken(site, "max_len", "max_len", "must be at most " ++ text.of(most) ++ " characters"), site.for_key);
    }
}

fn check_octets(comptime rules: pb.StringRules, comptime site: Site, len: usize, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, string.len_bytes: "uint(bytes(this).size()) != rules.len_bytes".
    if (comptime rules.len_bytes) |exact| {
        if (len != exact) try walk_file.violate(walk, path, comptime broken(site, "len_bytes", "len_bytes", "must be " ++ text.of(exact) ++ " bytes"), site.for_key);
    }
    // validate.proto, string.min_bytes: "uint(bytes(this).size()) < rules.min_bytes".
    if (comptime rules.min_bytes) |least| {
        if (len < least) try walk_file.violate(walk, path, comptime broken(site, "min_bytes", "min_bytes", "must be at least " ++ text.of(least) ++ " bytes"), site.for_key);
    }
    // validate.proto, string.max_bytes: "uint(bytes(this).size()) > rules.max_bytes".
    if (comptime rules.max_bytes) |most| {
        if (len > most) try walk_file.violate(walk, path, comptime broken(site, "max_bytes", "max_bytes", "must be at most " ++ text.of(most) ++ " bytes"), site.for_key);
    }
}

fn check_parts(comptime rules: pb.StringRules, comptime site: Site, value: []const u8, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, string.prefix: "!this.startsWith(rules.prefix)".
    if (comptime rules.prefix) |prefix| {
        if (!std.mem.startsWith(u8, value, prefix)) try walk_file.violate(walk, path, comptime broken(site, "prefix", "prefix", "does not have prefix `" ++ prefix ++ "`"), site.for_key);
    }
    // validate.proto, string.suffix: "!this.endsWith(rules.suffix)".
    if (comptime rules.suffix) |suffix| {
        if (!std.mem.endsWith(u8, value, suffix)) try walk_file.violate(walk, path, comptime broken(site, "suffix", "suffix", "does not have suffix `" ++ suffix ++ "`"), site.for_key);
    }
    // validate.proto, string.contains: "!this.contains(rules.contains)".
    if (comptime rules.contains) |part| {
        if (std.mem.indexOf(u8, value, part) == null) try walk_file.violate(walk, path, comptime broken(site, "contains", "contains", "does not contain substring `" ++ part ++ "`"), site.for_key);
    }
    // validate.proto, string.not_contains: "this.contains(rules.not_contains)".
    if (comptime rules.not_contains) |part| {
        if (std.mem.indexOf(u8, value, part) != null) try walk_file.violate(walk, path, comptime broken(site, "not_contains", "not_contains", "contains substring `" ++ part ++ "`"), site.for_key);
    }
}

const Known = @typeInfo(@FieldType(pb.StringRules, "well_known")).optional.child;

/// One of StringRules' well-known forms: the id of its rule after "string.", what its messages
/// call the form, and whether an empty value breaks the rule `<id>_empty` and is not checked.
const Form = struct {
    id: []const u8,
    name: []const u8,
    refuses_empty: bool = true,
};

/// The form a well-known rule asks for, or null for a rule that is off: `email = false`, or
/// KNOWN_REGEX_UNSPECIFIED.
fn form_of(comptime known: Known) ?Form {
    return switch (known) {
        .well_known_regex => |regex| switch (regex) {
            .known_regex_http_header_name => .{ .id = "well_known_regex.header_name", .name = "HTTP header name" },
            // validate.proto, string.well_known_regex.header_value has no rule for an empty
            // value: its pattern takes one.
            .known_regex_http_header_value => .{ .id = "well_known_regex.header_value", .name = "HTTP header value", .refuses_empty = false },
            else => null,
        },
        // validate.proto, string.uri_ref: "!rules.uri_ref || this.isUriRef()", with no rule for
        // an empty value: the empty string is a URI reference.
        inline else => |on, tag| if (on) .{ .id = @tagName(tag), .name = name_of(tag), .refuses_empty = tag != .uri_ref } else null,
    };
}

/// What validate.proto's messages call each form: "must be a valid <name>".
fn name_of(comptime tag: std.meta.Tag(Known)) []const u8 {
    return switch (tag) {
        .email => "email address",
        .hostname => "hostname",
        .ip => "IP address",
        .ipv4 => "IPv4 address",
        .ipv6 => "IPv6 address",
        .uri => "URI",
        .uri_ref => "URI Reference",
        .address => "hostname, or ip address",
        .uuid => "UUID",
        .tuuid => "trimmed UUID",
        .ip_with_prefixlen, .ip_prefix => "IP prefix",
        .ipv4_with_prefixlen => "IPv4 address with prefix length",
        .ipv6_with_prefixlen => "IPv6 address with prefix length",
        .ipv4_prefix => "IPv4 prefix",
        .ipv6_prefix => "IPv6 prefix",
        .host_and_port => "host and port pair",
        .ulid => "ULID",
        .protobuf_fqn => "fully-qualified Protobuf name",
        .protobuf_dot_fqn => "fully-qualified Protobuf name with a leading dot",
        .well_known_regex => unreachable,
    };
}

/// Whether `value` has the form `known` asks for, as validate.proto's rule of that name
/// states it.
fn has_form(comptime known: Known, comptime strict: bool, value: []const u8) bool {
    return switch (known) {
        .email => format_name.is_email(value),
        .hostname => format_name.is_hostname(value),
        .ip => format_ip.is_ip(value, .any),
        .ipv4 => format_ip.is_ip(value, .v4),
        .ipv6 => format_ip.is_ip(value, .v6),
        .uri => format_uri.is_uri(value),
        .uri_ref => format_uri.is_uri_ref(value),
        // validate.proto, string.address: "this.isHostname() || this.isIp()".
        .address => format_name.is_hostname(value) or format_ip.is_ip(value, .any),
        .uuid => format_name.is_uuid(value),
        .tuuid => format_name.is_tuuid(value),
        .ip_with_prefixlen => format_ip.is_ip_prefix(value, .any, false),
        .ipv4_with_prefixlen => format_ip.is_ip_prefix(value, .v4, false),
        .ipv6_with_prefixlen => format_ip.is_ip_prefix(value, .v6, false),
        // validate.proto, string.ip_prefix: "this.isIpPrefix(true)".
        .ip_prefix => format_ip.is_ip_prefix(value, .any, true),
        .ipv4_prefix => format_ip.is_ip_prefix(value, .v4, true),
        .ipv6_prefix => format_ip.is_ip_prefix(value, .v6, true),
        // validate.proto, string.host_and_port: "this.isHostAndPort(true)".
        .host_and_port => format_name.is_host_and_port(value, true),
        .ulid => format_name.is_ulid(value),
        .protobuf_fqn => format_name.is_protobuf_fqn(value),
        .protobuf_dot_fqn => format_name.is_protobuf_dot_fqn(value),
        .well_known_regex => |regex| switch (regex) {
            .known_regex_http_header_name => format_name.is_header_name(value, strict),
            .known_regex_http_header_value => format_name.is_header_value(value, strict),
            else => true,
        },
    };
}

fn check_known(comptime known: Known, comptime strict: bool, comptime site: Site, value: []const u8, walk: *Walk, path: *const Path) Fault!void {
    const form = (comptime form_of(known)) orelse return;
    const rule = comptime @tagName(known);
    if (comptime form.refuses_empty) {
        // validate.proto, string.email_empty and the like: "this != ''".
        if (value.len == 0) return walk_file.violate(walk, path, comptime broken(site, rule, form.id ++ "_empty", "value is empty, which is not a valid " ++ form.name), site.for_key);
    }
    if (!has_form(known, strict, value)) try walk_file.violate(walk, path, comptime broken(site, rule, form.id, "must be a valid " ++ form.name), site.for_key);
}

const testing = std.testing;

test "a string's characters are its code points, whatever octets each takes" {
    try testing.expectEqual(@as(usize, 0), characters(""));
    try testing.expectEqual(@as(usize, 3), characters("abc"));
    try testing.expectEqual(@as(usize, 2), characters("你好"));
    try testing.expectEqual(@as(usize, 3), characters("a😀é"));
}

test "a string holds a count of characters when its count reaches it" {
    const strings = [_][]const u8{ "", "a", "ab", "é", "你好", "a😀é", "Ada Lovelace", "\x80\x80a", "a\x80\x80" };
    for (strings) |value| {
        const count = characters(value);
        for (0..value.len + 2) |least| try testing.expectEqual(count >= least, has_characters(value, least));
    }
}

test "each well-known form names its rule, and the two with no empty rule say so" {
    const email = comptime form_of(.{ .email = true }).?;
    try testing.expectEqualStrings("email", email.id);
    try testing.expect(email.refuses_empty);
    try testing.expect(comptime form_of(.{ .email = false }) == null);
    try testing.expect(comptime form_of(.{ .well_known_regex = .known_regex_unspecified }) == null);
    try testing.expectEqualStrings("well_known_regex.header_name", comptime form_of(.{ .well_known_regex = .known_regex_http_header_name }).?.id);
    try testing.expect(comptime !form_of(.{ .well_known_regex = .known_regex_http_header_value }).?.refuses_empty);
    try testing.expect(comptime !form_of(.{ .uri_ref = true }).?.refuses_empty);
}
