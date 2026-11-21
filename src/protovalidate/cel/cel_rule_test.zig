//! Tests of the CEL rules through `validate`: the violation each one reports, with its field,
//! its rule's path, its id and its message, and what a rule that cannot run ends with.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("../table.zig");
const constants = @import("../constants.zig");
const report_file = @import("../report.zig");
const validate_file = @import("../validate.zig");
const walk_test = @import("../validate_test.zig");
const Rules = table.Rules;
const Checked = walk_test.Checked;

const Nested = struct {
    a: i32 = 0,
    b: i32 = 0,
    pub const FieldNumber = enum(u29) { a = 1, b = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Nested", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}), proto.field_of(FieldNumber.b, .int32, .{}),
    } };
    pub const protovalidate: Rules = .{
        .message = .{
            // A string result is the violation's message, and an empty one passes.
            .cel = .of(&.{.{ .id = "nested", .expression = "this.a > this.b ? '' : 'a must be greater than b'" }}),
        },
    };
};

const Outer = struct {
    a: i32 = 0,
    b: i32 = 0,
    e: ?Nested = null,
    val: i32 = 0,
    name: ?[]const u8 = null,
    pub const FieldNumber = enum(u29) { a = 1, b = 2, e = 3, val = 4, name = 5 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Outer", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}),     proto.field_of(FieldNumber.b, .int32, .{}),
        proto.field_of(FieldNumber.e, .message, .{}),   proto.field_of(FieldNumber.val, .int32, .{}),
        proto.field_of(FieldNumber.name, .string, .{}),
    } };
    pub const protovalidate: Rules = .{
        .message = .{
            .cel = .of(&.{ .{ .id = "ordered", .message = "a must be less than b", .expression = "this.a < this.b" }, .{ .id = "plain", .expression = "this.b != 9" } }),
            .cel_expression = .of(&.{"this.a != 7"}),
        },
        .fields = &.{
            .{ .number = @intFromEnum(FieldNumber.val), .rules = .{
                .cel = .of(&.{ .{ .id = "first", .message = "val must be positive", .expression = "this > 0" }, .{ .id = "second", .message = "val must be over 1", .expression = "this > 1" } }),
                .cel_expression = .of(&.{"this != 5"}),
                .type = .{ .int32 = .{ .less_than = .{ .lt = max } } },
            } },
            .{ .number = @intFromEnum(FieldNumber.name), .rules = .{ .cel = .of(&.{.{ .id = "named", .message = "name must start with n", .expression = "this.startsWith('n')" }}) } },
        },
    };
    const max = 100;
};

fn valid() Outer {
    const two = 2;
    return .{ .a = 1, .b = two, .e = .{ .a = two, .b = 1 }, .val = two };
}

test "a message that keeps each CEL rule passes" {
    var checked: Checked = undefined;
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &valid())).len);
    var named = valid();
    named.name = "nell";
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &named)).len);
}

test "a message's CEL rule names no field and no rule path, and states its message" {
    var checked: Checked = undefined;
    var message = valid();
    message.a = 2;
    const violations = try checked.of(Outer, &message);
    try walk_test.expect_one(violations, "", "", "ordered");
    try testing.expectEqualStrings("a must be less than b", violations[0].message.?);
    // A rule with no message states which expression gave false, and a `cel_expression` is
    // its own id.
    message = valid();
    message.b = 9;
    const plain = try checked.of(Outer, &message);
    try walk_test.expect_one(plain, "", "", "plain");
    try testing.expectEqualStrings("\"this.b != 9\" returned false", plain[0].message.?);
    message = valid();
    message.a = 7;
    message.b = 8;
    const expression = try checked.of(Outer, &message);
    try walk_test.expect_one(expression, "", "", "this.a != 7");
    try testing.expectEqualStrings("\"this.a != 7\" returned false", expression[0].message.?);
}

test "a nested message's CEL rule names its field, and its string result is the message" {
    var checked: Checked = undefined;
    var message = valid();
    message.e = .{ .a = 1, .b = 1 };
    const violations = try checked.of(Outer, &message);
    try walk_test.expect_one(violations, "e", "", "nested");
    try testing.expectEqualStrings("a must be greater than b", violations[0].message.?);
}

test "a field's CEL rule names the field and the rule's place among the field's rules" {
    var checked: Checked = undefined;
    var message = valid();
    message.val = 1;
    try walk_test.expect_one(try checked.of(Outer, &message), "val", "cel[1]", "second");
    try testing.expectEqualStrings("val must be over 1", checked.report.violations()[0].message.?);
    message.val = 0;
    const both = try checked.of(Outer, &message);
    try testing.expectEqual(@as(usize, 2), both.len);
    try walk_test.expect_violation(both[0], "val", "cel[0]", "first");
    try walk_test.expect_violation(both[1], "val", "cel[1]", "second");
    message.val = 5;
    try walk_test.expect_one(try checked.of(Outer, &message), "val", "cel_expression[0]", "this != 5");
    // The CEL rules come before the rules of the field's type.
    message.val = Outer.max;
    try walk_test.expect_one(try checked.of(Outer, &message), "val", "int32.lt", "int32.lt");
    // A field with presence that is not set has no value to check, and one that is set has.
    message = valid();
    message.name = "mel";
    try walk_test.expect_one(try checked.of(Outer, &message), "name", "cel[0]", "named");
    const rule = checked.report.violations()[0].rule.?.elements.items[0];
    const cel_number = 23;
    try testing.expectEqual(@as(?i32, cel_number), rule.field_number);
    try testing.expectEqual(@as(?table.Type, .type_message), rule.field_type);
}

const Dividing = struct {
    value: i32 = 0,
    div: i32 = 0,
    at: ?proto.wkt.Timestamp = null,
    pub const FieldNumber = enum(u29) { value = 1, div = 2, at = 3 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Dividing", .fields = &.{
        proto.field_of(FieldNumber.value, .int32, .{}), proto.field_of(FieldNumber.div, .int32, .{}), proto.field_of(FieldNumber.at, .message, .{}),
    } };
    pub const protovalidate: Rules = .{
        .message = .{ .cel = .of(&.{.{ .id = "divides", .message = "div must divide value", .expression = "this.value % this.div == 0" }}) },
        .fields = &.{.{ .number = @intFromEnum(FieldNumber.at), .rules = .{ .cel = .of(&.{.{ .id = "past", .message = "at must be in the past", .expression = "this < now" }}) } }},
    };
};

const Dynamic = struct {
    a: i32 = 0,
    pub const FieldNumber = enum(u29) { a = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Dynamic", .fields = &.{proto.field_of(FieldNumber.a, .int32, .{})} };
    pub const protovalidate: Rules = .{ .message = .{ .cel = .of(&.{.{ .id = "dyn", .expression = "dyn(this).b == 'foo'" }}) } };
};

fn outcome(comptime T: type, message: *const T, options: validate_file.Options) validate_file.Error!void {
    var storage: [constants.report_bytes_default]u8 align(report_file.storage_alignment) = undefined;
    var report: report_file.Report = .init(&storage);
    return validate_file.validate(T, message, options, &report);
}

test "an expression that fails as it runs ends validate with Unevaluable" {
    try outcome(Dividing, &.{ .value = 6, .div = 3 }, .{});
    try testing.expectError(error.Invalid, outcome(Dividing, &.{ .value = 7, .div = 3 }, .{}));
    try testing.expectError(error.Unevaluable, outcome(Dividing, &.{ .value = 7, .div = 0 }, .{}));
    try testing.expectError(error.Unevaluable, outcome(Dynamic, &.{ .a = 1 }, .{}));
}

test "a rule that reads now takes the caller's time, and fails without it" {
    const then: Dividing = .{ .div = 1, .at = .{ .seconds = 5 } };
    try testing.expectError(error.TimeMissing, outcome(Dividing, &then, .{}));
    try outcome(Dividing, &then, .{ .now = .{ .seconds = 6 } });
    try testing.expectError(error.Invalid, outcome(Dividing, &then, .{ .now = .{ .seconds = 5 } }));
    // A timestamp that is not set has no value for the rule.
    try outcome(Dividing, &.{ .div = 1 }, .{});
}

const PairsEntry = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Lists.PairsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

const Lists = struct {
    numbers: proto.Repeated(i32, .int32) = .{},
    pairs: proto.Repeated(PairsEntry, .message) = .{},
    pub const FieldNumber = enum(u29) { numbers = 1, pairs = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Lists", .fields = &.{
        proto.field_of(FieldNumber.numbers, .int32, .{}), proto.field_of(FieldNumber.pairs, .message, .{}),
    } };
    const item: pb.FieldRules = .{ .cel = .of(&.{.{ .id = "item", .message = "an item must be positive", .expression = "this > 0" }}) };
    const key: pb.FieldRules = .{ .cel = .of(&.{.{ .id = "key", .message = "a key must not be bad", .expression = "this != 'bad'" }}) };
    const value: pb.FieldRules = .{ .cel_expression = .of(&.{"this < 10"}) };
    /// The first value that the rule of a map's values refuses.
    const limit = 10;
    pub const protovalidate: Rules = .{ .fields = &.{
        .{ .number = @intFromEnum(FieldNumber.numbers), .rules = .{
            .cel = .of(&.{.{ .id = "sized", .message = "numbers must hold two", .expression = "this.size() == 2" }}),
            .type = .{ .repeated = .of(&.{ .items = .of(&item) }) },
        } },
        .{ .number = @intFromEnum(FieldNumber.pairs), .rules = .{
            .cel = .of(&.{.{ .id = "summed", .message = "each value must be positive", .expression = "this.all(k, this[k] > 0)" }}),
            .type = .{ .map = .of(&.{ .keys = .of(&key), .values = .of(&value) }) },
        } },
    } };
};

test "a list's own CEL rule reads the whole list, and an element's rule each element" {
    var checked: Checked = undefined;
    const two = 2;
    try testing.expectEqual(@as(usize, 0), (try checked.of(Lists, &.{ .numbers = .of(&.{ 1, two }) })).len);
    try walk_test.expect_one(try checked.of(Lists, &.{ .numbers = .of(&.{1}) }), "numbers", "cel[0]", "sized");
    // An element's rule lies under `repeated.items` in the field's rules.
    try walk_test.expect_one(try checked.of(Lists, &.{ .numbers = .of(&.{ 1, 0 }) }), "numbers[1]", "repeated.items.cel[0]", "item");
    try testing.expectEqualStrings("an item must be positive", checked.report.violations()[0].message.?);
}

/// A map alone would break the rule of `numbers`, which an empty list does not keep.
fn with_pairs(pairs: []const PairsEntry) Lists {
    const numbers = comptime [_]i32{ 1, 1 };
    return .{ .numbers = .of(&numbers), .pairs = .of(pairs) };
}

test "a map's own CEL rule reads the whole map, and a key's and a value's rule each entry" {
    var checked: Checked = undefined;
    try testing.expectEqual(@as(usize, 0), (try checked.of(Lists, &with_pairs(&.{.{ .key = "k", .value = 1 }}))).len);
    try walk_test.expect_one(try checked.of(Lists, &with_pairs(&.{.{ .key = "k", .value = 0 }})), "pairs", "cel[0]", "summed");
    const keyed = try checked.of(Lists, &with_pairs(&.{.{ .key = "bad", .value = 1 }}));
    try walk_test.expect_one(keyed, "pairs[\"bad\"]", "map.keys.cel[0]", "key");
    try testing.expectEqual(@as(?bool, true), keyed[0].for_key);
    const valued = try checked.of(Lists, &with_pairs(&.{.{ .key = "k", .value = Lists.limit }}));
    try walk_test.expect_one(valued, "pairs[\"k\"]", "map.values.cel_expression[0]", "this < 10");
    try testing.expectEqual(@as(?bool, null), valued[0].for_key);
    // A list with no element is read by its own rule too: it has no presence to skip it by.
    try walk_test.expect_one(try checked.of(Lists, &.{}), "numbers", "cel[0]", "sized");
}
