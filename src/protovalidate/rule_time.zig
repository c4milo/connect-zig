//! The rules of a Duration and of a Timestamp: `const`, the bounds `lt`, `lte`, `gt` and
//! `gte`, a duration's `in` and `not_in`, and a timestamp's `lt_now`, `gt_now` and `within`
//! (validate.proto, DurationRules and TimestampRules). Both types are a count of seconds and
//! of nanoseconds, so each is compared as one count of nanoseconds.
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const constants = @import("constants.zig");
const text = @import("text.zig");
const walk_file = @import("walk.zig");
const rule_number = @import("rule_number.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const Bound = rule_number.Bound(Nanos);
const broken = walk_file.rule_broken;

/// The rules this file checks, by their names in validate.proto.
pub const handled_duration = [_][]const u8{ "const", "lt", "lte", "gt", "gte", "in", "not_in", "example" };
pub const handled_timestamp = [_][]const u8{ "const", "lt", "lte", "lt_now", "gt", "gte", "gt_now", "within", "example" };

/// A duration, or a timestamp's time since the epoch, in nanoseconds: an i64 of seconds and an
/// i32 of nanoseconds take 94 bits.
pub const Nanos = i128;

pub fn nanos_of(value: anytype) Nanos {
    return @as(Nanos, value.seconds) * constants.nanos_per_second + value.nanos;
}

fn bound_of(comptime name: []const u8, comptime value: anytype) Bound {
    return .{ .name = name, .value = nanos_of(value), .inclusive = name.len == "gte".len, .text = text.of(value) };
}

/// The lower bound a rule message states: `gt` or `gte`. A timestamp's `gt_now` is a rule of
/// its own.
fn lower_of(comptime Rules: type, comptime rules: Rules) ?Bound {
    const stated = rules.greater_than orelse return null;
    return switch (stated) {
        // `gt_now` holds a bool, and `gt` and `gte` the time they compare with.
        inline else => |value, tag| if (@TypeOf(value) == bool) null else bound_of(@tagName(tag), value),
    };
}

/// The upper bound a rule message states: `lt` or `lte`.
fn upper_of(comptime Rules: type, comptime rules: Rules) ?Bound {
    const stated = rules.less_than orelse return null;
    return switch (stated) {
        inline else => |value, tag| if (@TypeOf(value) == bool) null else bound_of(@tagName(tag), value),
    };
}

/// `const` and the bounds, which a duration and a timestamp state alike.
fn check_shared(comptime Rules: type, comptime rules: Rules, comptime kind: []const u8, comptime site: Site, nanos: Nanos, walk: *Walk, path: *const Path) Fault!void {
    // validate.proto, duration.const and timestamp.const: "this != getField(rules, 'const')".
    if (comptime rules.@"const") |wanted| {
        if (nanos != comptime nanos_of(wanted)) try walk_file.violate(walk, path, comptime broken(Rules, kind, site, "const", "const", "must equal " ++ text.of(wanted)), site.for_key);
    }
    const lower = comptime lower_of(Rules, rules);
    const upper = comptime upper_of(Rules, rules);
    if (comptime lower == null and upper == null) return;
    if (rule_number.outside(Nanos, lower, upper, nanos)) try walk_file.violate(walk, path, comptime rule_number.range_broken(Rules, kind, site, lower, upper), site.for_key);
}

pub fn check_duration(comptime rules: pb.DurationRules, comptime site: Site, value: *const proto.wkt.Duration, walk: *Walk, path: *const Path) Fault!void {
    const nanos = nanos_of(value);
    try check_shared(pb.DurationRules, rules, "duration", site, nanos, walk, path);
    // validate.proto, duration.in: "!(this in getField(rules, 'in'))".
    if (comptime rules.in.items.len != 0) {
        if (!holds(rules.in.items, nanos)) try walk_file.violate(walk, path, comptime broken(pb.DurationRules, "duration", site, "in", "in", "must be in list " ++ text.list(rules.in.items)), site.for_key);
    }
    // validate.proto, duration.not_in: "this in rules.not_in".
    if (comptime rules.not_in.items.len != 0) {
        if (holds(rules.not_in.items, nanos)) try walk_file.violate(walk, path, comptime broken(pb.DurationRules, "duration", site, "not_in", "not_in", "must not be in list " ++ text.list(rules.not_in.items)), site.for_key);
    }
}

fn holds(comptime list: []const proto.wkt.Duration, nanos: Nanos) bool {
    inline for (list) |item| {
        if (nanos == comptime nanos_of(item)) return true;
    }
    return false;
}

/// Whether `rules` read the time: `lt_now`, `gt_now` or `within`.
pub fn reads_now(comptime rules: pb.TimestampRules) bool {
    return rules.within != null or states_now(rules.less_than, "lt_now") or states_now(rules.greater_than, "gt_now");
}

/// Whether a bound's oneof holds the member `name`, `lt_now` or `gt_now`, set to true.
fn states_now(comptime stated: anytype, comptime name: []const u8) bool {
    const held = stated orelse return false;
    return std.mem.eql(u8, @tagName(held), name) and @field(held, name);
}

pub fn check_timestamp(comptime rules: pb.TimestampRules, comptime site: Site, value: *const proto.wkt.Timestamp, walk: *Walk, path: *const Path) Fault!void {
    const nanos = nanos_of(value);
    try check_shared(pb.TimestampRules, rules, "timestamp", site, nanos, walk, path);
    if (comptime !reads_now(rules)) return;
    // The module reads no clock (decision 3): the caller passes the time.
    const now = nanos_of(walk.options.now orelse return error.TimeMissing);
    // validate.proto, timestamp.lt_now: "rules.lt_now && this > now".
    if (comptime states_now(rules.less_than, "lt_now")) {
        if (nanos > now) try walk_file.violate(walk, path, comptime broken(pb.TimestampRules, "timestamp", site, "lt_now", "lt_now", "must be less than now"), site.for_key);
    }
    // validate.proto, timestamp.gt_now: "rules.gt_now && this < now".
    if (comptime states_now(rules.greater_than, "gt_now")) {
        if (nanos < now) try walk_file.violate(walk, path, comptime broken(pb.TimestampRules, "timestamp", site, "gt_now", "gt_now", "must be greater than now"), site.for_key);
    }
    if (comptime rules.within) |span| {
        // validate.proto, timestamp.within: "this < now-rules.within || this > now+rules.within".
        const width = comptime nanos_of(span);
        if (nanos < now - width or nanos > now + width) try walk_file.violate(walk, path, comptime broken(pb.TimestampRules, "timestamp", site, "within", "within", "must be within " ++ text.of(span) ++ " of now"), site.for_key);
    }
}

const testing = std.testing;

test "seconds and nanoseconds are one count, on both sides of zero" {
    try testing.expectEqual(@as(Nanos, 1_500_000_000), nanos_of(proto.wkt.Duration{ .seconds = 1, .nanos = 500_000_000 }));
    try testing.expectEqual(@as(Nanos, -1_500_000_000), nanos_of(proto.wkt.Duration{ .seconds = -1, .nanos = -500_000_000 }));
    try testing.expectEqual(@as(Nanos, 1), nanos_of(proto.wkt.Timestamp{ .nanos = 1 }));
    try testing.expectEqual(@as(Nanos, std.math.maxInt(i64)) * 1_000_000_000, nanos_of(proto.wkt.Timestamp{ .seconds = std.math.maxInt(i64) }));
}

test "a timestamp's rules read the time for lt_now, gt_now and within alone" {
    try testing.expect(comptime reads_now(.{ .less_than = .{ .lt_now = true } }));
    try testing.expect(comptime reads_now(.{ .greater_than = .{ .gt_now = true } }));
    try testing.expect(comptime reads_now(.{ .within = .{ .seconds = 1 } }));
    try testing.expect(comptime !reads_now(.{ .less_than = .{ .lt_now = false } }));
    try testing.expect(comptime !reads_now(.{ .less_than = .{ .lt = .{ .seconds = 1 } }, .greater_than = .{ .gte = .{} } }));
    try testing.expect(comptime !reads_now(.{}));
}
