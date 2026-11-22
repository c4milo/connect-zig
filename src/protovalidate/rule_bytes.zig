//! The rules of a bytes field: `const`, its length, `prefix`, `suffix`, `contains`, `in`,
//! `not_in`, and the lengths of an IP address and of a UUID (validate.proto, BytesRules).
const std = @import("std");
const pb = @import("buf_validate_validate");
const constants = @import("constants.zig");
const text = @import("text.zig");
const walk_file = @import("walk.zig");
const rule_scalar = @import("rule_scalar.zig");
const pattern_file = @import("pattern.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const Broken = walk_file.Broken;

/// The rules this file checks, by their names in validate.proto.
pub const handled = [_][]const u8{ "const", "len", "min_len", "max_len", "pattern", "prefix", "suffix", "contains", "in", "not_in", "ip", "ipv4", "ipv6", "uuid", "example" };

fn broken(comptime site: Site, comptime rule: []const u8, comptime id: []const u8, comptime message: []const u8) Broken {
    return walk_file.rule_broken(pb.BytesRules, "bytes", site, rule, id, message);
}

pub fn check(comptime rules: pb.BytesRules, comptime site: Site, value: []const u8, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, bytes.const: "this != getField(rules, 'const')".
    if (comptime rules.@"const") |wanted| {
        if (!std.mem.eql(u8, value, wanted)) try walk_file.violate(walk, path, comptime broken(site, "const", "const", "must be " ++ text.hex(wanted)), site.for_key);
    }
    try check_len(rules, site, value.len, walk, path);
    try check_pattern(rules, site, value, walk, path);
    try check_parts(rules, site, value, walk, path);
    // validate.proto, bytes.in: "getField(rules, 'in').size() > 0 && !(this in getField(rules,
    // 'in'))".
    if (comptime rules.in.items.len != 0) {
        if (!rule_scalar.names(rules.in.items, value)) try walk_file.violate(walk, path, comptime broken(site, "in", "in", "must be in list " ++ text.hex_list(rules.in.items)), site.for_key);
    }
    // validate.proto, bytes.not_in: "this in rules.not_in".
    if (comptime rules.not_in.items.len != 0) {
        if (rule_scalar.names(rules.not_in.items, value)) try walk_file.violate(walk, path, comptime broken(site, "not_in", "not_in", "must not be in list " ++ text.hex_list(rules.not_in.items)), site.for_key);
    }
    if (comptime rules.well_known) |known| try check_known(known, site, value.len, walk, path);
}

fn check_len(comptime rules: pb.BytesRules, comptime site: Site, len: usize, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, bytes.len: "uint(this.size()) != rules.len".
    if (comptime rules.len) |exact| {
        if (len != exact) try walk_file.violate(walk, path, comptime broken(site, "len", "len", "must be " ++ text.of(exact) ++ " bytes"), site.for_key);
    }
    // validate.proto, bytes.min_len: "uint(this.size()) < rules.min_len".
    if (comptime rules.min_len) |least| {
        if (len < least) try walk_file.violate(walk, path, comptime broken(site, "min_len", "min_len", "must be at least " ++ text.of(least) ++ " bytes"), site.for_key);
    }
    // validate.proto, bytes.max_len: "uint(this.size()) > rules.max_len".
    if (comptime rules.max_len) |most| {
        if (len > most) try walk_file.violate(walk, path, comptime broken(site, "max_len", "max_len", "must be at most " ++ text.of(most) ++ " bytes"), site.for_key);
    }
}

/// validate.proto, bytes.pattern: "!string(this).matches(rules.pattern)". `string` of octets
/// that are not UTF-8 fails as the rule runs (CEL language definition, "Types and
/// Conversions"), so such a value is no violation: the rule cannot judge it.
fn check_pattern(comptime rules: pb.BytesRules, comptime site: Site, value: []const u8, walk: *Walk, path: *const Path) Fault!void {
    if (comptime rules.pattern) |pattern| {
        if (!std.unicode.utf8ValidateSlice(value)) return error.Unevaluable;
        if (!pattern_file.matches(pattern, value, walk.options.cpu_features)) try walk_file.violate(walk, path, comptime broken(site, "pattern", "pattern", "must match regex pattern `" ++ pattern ++ "`"), site.for_key);
    }
}

fn check_parts(comptime rules: pb.BytesRules, comptime site: Site, value: []const u8, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, bytes.prefix: "!this.startsWith(rules.prefix)".
    if (comptime rules.prefix) |prefix| {
        if (!std.mem.startsWith(u8, value, prefix)) try walk_file.violate(walk, path, comptime broken(site, "prefix", "prefix", "does not have prefix " ++ text.hex(prefix)), site.for_key);
    }
    // validate.proto, bytes.suffix: "!this.endsWith(rules.suffix)".
    if (comptime rules.suffix) |suffix| {
        if (!std.mem.endsWith(u8, value, suffix)) try walk_file.violate(walk, path, comptime broken(site, "suffix", "suffix", "does not have suffix " ++ text.hex(suffix)), site.for_key);
    }
    // validate.proto, bytes.contains: "!this.contains(rules.contains)".
    if (comptime rules.contains) |part| {
        if (std.mem.indexOf(u8, value, part) == null) try walk_file.violate(walk, path, comptime broken(site, "contains", "contains", "does not contain " ++ text.hex(part)), site.for_key);
    }
}

/// One of BytesRules' well-known forms: the lengths it takes, and what its messages call it.
const Known = struct { lens: []const usize, name: []const u8 };

fn known_of(comptime known: @typeInfo(@FieldType(pb.BytesRules, "well_known")).optional.child) ?Known {
    return switch (known) {
        // validate.proto, bytes.ip: "this.size() == 4 || this.size() == 16".
        .ip => |on| if (on) .{ .lens = &.{ constants.ipv4_len, constants.ipv6_len }, .name = "IP address" } else null,
        // validate.proto, bytes.ipv4: "this.size() == 4".
        .ipv4 => |on| if (on) .{ .lens = &.{constants.ipv4_len}, .name = "IPv4 address" } else null,
        // validate.proto, bytes.ipv6: "this.size() == 16".
        .ipv6 => |on| if (on) .{ .lens = &.{constants.ipv6_len}, .name = "IPv6 address" } else null,
        // validate.proto, bytes.uuid: "this.size() == 16".
        .uuid => |on| if (on) .{ .lens = &.{constants.uuid_len}, .name = "UUID" } else null,
    };
}

fn check_known(comptime known: @typeInfo(@FieldType(pb.BytesRules, "well_known")).optional.child, comptime site: Site, len: usize, walk: *Walk, path: *const Path) Fault!void {
    const form = (comptime known_of(known)) orelse return;
    const rule = comptime @tagName(known);
    // validate.proto, bytes.ip_empty and the like: "this.size() != 0".
    if (len == 0) return walk_file.violate(walk, path, comptime broken(site, rule, rule ++ "_empty", "value is empty, which is not a valid " ++ form.name), site.for_key);
    inline for (form.lens) |valid| {
        if (len == valid) return;
    }
    try walk_file.violate(walk, path, comptime broken(site, rule, rule, "must be a valid " ++ form.name), site.for_key);
}
