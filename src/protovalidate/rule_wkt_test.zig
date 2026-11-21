//! Tests of the rules of the well-known types through `validate`: Any, Duration, Timestamp
//! and FieldMask.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const support = @import("rule_test_support.zig");
const expect = support.expect;
const expect_at = support.expect_at;
const expect_message = support.expect_message;

const Duration = proto.wkt.Duration;
const Timestamp = proto.wkt.Timestamp;

test "an Any's rules read its type URL" {
    const rules: pb.FieldRules = comptime .{ .type = .{ .any = .{ .in = .of(&.{ "t/a", "t/b" }), .not_in = .of(&.{"t/b"}) } } };
    try expect(?proto.wkt.Any, .message, rules, .{ .type_url = "t/a" }, "");
    try expect(?proto.wkt.Any, .message, rules, .{ .type_url = "t/b" }, "any.not_in");
    try expect(?proto.wkt.Any, .message, rules, .{ .type_url = "t/c" }, "any.in");
    try expect(?proto.wkt.Any, .message, rules, null, "");
    try expect_message(?proto.wkt.Any, .message, comptime .{ .type = .{ .any = .{ .in = .of(&.{"t/a"}) } } }, .{}, "type URL must be in the allow list");
    try expect_message(?proto.wkt.Any, .message, comptime .{ .type = .{ .any = .{ .not_in = .of(&.{"t/a"}) } } }, .{ .type_url = "t/a" }, "type URL must not be in the block list");
}

test "a duration's rules compare seconds and nanoseconds as one length" {
    const exact: pb.FieldRules = comptime .{ .type = .{ .duration = .{ .@"const" = .{ .seconds = 1, .nanos = 5 } } } };
    try expect(?Duration, .message, exact, .{ .seconds = 1, .nanos = 5 }, "");
    try expect(?Duration, .message, exact, .{ .seconds = 1, .nanos = 6 }, "duration.const");
    try expect(?Duration, .message, exact, .{ .seconds = 2, .nanos = 5 }, "duration.const");
    try expect(?Duration, .message, exact, null, "");
    try expect_message(?Duration, .message, exact, .{}, "must equal 1.000000005s");
    const range: pb.FieldRules = comptime .{ .type = .{ .duration = .{ .greater_than = .{ .gt = .{ .seconds = 1 } }, .less_than = .{ .lte = .{ .seconds = 2 } } } } };
    try expect(?Duration, .message, range, .{ .seconds = 1 }, "duration.gt_lte");
    try expect(?Duration, .message, range, .{ .seconds = 1, .nanos = 1 }, "");
    try expect(?Duration, .message, range, .{ .seconds = 2 }, "");
    try expect(?Duration, .message, range, .{ .seconds = 2, .nanos = 1 }, "duration.gt_lte");
    try expect_message(?Duration, .message, range, .{}, "must be greater than 1s and less than or equal to 2s");
    try expect(?Duration, .message, comptime .{ .type = .{ .duration = .{ .greater_than = .{ .gte = .{ .nanos = -1 } } } } }, .{ .nanos = -2 }, "duration.gte");
    try expect(?Duration, .message, comptime .{ .type = .{ .duration = .{ .less_than = .{ .lt = .{} } } } }, .{}, "duration.lt");
    const lists: pb.FieldRules = comptime .{ .type = .{ .duration = .{ .in = .of(&.{ .{ .seconds = 1 }, .{ .seconds = 2 } }), .not_in = .of(&.{.{ .seconds = 2 }}) } } };
    try expect(?Duration, .message, lists, .{ .seconds = 1 }, "");
    try expect(?Duration, .message, lists, .{ .seconds = 2 }, "duration.not_in");
    try expect(?Duration, .message, lists, .{ .seconds = 3 }, "duration.in");
    try expect_message(?Duration, .message, comptime .{ .type = .{ .duration = .{ .in = .of(&.{ .{ .seconds = 1 }, .{ .nanos = 1_000_000 } }) } } }, .{}, "must be in list [1s, 0.001s]");
}

test "a timestamp's const and bounds compare times, with no clock" {
    const exact: pb.FieldRules = comptime .{ .type = .{ .timestamp = .{ .@"const" = .{ .seconds = 3 } } } };
    try expect(?Timestamp, .message, exact, .{ .seconds = 3 }, "");
    try expect(?Timestamp, .message, exact, .{ .seconds = 3, .nanos = 1 }, "timestamp.const");
    const range: pb.FieldRules = comptime .{ .type = .{ .timestamp = .{ .greater_than = .{ .gte = .{ .seconds = 10 } }, .less_than = .{ .lt = .{ .seconds = 5 } } } } };
    // The upper bound lies under the lower one: the two ranges outside them pass.
    try expect(?Timestamp, .message, range, .{ .seconds = 4 }, "");
    try expect(?Timestamp, .message, range, .{ .seconds = 5 }, "timestamp.gte_lt_exclusive");
    try expect(?Timestamp, .message, range, .{ .seconds = 9 }, "timestamp.gte_lt_exclusive");
    try expect(?Timestamp, .message, range, .{ .seconds = 10 }, "");
    try expect_message(?Timestamp, .message, comptime .{ .type = .{ .timestamp = .{ .less_than = .{ .lt = .{ .seconds = 7 } } } } }, .{ .seconds = 7 }, "must be less than 1970-01-01T00:00:07Z");
}

test "a timestamp's lt_now, gt_now and within compare with the time the caller passes" {
    const now: Timestamp = .{ .seconds = 100 };
    const past: pb.FieldRules = comptime .{ .type = .{ .timestamp = .{ .less_than = .{ .lt_now = true } } } };
    try expect_at(?Timestamp, .message, past, .{ .seconds = 99 }, .{ .now = now }, "");
    try expect_at(?Timestamp, .message, past, .{ .seconds = 100 }, .{ .now = now }, "");
    try expect_at(?Timestamp, .message, past, .{ .seconds = 100, .nanos = 1 }, .{ .now = now }, "timestamp.lt_now");
    const future: pb.FieldRules = comptime .{ .type = .{ .timestamp = .{ .greater_than = .{ .gt_now = true } } } };
    try expect_at(?Timestamp, .message, future, .{ .seconds = 101 }, .{ .now = now }, "");
    try expect_at(?Timestamp, .message, future, .{ .seconds = 100 }, .{ .now = now }, "");
    try expect_at(?Timestamp, .message, future, .{ .seconds = 99, .nanos = 999_999_999 }, .{ .now = now }, "timestamp.gt_now");
    const near: pb.FieldRules = comptime .{ .type = .{ .timestamp = .{ .within = .{ .seconds = 5 } } } };
    try expect_at(?Timestamp, .message, near, .{ .seconds = 95 }, .{ .now = now }, "");
    try expect_at(?Timestamp, .message, near, .{ .seconds = 105 }, .{ .now = now }, "");
    try expect_at(?Timestamp, .message, near, .{ .seconds = 94, .nanos = 999_999_999 }, .{ .now = now }, "timestamp.within");
    try expect_at(?Timestamp, .message, near, .{ .seconds = 105, .nanos = 1 }, .{ .now = now }, "timestamp.within");
    // A rule that reads the time fails without it, and a message with no such rule does not.
    try testing.expectError(error.TimeMissing, expect(?Timestamp, .message, past, .{ .seconds = 1 }, ""));
    try testing.expectError(error.TimeMissing, expect(?Timestamp, .message, future, .{ .seconds = 1 }, ""));
    try testing.expectError(error.TimeMissing, expect(?Timestamp, .message, near, .{ .seconds = 1 }, ""));
    try expect(?Timestamp, .message, past, null, "");
    try expect(?Timestamp, .message, comptime .{ .type = .{ .timestamp = .{ .less_than = .{ .lt_now = false } } } }, .{ .seconds = 1 }, "");
    try expect(?Timestamp, .message, comptime .{ .type = .{ .timestamp = .{ .@"const" = .{ .seconds = 1 } } } }, .{ .seconds = 1 }, "");
}

test "a field mask's rules compare its paths with a list" {
    const Mask = proto.wkt.FieldMask;
    const exact: pb.FieldRules = comptime .{ .type = .{ .field_mask = .{ .@"const" = .{ .paths = .of(&.{ "a", "b" }) } } } };
    try expect(?Mask, .message, exact, .{ .paths = .of(&.{ "a", "b" }) }, "");
    try expect(?Mask, .message, exact, .{ .paths = .of(&.{"a"}) }, "field_mask.const");
    try expect(?Mask, .message, exact, .{ .paths = .of(&.{ "b", "a" }) }, "field_mask.const");
    try expect_message(?Mask, .message, exact, .{}, "must equal paths [a, b]");
    const inside: pb.FieldRules = comptime .{ .type = .{ .field_mask = .{ .in = .of(&.{ "a", "b" }) } } };
    try expect(?Mask, .message, inside, .{ .paths = .of(&.{ "a", "b.c" }) }, "");
    try expect(?Mask, .message, inside, .{}, "");
    try expect(?Mask, .message, inside, .{ .paths = .of(&.{ "a", "c" }) }, "field_mask.in");
    try expect(?Mask, .message, inside, .{ .paths = .of(&.{"ab"}) }, "field_mask.in");
    try expect_message(?Mask, .message, inside, .{ .paths = .of(&.{"c"}) }, "must only contain paths in [a, b]");
    const outside: pb.FieldRules = comptime .{ .type = .{ .field_mask = .{ .not_in = .of(&.{ "a", "b" }) } } };
    try expect(?Mask, .message, outside, .{ .paths = .of(&.{ "c", "ab" }) }, "");
    try expect(?Mask, .message, outside, .{ .paths = .of(&.{ "c", "b.d" }) }, "field_mask.not_in");
    try expect(?Mask, .message, outside, .{ .paths = .of(&.{"a"}) }, "field_mask.not_in");
    try expect_message(?Mask, .message, outside, .{ .paths = .of(&.{"a"}) }, "must not contain any paths in [a, b]");
}
