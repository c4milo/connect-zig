//! A repeated field: `required` and `ignore` by whether it holds an element, the rules of the
//! list itself, then each element against `repeated.items` (validate.proto, RepeatedRules).
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("table.zig");
const constants = @import("constants.zig");
const shape = @import("shape.zig");
const walk_file = @import("walk.zig");
const value_file = @import("value.zig");
const field_file = @import("field.zig");
const cel_rule = @import("cel/cel_rule.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const Broken = walk_file.Broken;

/// The rules this file checks, by their names in validate.proto.
pub const handled = [_][]const u8{ "min_items", "max_items", "unique", "items" };

/// The `repeated` rules a field's rules state, or none.
pub fn rules_of(comptime rules: pb.FieldRules) pb.RepeatedRules {
    const typed = rules.type orelse return .{};
    return switch (typed) {
        .repeated => |lazy| lazy.value.?.*,
        else => .{},
    };
}

/// The rules of each element: `repeated.items`, or none.
pub fn item_rules_of(comptime rules: pb.FieldRules) pb.FieldRules {
    const items = rules_of(rules).items.value orelse return .{};
    return items.*;
}

fn broken(comptime rule: []const u8, comptime message: []const u8) Broken {
    return .{
        .rule = table.rule_path(&.{}, &.{ .{ .message = pb.FieldRules, .name = "repeated" }, .{ .message = pb.RepeatedRules, .name = rule } }),
        .id = "repeated." ++ rule,
        .message = message,
    };
}

/// The rule path that leads each element's rule: `repeated.items`.
const items_prefix: []const table.Element = table.rule_path(&.{}, &.{ .{ .message = pb.FieldRules, .name = "repeated" }, .{ .message = pb.RepeatedRules, .name = "items" } }).elements.items;

pub fn check(comptime F: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules, list: *const F, walk: *Walk, step: *Path) Fault!void {
    if (list.is_empty()) {
        // validate.proto, Ignore.IGNORE_IF_ZERO_VALUE: "For repeated fields, the zero is an empty
        // list", and FieldRules.required refuses the zero value.
        if (comptime rules.required orelse false) return walk_file.violate(walk, step, comptime field_file.required_broken(.{}), false);
        if (comptime (rules.ignore orelse .ignore_unspecified) == .ignore_if_zero_value) return;
    }
    if (comptime cel_rule.states(rules)) try cel_rule.check_field(rules, .{}, cel_rule.Whole(F).?{ .field = list }, walk, step);
    try check_size(F, comptime rules_of(rules), list, walk, step);
    if (comptime rules_of(rules).unique orelse false) try check_unique(F, list, walk, step);
    try check_items(F, kind, comptime item_rules_of(rules), list, walk, step);
}

fn check_size(comptime F: type, comptime rules: pb.RepeatedRules, list: *const F, walk: *Walk, step: *const Path) Fault!void {
    if (comptime rules.min_items == null and rules.max_items == null) return;
    const count = list.count() catch |failure| return walk_file.malformed(failure);
    // validate.proto, repeated.min_items: "uint(this.size()) < rules.min_items".
    if (comptime rules.min_items) |least| {
        if (count < least) try walk_file.violate(walk, step, comptime broken("min_items", std.fmt.comptimePrint("must contain at least {d} item(s)", .{least})), false);
    }
    // validate.proto, repeated.max_items: "uint(this.size()) > rules.max_items".
    if (comptime rules.max_items) |most| {
        if (count > most) try walk_file.violate(walk, step, comptime broken("max_items", std.fmt.comptimePrint("must contain no more than {d} item(s)", .{most})), false);
    }
}

/// validate.proto, repeated.unique: "this.unique()". The module holds no set, so it compares
/// each element with each later one, and refuses a list too long to compare so.
fn check_unique(comptime F: type, list: *const F, walk: *Walk, step: *const Path) Fault!void {
    const count = list.count() catch |failure| return walk_file.malformed(failure);
    if (count > constants.compared_items_max) return error.TooManyItems;
    var elements = list.iterator();
    for (0..count) |_| {
        const element = (elements.next() catch |failure| return walk_file.malformed(failure)) orelse return;
        // A copy of the iterator reads the elements after this one.
        var later = elements;
        for (0..count) |_| {
            const other = (later.next() catch |failure| return walk_file.malformed(failure)) orelse break;
            if (same(F.Element, element, other)) {
                return walk_file.violate(walk, step, comptime broken("unique", "repeated value must contain unique items"), false);
            }
        }
    }
}

/// Whether two elements are equal: two strings or two byte strings by their octets, and any
/// other two by value.
pub fn same(comptime E: type, a: E, b: E) bool {
    if (comptime E == []const u8) return std.mem.eql(u8, a, b);
    return a == b;
}

fn check_items(comptime F: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules, list: *const F, walk: *Walk, step: *Path) Fault!void {
    const E = F.Element;
    if (comptime !value_file.is_read(E, rules)) return;
    // validate.proto, Ignore.IGNORE_ALWAYS, on `repeated.items`.
    if (comptime (rules.ignore orelse .ignore_unspecified) == .ignore_always) return;
    const skips_zero = comptime (rules.ignore orelse .ignore_unspecified) == .ignore_if_zero_value;
    const site: Site = comptime .{ .prefix = items_prefix };
    var elements = list.iterator();
    for (0..proto.constants.limits.elements_max) |index| {
        const next = (elements.next() catch |failure| return walk_file.malformed(failure)) orelse return;
        // A message's iterator gives a pointer, and any other element a value (decision 37).
        const element: *const E = if (comptime @TypeOf(next) == *const E) next else &next;
        if (skips_zero and shape.is_zero(E, element)) continue;
        step.element.subscript = .{ .index = index };
        try value_file.check(E, kind, rules, site, element, walk, step);
    }
    unreachable;
}
