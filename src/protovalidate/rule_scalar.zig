//! The rules of a bool, of an enum and of an Any (validate.proto, BoolRules, EnumRules and
//! AnyRules).
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const text = @import("text.zig");
const walk_file = @import("walk.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const broken = walk_file.rule_broken;

/// The rules this file checks, by their names in validate.proto. `example` checks nothing:
/// its rule in validate.proto is `true`.
pub const handled_bool = [_][]const u8{ "const", "example" };
pub const handled_enum = [_][]const u8{ "const", "defined_only", "in", "not_in", "example" };
pub const handled_any = [_][]const u8{ "in", "not_in" };

pub fn check_bool(comptime rules: pb.BoolRules, comptime site: Site, value: bool, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, bool.const: "this != getField(rules, 'const')".
    if (comptime rules.@"const") |wanted| {
        if (value != wanted) try walk_file.violate(walk, path, comptime broken(pb.BoolRules, "bool", site, "const", "const", "must equal " ++ text.of(wanted)), site.for_key);
    }
}

pub fn check_enum(comptime E: type, comptime rules: pb.EnumRules, comptime site: Site, value: E, walk: *Walk, path: *const Path) Fault!void {
    const number: i32 = @intFromEnum(value);
    // validate.proto, enum.const: "this != getField(rules, 'const')".
    if (comptime rules.@"const") |wanted| {
        if (number != wanted) try walk_file.violate(walk, path, comptime broken(pb.EnumRules, "enum", site, "const", "const", "must equal " ++ text.of(wanted)), site.for_key);
    }
    // validate.proto, EnumRules.defined_only: "the field value must be one of the defined
    // values for this enum".
    if (comptime rules.defined_only orelse false) {
        if (!E.protobuf.contains(number)) try walk_file.violate(walk, path, comptime broken(pb.EnumRules, "enum", site, "defined_only", "defined_only", "value must be one of the defined enum values"), site.for_key);
    }
    // validate.proto, enum.in: "!(this in getField(rules, 'in'))".
    if (comptime rules.in.items.len != 0) {
        if (!holds(rules.in.items, number)) try walk_file.violate(walk, path, comptime broken(pb.EnumRules, "enum", site, "in", "in", "must be in list " ++ text.list(rules.in.items)), site.for_key);
    }
    // validate.proto, enum.not_in: "this in rules.not_in".
    if (comptime rules.not_in.items.len != 0) {
        if (holds(rules.not_in.items, number)) try walk_file.violate(walk, path, comptime broken(pb.EnumRules, "enum", site, "not_in", "not_in", "must not be in list " ++ text.list(rules.not_in.items)), site.for_key);
    }
}

fn holds(comptime list: []const i32, number: i32) bool {
    inline for (list) |item| {
        if (number == item) return true;
    }
    return false;
}

pub fn check_any(comptime rules: pb.AnyRules, comptime site: Site, value: *const proto.wkt.Any, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, AnyRules.in: "requires the field's `type_url` to be equal to one of the
    // specified values".
    if (comptime rules.in.items.len != 0) {
        if (!names(rules.in.items, value.type_url)) try walk_file.violate(walk, path, comptime broken(pb.AnyRules, "any", site, "in", "in", "type URL must be in the allow list"), site.for_key);
    }
    // validate.proto, AnyRules.not_in: "requires the field's type_url to be not equal to any of
    // the specified values".
    if (comptime rules.not_in.items.len != 0) {
        if (names(rules.not_in.items, value.type_url)) try walk_file.violate(walk, path, comptime broken(pb.AnyRules, "any", site, "not_in", "not_in", "type URL must not be in the block list"), site.for_key);
    }
}

/// Whether `list` holds `value`, octet for octet.
pub fn names(comptime list: []const []const u8, value: []const u8) bool {
    inline for (list) |item| {
        if (std.mem.eql(u8, value, item)) return true;
    }
    return false;
}
