//! The rules of a FieldMask: `const`, `in` and `not_in` (validate.proto, FieldMaskRules).
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const text = @import("text.zig");
const walk_file = @import("walk.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const Broken = walk_file.Broken;

/// The rules this file checks, by their names in validate.proto.
pub const handled = [_][]const u8{ "const", "in", "not_in", "example" };

fn broken(comptime site: Site, comptime rule: []const u8, comptime message: []const u8) Broken {
    return walk_file.rule_broken(pb.FieldMaskRules, "field_mask", site, rule, rule, message);
}

pub fn check(comptime rules: pb.FieldMaskRules, comptime site: Site, value: *const proto.wkt.FieldMask, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, field_mask.const: "this.paths != getField(rules, 'const').paths".
    if (comptime rules.@"const") |wanted| {
        const equal = same_paths(wanted.paths.items, value) catch |failure| return walk_file.malformed(failure);
        if (!equal) try walk_file.violate(walk, path, comptime broken(site, "const", "must equal paths " ++ text.list(wanted.paths.items)), site.for_key);
    }
    // validate.proto, field_mask.in: "!this.paths.all(p, p in getField(rules, 'in') ||
    // getField(rules, 'in').exists(f, p.startsWith(f+'.')))".
    if (comptime rules.in.items.len != 0) {
        const outside = any_path(rules.in.items, value, false) catch |failure| return walk_file.malformed(failure);
        if (outside) try walk_file.violate(walk, path, comptime broken(site, "in", "must only contain paths in " ++ text.list(rules.in.items)), site.for_key);
    }
    // validate.proto, field_mask.not_in: "!this.paths.all(p, !(p in getField(rules, 'not_in') ||
    // getField(rules, 'not_in').exists(f, p.startsWith(f+'.'))))".
    if (comptime rules.not_in.items.len != 0) {
        const inside = any_path(rules.not_in.items, value, true) catch |failure| return walk_file.malformed(failure);
        if (inside) try walk_file.violate(walk, path, comptime broken(site, "not_in", "must not contain any paths in " ++ text.list(rules.not_in.items)), site.for_key);
    }
}

/// Whether the mask holds the paths of `wanted`, in their order, and no other.
fn same_paths(comptime wanted: []const []const u8, value: *const proto.wkt.FieldMask) !bool {
    var paths = value.paths.iterator();
    inline for (wanted) |each| {
        const held = try paths.next() orelse return false;
        if (!std.mem.eql(u8, held, each)) return false;
    }
    return try paths.next() == null;
}

/// Whether a path of the mask is covered by `list`, when `covered` is true, or is not, when it
/// is false. A path is covered by a name of the list that equals it, or that names a field it
/// lies under: "a" covers "a" and "a.b".
fn any_path(comptime list: []const []const u8, value: *const proto.wkt.FieldMask, comptime covered: bool) !bool {
    var paths = value.paths.iterator();
    for (0..proto.constants.limits.elements_max) |_| {
        const held = try paths.next() orelse return false;
        if (covers(list, held) == covered) return true;
    }
    unreachable;
}

fn covers(comptime list: []const []const u8, held: []const u8) bool {
    inline for (list) |name| {
        if (std.mem.eql(u8, held, name)) return true;
        if (std.mem.startsWith(u8, held, name ++ ".")) return true;
    }
    return false;
}

const testing = std.testing;

test "a name covers its own path and the paths under it, and no path that only starts like it" {
    const list = [_][]const u8{ "a", "b.c" };
    try testing.expect(covers(&list, "a") and covers(&list, "a.b") and covers(&list, "b.c") and covers(&list, "b.c.d"));
    try testing.expect(!covers(&list, "ab") and !covers(&list, "b") and !covers(&list, "b.cd") and !covers(&list, ""));
}

test "a mask's paths equal a list in order, and are found inside or outside one" {
    const mask: proto.wkt.FieldMask = .{ .paths = .of(&.{ "a", "b" }) };
    try testing.expect(try same_paths(&.{ "a", "b" }, &mask));
    try testing.expect(!try same_paths(&.{ "b", "a" }, &mask));
    try testing.expect(!try same_paths(&.{"a"}, &mask));
    try testing.expect(!try same_paths(&.{ "a", "b", "c" }, &mask));
    try testing.expect(try same_paths(&.{}, &proto.wkt.FieldMask{}));
    try testing.expect(!try any_path(&.{ "a", "b" }, &mask, false));
    try testing.expect(try any_path(&.{"a"}, &mask, false));
    try testing.expect(try any_path(&.{"b"}, &mask, true));
    try testing.expect(!try any_path(&.{"c"}, &mask, true));
}
