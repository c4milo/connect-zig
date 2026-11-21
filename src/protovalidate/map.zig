//! A map field: `required` and `ignore` by whether it holds an entry, the rules of the map
//! itself, then each entry's key against `map.keys` and its value against `map.values`
//! (validate.proto, MapRules).
//!
//! A map on the wire is a list of entries, and the last entry of a key is the map's value
//! ("Maps", language guide). The walk reads an entry only when no later entry holds its key, so
//! it counts and checks what a program reads with `proto.map_get`. It compares the keys pair by
//! pair, since the module holds no set, up to `constants.compared_items_max` entries. A longer
//! map is read entry by entry, which checks more than the map holds and never less; with
//! `min_pairs`, where a repeated key would count twice, it is refused.
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("table.zig");
const constants = @import("constants.zig");
const shape = @import("shape.zig");
const walk_file = @import("walk.zig");
const value_file = @import("value.zig");
const field_file = @import("field.zig");
const list_file = @import("list.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const Broken = walk_file.Broken;

/// The rules this file checks, by their names in validate.proto.
pub const handled = [_][]const u8{ "min_pairs", "max_pairs", "keys", "values" };

/// The `map` rules a field's rules state, or none.
pub fn rules_of(comptime rules: pb.FieldRules) pb.MapRules {
    const typed = rules.type orelse return .{};
    return switch (typed) {
        .map => |lazy| lazy.value.?.*,
        else => .{},
    };
}

pub fn key_rules_of(comptime rules: pb.FieldRules) pb.FieldRules {
    const keys = rules_of(rules).keys.value orelse return .{};
    return keys.*;
}

pub fn value_rules_of(comptime rules: pb.FieldRules) pb.FieldRules {
    const values = rules_of(rules).values.value orelse return .{};
    return values.*;
}

fn broken(comptime rule: []const u8, comptime message: []const u8) Broken {
    return .{
        .rule = table.rule_path(&.{}, &.{ .{ .message = pb.FieldRules, .name = "map" }, .{ .message = pb.MapRules, .name = rule } }),
        .id = "map." ++ rule,
        .message = message,
    };
}

fn prefix_of(comptime rule: []const u8) []const table.Element {
    return table.rule_path(&.{}, &.{ .{ .message = pb.FieldRules, .name = "map" }, .{ .message = pb.MapRules, .name = rule } }).elements.items;
}

/// The subscript of a path element for an entry's key, by the key's type (validate.proto,
/// FieldPathElement.subscript).
fn subscript_of(comptime K: type, key: K) @typeInfo(@FieldType(table.Element, "subscript")).optional.child {
    return switch (@typeInfo(K)) {
        .bool => .{ .bool_key = key },
        .int => |int| if (int.signedness == .signed) .{ .int_key = key } else .{ .uint_key = key },
        .pointer => .{ .string_key = key },
        else => @compileError("no map key of type " ++ @typeName(K)),
    };
}

pub fn check(comptime F: type, comptime rules: pb.FieldRules, map: *const F, walk: *Walk, step: *Path) Fault!void {
    if (map.is_empty()) {
        // validate.proto, Ignore.IGNORE_IF_ZERO_VALUE: "For map fields, the zero is an empty
        // map", and FieldRules.required refuses the zero value.
        if (comptime rules.required orelse false) return walk_file.violate(walk, step, comptime field_file.required_broken(.{}), false);
        if (comptime (rules.ignore orelse .ignore_unspecified) == .ignore_if_zero_value) return;
    }
    const Entry = F.Element;
    const map_rules = comptime rules_of(rules);
    const counts = comptime map_rules.min_pairs != null or map_rules.max_pairs != null;
    const reads_keys = comptime side_read(@FieldType(Entry, "key"), key_rules_of(rules));
    const reads_values = comptime side_read(@FieldType(Entry, "value"), value_rules_of(rules));
    if (comptime !counts and !reads_keys and !reads_values) return;
    const entries = map.count() catch |failure| return walk_file.malformed(failure);
    const compares = entries <= constants.compared_items_max;
    // A repeated key counted twice would pass `min_pairs` for a map that holds fewer pairs.
    if (comptime map_rules.min_pairs != null) {
        if (!compares) return error.TooManyItems;
    }
    const pairs = try check_entries(F, rules, map, entries, compares, walk, step);
    try check_size(map_rules, pairs, walk, step);
}

/// Whether the walk reads an entry's keys, or its values, held as `H`: they have rules, or
/// are messages with a table, and `map.keys` or `map.values` does not state IGNORE_ALWAYS.
pub fn side_read(comptime H: type, comptime rules: pb.FieldRules) bool {
    if ((rules.ignore orelse .ignore_unspecified) == .ignore_always) return false;
    return value_file.is_read(value_file.Held(H), rules);
}

fn check_size(comptime rules: pb.MapRules, pairs: usize, walk: *Walk, step: *const Path) Fault!void {
    // validate.proto, map.min_pairs: "uint(this.size()) < rules.min_pairs".
    if (comptime rules.min_pairs) |least| {
        if (pairs < least) try walk_file.violate(walk, step, comptime broken("min_pairs", std.fmt.comptimePrint("map must be at least {d} entries", .{least})), false);
    }
    // validate.proto, map.max_pairs: "uint(this.size()) > rules.max_pairs".
    if (comptime rules.max_pairs) |most| {
        if (pairs > most) try walk_file.violate(walk, step, comptime broken("max_pairs", std.fmt.comptimePrint("map must be at most {d} entries", .{most})), false);
    }
}

/// Checks each entry that the map keeps, and returns how many it keeps.
fn check_entries(comptime F: type, comptime rules: pb.FieldRules, map: *const F, entries: usize, compares: bool, walk: *Walk, step: *Path) Fault!usize {
    const Entry = F.Element;
    const K = @FieldType(Entry, "key");
    step.element.key_type = comptime table.type_of(table.field_named(Entry, "key").kind);
    step.element.value_type = comptime table.type_of(table.field_named(Entry, "value").kind);
    defer step.element.subscript = null;
    defer step.element.key_type = null;
    defer step.element.value_type = null;
    var pairs: usize = 0;
    var each = map.iterator();
    for (0..entries) |_| {
        const entry = (each.next() catch |failure| return walk_file.malformed(failure)) orelse break;
        // "Maps", language guide: the last entry of a key is the map's value for it.
        if (compares and try key_again(F, each, entry.key, entries)) continue;
        pairs += 1;
        step.element.subscript = subscript_of(K, entry.key);
        try check_entry(Entry, rules, entry, walk, step);
    }
    return pairs;
}

/// Whether an entry after the iterator's place holds `key`.
fn key_again(comptime F: type, after: F.Iterator, key: @FieldType(F.Element, "key"), entries: usize) Fault!bool {
    var later = after;
    for (0..entries) |_| {
        const other = (later.next() catch |failure| return walk_file.malformed(failure)) orelse return false;
        if (list_file.same(@TypeOf(key), key, other.key)) return true;
    }
    return false;
}

fn check_entry(comptime Entry: type, comptime rules: pb.FieldRules, entry: *const Entry, walk: *Walk, step: *const Path) Fault!void {
    const K = @FieldType(Entry, "key");
    const H = @FieldType(Entry, "value");
    const key_rules = comptime key_rules_of(rules);
    if (comptime side_read(K, key_rules)) {
        const skips_zero = comptime (key_rules.ignore orelse .ignore_unspecified) == .ignore_if_zero_value;
        if (!(skips_zero and shape.is_zero(K, &entry.key))) {
            try value_file.check(K, key_rules, comptime .{ .prefix = prefix_of("keys"), .for_key = true }, &entry.key, walk, step);
        }
    }
    const value_rules = comptime value_rules_of(rules);
    if (comptime side_read(H, value_rules)) {
        const skips_zero = comptime (value_rules.ignore orelse .ignore_unspecified) == .ignore_if_zero_value;
        if (!(skips_zero and shape.is_zero(H, &entry.value))) {
            try value_file.check_held(H, value_rules, comptime .{ .prefix = prefix_of("values") }, &entry.value, walk, step);
        }
    }
}
