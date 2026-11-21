//! The rules of a number: `const`, the bounds `lt`, `lte`, `gt` and `gte`, `in`, `not_in`, and
//! a float's `finite` (validate.proto, FloatRules to SFixed64Rules). The twelve rule messages
//! hold the same fields, so one check reads each, with the number's type from its `const`.
const std = @import("std");
const pb = @import("buf_validate_validate");
const text = @import("text.zig");
const walk_file = @import("walk.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const Broken = walk_file.Broken;

/// The rules this file checks, by their names in validate.proto. `example` checks nothing:
/// its rule in validate.proto is `true`.
pub const handled = [_][]const u8{ "const", "lt", "lte", "gt", "gte", "in", "not_in", "finite", "example" };

/// One bound of a range: its rule's name, its value, whether the value itself is inside, and
/// the value as a message states it.
pub fn Bound(comptime Number: type) type {
    return struct { name: []const u8, value: Number, inclusive: bool, text: []const u8 };
}

/// The lower bound a rule message states: `gt` or `gte`.
fn lower_of(comptime Rules: type, comptime rules: Rules, comptime Number: type) ?Bound(Number) {
    const stated = rules.greater_than orelse return null;
    return switch (stated) {
        .gt => |value| .{ .name = "gt", .value = value, .inclusive = false, .text = text.of(value) },
        .gte => |value| .{ .name = "gte", .value = value, .inclusive = true, .text = text.of(value) },
    };
}

/// The upper bound a rule message states: `lt` or `lte`.
fn upper_of(comptime Rules: type, comptime rules: Rules, comptime Number: type) ?Bound(Number) {
    const stated = rules.less_than orelse return null;
    return switch (stated) {
        .lt => |value| .{ .name = "lt", .value = value, .inclusive = false, .text = text.of(value) },
        .lte => |value| .{ .name = "lte", .value = value, .inclusive = true, .text = text.of(value) },
    };
}

/// The rule a value outside the range breaks: its id, such as "int32.gt_lt", the path of the
/// bound that carries it in validate.proto, and its message.
pub fn range_broken(comptime Rules: type, comptime kind: []const u8, comptime site: Site, comptime lower: anytype, comptime upper: anytype) Broken {
    comptime {
        const low = lower orelse return broken(Rules, kind, site, upper.?.name, upper.?.name, "must be " ++ bound_text("less than ", upper.?));
        const high = upper orelse return broken(Rules, kind, site, low.name, low.name, "must be " ++ bound_text("greater than ", low));
        // validate.proto: an upper bound under the lower one states the two ranges outside
        // them, "<type>.gt_lt_exclusive".
        const exclusive = is_exclusive(@TypeOf(low.value), low, high);
        const id = low.name ++ "_" ++ high.name ++ (if (exclusive) "_exclusive" else "");
        const message = "must be " ++ bound_text("greater than ", low) ++ (if (exclusive) " or " else " and ") ++ bound_text("less than ", high);
        return broken(Rules, kind, site, low.name, id, message);
    }
}

/// "greater than 5", or "greater than or equal to 5" for a bound whose value is inside.
fn bound_text(comptime relation: []const u8, comptime bound: anytype) []const u8 {
    return relation ++ (if (bound.inclusive) "or equal to " else "") ++ bound.text;
}

const broken = walk_file.rule_broken;

/// Checks `value` against each rule of `rules`. `kind` is the member of FieldRules that holds
/// the rule message: "int32", "float".
pub fn check(comptime Rules: type, comptime rules: Rules, comptime kind: []const u8, comptime site: Site, value: anytype, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, <type>.const: "this != getField(rules, 'const')".
    if (comptime rules.@"const") |wanted| {
        if (value != wanted) try walk_file.violate(walk, path, comptime broken(Rules, kind, site, "const", "const", "must equal " ++ text.of(wanted)), site.for_key);
    }
    try check_range(Rules, rules, kind, site, value, walk, path);
    try check_lists(Rules, rules, kind, site, value, walk, path);
    if (comptime @hasField(Rules, "finite")) {
        // validate.proto, <type>.finite: "this.isNan() || this.isInf()".
        if (comptime rules.finite orelse false) {
            if (!std.math.isFinite(value)) try walk_file.violate(walk, path, comptime broken(Rules, kind, site, "finite", "finite", "must be finite"), site.for_key);
        }
    }
}

fn check_lists(comptime Rules: type, comptime rules: Rules, comptime kind: []const u8, comptime site: Site, value: anytype, walk: *Walk, path: *const Path) Fault!void {
    const Number = @TypeOf(value);
    // validate.proto, <type>.in: "!(this in getField(rules, 'in'))".
    if (comptime rules.in.items.len != 0) {
        if (!holds(Number, rules.in.items, value)) try walk_file.violate(walk, path, comptime broken(Rules, kind, site, "in", "in", "must be in list " ++ text.list(rules.in.items)), site.for_key);
    }
    // validate.proto, <type>.not_in: "this in rules.not_in".
    if (comptime rules.not_in.items.len != 0) {
        if (holds(Number, rules.not_in.items, value)) try walk_file.violate(walk, path, comptime broken(Rules, kind, site, "not_in", "not_in", "must not be in list " ++ text.list(rules.not_in.items)), site.for_key);
    }
}

fn check_range(comptime Rules: type, comptime rules: Rules, comptime kind: []const u8, comptime site: Site, value: anytype, walk: *Walk, path: *const Path) Fault!void {
    const Number = @TypeOf(value);
    const lower = comptime lower_of(Rules, rules, Number);
    const upper = comptime upper_of(Rules, rules, Number);
    if (comptime lower == null and upper == null) return;
    if (outside(Number, lower, upper, value)) try walk_file.violate(walk, path, comptime range_broken(Rules, kind, site, lower, upper), site.for_key);
}

/// Whether `value` breaks the range of `lower` and `upper`, as validate.proto states each case.
pub fn outside(comptime Number: type, comptime lower: ?Bound(Number), comptime upper: ?Bound(Number), value: Number) bool {
    // validate.proto, float.gt and each float bound: "this.isNan() ||". No number is NaN but a
    // float, and NaN compares false with every bound.
    if (comptime @typeInfo(Number) == .float) {
        if (std.math.isNan(value)) return true;
    }
    const below = is_below(Number, lower, value);
    const above = is_above(Number, upper, value);
    // validate.proto, <type>.gt_lt_exclusive: "rules.lt < rules.gt && (rules.lt <= this && this
    // <= rules.gt)". The value is then between the two ranges.
    if (comptime is_exclusive(Number, lower, upper)) return above and below;
    // validate.proto, <type>.gt_lt: "this >= rules.lt || this <= rules.gt".
    return above or below;
}

/// Whether the upper bound lies under the lower one, so the two state the ranges outside them.
fn is_exclusive(comptime Number: type, comptime lower: ?Bound(Number), comptime upper: ?Bound(Number)) bool {
    const low = lower orelse return false;
    const high = upper orelse return false;
    return high.value < low.value;
}

/// validate.proto, <type>.gt: "this <= rules.gt"; <type>.gte: "this < rules.gte".
fn is_below(comptime Number: type, comptime lower: ?Bound(Number), value: Number) bool {
    const bound = (comptime lower) orelse return false;
    return if (comptime bound.inclusive) value < bound.value else value <= bound.value;
}

/// validate.proto, <type>.lt: "this >= rules.lt"; <type>.lte: "this > rules.lte".
fn is_above(comptime Number: type, comptime upper: ?Bound(Number), value: Number) bool {
    const bound = (comptime upper) orelse return false;
    return if (comptime bound.inclusive) value > bound.value else value >= bound.value;
}

/// Whether `list` holds `value`, as CEL's `in` compares: NaN equals no number.
fn holds(comptime Number: type, comptime list: []const Number, value: Number) bool {
    inline for (list) |item| {
        if (value == item) return true;
    }
    return false;
}

const testing = std.testing;

fn limit(comptime Number: type, comptime name: []const u8, comptime value: Number) ?Bound(Number) {
    return .{ .name = name, .value = value, .inclusive = name.len == "gte".len, .text = text.of(value) };
}

test "a single bound refuses the value at it unless it is inclusive" {
    try testing.expect(outside(i32, limit(i32, "gt", 5), null, 5));
    try testing.expect(!outside(i32, limit(i32, "gt", 5), null, 6));
    try testing.expect(!outside(i32, limit(i32, "gte", 5), null, 5));
    try testing.expect(outside(i32, limit(i32, "gte", 5), null, 4));
    try testing.expect(outside(u64, null, limit(u64, "lt", 5), 5));
    try testing.expect(!outside(u64, null, limit(u64, "lt", 5), 4));
    try testing.expect(!outside(u64, null, limit(u64, "lte", 5), 5));
    try testing.expect(outside(u64, null, limit(u64, "lte", 5), 6));
}

test "two bounds state a range, or the two ranges outside them when the upper one is lower" {
    // gt 0 and lt 10: inside is 1 to 9.
    try testing.expect(outside(i64, limit(i64, "gt", 0), limit(i64, "lt", 10), 0));
    try testing.expect(outside(i64, limit(i64, "gt", 0), limit(i64, "lt", 10), 10));
    try testing.expect(!outside(i64, limit(i64, "gt", 0), limit(i64, "lt", 10), 1));
    try testing.expect(!outside(i64, limit(i64, "gte", 0), limit(i64, "lte", 10), 0));
    try testing.expect(!outside(i64, limit(i64, "gte", 0), limit(i64, "lte", 10), 10));
    // gt 10 or lt 0: inside is under 0 and over 10.
    try testing.expect(outside(i64, limit(i64, "gt", 10), limit(i64, "lt", 0), 0));
    try testing.expect(outside(i64, limit(i64, "gt", 10), limit(i64, "lt", 0), 10));
    try testing.expect(outside(i64, limit(i64, "gt", 10), limit(i64, "lt", 0), 5));
    try testing.expect(!outside(i64, limit(i64, "gt", 10), limit(i64, "lt", 0), -1));
    try testing.expect(!outside(i64, limit(i64, "gt", 10), limit(i64, "lt", 0), 11));
    // Equal bounds are a range, which holds no number when a bound is exclusive: validate.proto
    // compares the bounds with ">=".
    try testing.expect(outside(i64, limit(i64, "gt", 5), limit(i64, "lt", 5), 4));
    try testing.expect(outside(i64, limit(i64, "gt", 5), limit(i64, "lt", 5), 5));
    try testing.expect(outside(i64, limit(i64, "gt", 5), limit(i64, "lt", 5), 6));
    try testing.expect(!outside(i64, limit(i64, "gte", 5), limit(i64, "lte", 5), 5));
    try testing.expect(outside(i64, limit(i64, "gte", 5), limit(i64, "lte", 5), 4));
    // gte 10 or lte 0: the bounds themselves are inside.
    try testing.expect(!outside(i64, limit(i64, "gte", 10), limit(i64, "lte", 0), 0));
    try testing.expect(!outside(i64, limit(i64, "gte", 10), limit(i64, "lte", 0), 10));
    try testing.expect(outside(i64, limit(i64, "gte", 10), limit(i64, "lte", 0), 1));
    try testing.expect(outside(i64, limit(i64, "gte", 10), limit(i64, "lte", 0), 9));
}

test "NaN is outside every float range, and inside no list" {
    const nan = std.math.nan(f64);
    try testing.expect(outside(f64, limit(f64, "gt", 0), null, nan));
    try testing.expect(outside(f64, null, limit(f64, "lte", 0), nan));
    try testing.expect(outside(f64, limit(f64, "gt", 10), limit(f64, "lt", 0), nan));
    try testing.expect(!outside(f64, limit(f64, "gt", 0), null, std.math.inf(f64)));
    try testing.expect(!holds(f64, &.{ 1.5, nan }, nan));
    try testing.expect(holds(f64, &.{ 1.5, nan }, 1.5));
    try testing.expect(!holds(i32, &.{}, 0));
}

test "a range's rule is named for its bounds, and carried by the lower one" {
    const site: Site = .{};
    const single = comptime range_broken(pb.Int32Rules, "int32", site, limit(i32, "gte", 5), null);
    try testing.expectEqualStrings("int32.gte", single.id);
    try testing.expectEqualStrings("must be greater than or equal to 5", single.message);
    try testing.expectEqualStrings("gte", single.rule.?.elements.items[1].field_name.?);
    const upper_alone = comptime range_broken(pb.Int32Rules, "int32", site, null, limit(i32, "lt", 5));
    try testing.expectEqualStrings("int32.lt", upper_alone.id);
    try testing.expectEqualStrings("must be less than 5", upper_alone.message);
    try testing.expectEqualStrings("lt", upper_alone.rule.?.elements.items[1].field_name.?);
    const both = comptime range_broken(pb.FloatRules, "float", site, limit(f32, "gt", 0), limit(f32, "lte", 10));
    try testing.expectEqualStrings("float.gt_lte", both.id);
    try testing.expectEqualStrings("must be greater than 0 and less than or equal to 10", both.message);
    try testing.expectEqualStrings("gt", both.rule.?.elements.items[1].field_name.?);
    try testing.expectEqualStrings("float", both.rule.?.elements.items[0].field_name.?);
    const exclusive = comptime range_broken(pb.Int32Rules, "int32", site, limit(i32, "gte", 10), limit(i32, "lt", 0));
    try testing.expectEqualStrings("int32.gte_lt_exclusive", exclusive.id);
    try testing.expectEqualStrings("must be greater than or equal to 10 or less than 0", exclusive.message);
    // Equal bounds are a range, not the ranges outside one: validate.proto compares with ">=".
    const equal = comptime range_broken(pb.Int32Rules, "int32", site, limit(i32, "gt", 5), limit(i32, "lt", 5));
    try testing.expectEqualStrings("int32.gt_lt", equal.id);
}
