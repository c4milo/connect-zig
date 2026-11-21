//! Tests of predefined rules: an extension of a rule message, whose CEL rules read the field's
//! value as `this`, the extension's value as `rule` and the rule message as `rules`
//! (validate.proto, PredefinedRules). The tables are written as the plugin writes them.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("../table.zig");
const check_file = @import("../check.zig");
const walk_test = @import("../validate_test.zig");
const Rules = table.Rules;
const Predefined = Rules.Predefined;
const Checked = walk_test.Checked;

/// The numbers of the extensions, as a schema gives them.
const even_number = 1161;
const abs_in_number = 1162;
const five = 5;
const limit = 100;

const even: Predefined = .{ .number = even_number, .name = "t.even", .type = .type_bool, .value = .{ .boolean = true }, .cel = &.{
    .{ .id = "int32.even", .message = "must be even", .expression = "!rule || this % 2 == 0" },
} };
const abs_in: Predefined = .{
    .number = abs_in_number,
    .name = "t.abs_in",
    .type = .type_int32,
    .value = .{ .ints = &.{ -two, five } },
    .cel = &.{
        .{ .id = "int32.abs_in", .message = "must be in absolute value of list", .expression = "this in rule || this in rule.map(n, -n)" },
        // A second rule of one extension, which reads the rule message beside it.
        .{ .id = "int32.under", .expression = "has(rules.lt) && this < rules.lt ? '' : 'must be under the limit'" },
    },
};

const TagsEntry = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message.TagsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

const Message = struct {
    val: i32 = 0,
    items: proto.Repeated(i32, .int32) = .{},
    tags: proto.Repeated(TagsEntry, .message) = .{},
    pub const FieldNumber = enum(u29) { val = 1, items = 2, tags = 3 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.val, .int32, .{}), proto.field_of(FieldNumber.items, .int32, .{}), proto.field_of(FieldNumber.tags, .message, .{}),
    } };
    const number: pb.FieldRules = .{ .type = .{ .int32 = .{} } };
    const text: pb.FieldRules = .{ .type = .{ .string = .{} } };
    const at_least: Predefined = .{ .number = even_number, .name = "t.at_least", .type = .type_uint64, .value = .{ .uint = two }, .cel = &.{
        .{ .id = "repeated.at_least", .message = "must hold more items", .expression = "uint(this.size()) >= rule" },
    } };
    const prefixed: Predefined = .{ .site = .keys, .number = even_number, .name = "t.prefixed", .type = .type_string, .value = .{ .string = "k" }, .cel = &.{
        .{ .id = "string.prefixed", .message = "must start with the prefix", .expression = "this.startsWith(rule)" },
    } };
    pub const protovalidate: Rules = .{ .fields = &.{
        .{ .number = @intFromEnum(FieldNumber.val), .rules = .{ .type = .{ .int32 = .{ .less_than = .{ .lt = limit } } } }, .predefined = &.{ even, abs_in } },
        .{ .number = @intFromEnum(FieldNumber.items), .rules = .{ .type = .{ .repeated = .of(&.{ .items = .of(&number) }) } }, .predefined = &.{ at_least, on(.items, even) } },
        .{ .number = @intFromEnum(FieldNumber.tags), .rules = .{ .type = .{ .map = .of(&.{ .keys = .of(&text), .values = .of(&number) }) } }, .predefined = &.{ prefixed, on(.values, even) } },
    } };
};

/// `entry` at another site of its field's rules.
fn on(comptime site: Predefined.Where, comptime entry: Predefined) Predefined {
    var moved = entry;
    moved.site = site;
    return moved;
}

const two = 2;

fn valid() Message {
    const items = comptime [_]i32{ two, two };
    return .{ .val = two, .items = .of(&items), .tags = .of(&.{.{ .key = "k1", .value = two }}) };
}

test "a predefined rule reads the field's value, the extension's value and the rule message" {
    var checked: Checked = undefined;
    try testing.expectEqual(@as(usize, 0), (try checked.of(Message, &valid())).len);
    var message = valid();
    // 5 is in the list, and is not even.
    message.val = five;
    try walk_test.expect_one(try checked.of(Message, &message), "val", "int32.[t.even]", "int32.even");
    try testing.expectEqualStrings("must be even", checked.report.violations()[0].message.?);
    const rule = checked.report.violations()[0].rule.?.elements.items[1];
    try testing.expectEqual(@as(?i32, even_number), rule.field_number);
    try testing.expectEqual(@as(?table.Type, .type_bool), rule.field_type);
    // -2 is the negation of no element but is an element, and 4 is neither.
    message.val = -two;
    try testing.expectEqual(@as(usize, 0), (try checked.of(Message, &message)).len);
    message.val = two + two;
    try walk_test.expect_one(try checked.of(Message, &message), "val", "int32.[t.abs_in]", "int32.abs_in");
    try testing.expectEqualStrings("must be in absolute value of list", checked.report.violations()[0].message.?);
}

test "an extension's second rule reads the rule message as rules" {
    var checked: Checked = undefined;
    var message = valid();
    // 100 is even and not in the list, and is not under `int32.lt`, which its own rule reads too.
    message.val = limit;
    const violations = try checked.of(Message, &message);
    const count = 3;
    try testing.expectEqual(@as(usize, count), violations.len);
    try walk_test.expect_violation(violations[0], "val", "int32.[t.abs_in]", "int32.abs_in");
    try walk_test.expect_violation(violations[1], "val", "int32.[t.abs_in]", "int32.under");
    try testing.expectEqualStrings("must be under the limit", violations[1].message.?);
    try walk_test.expect_violation(violations[2], "val", "int32.lt", "int32.lt");
}

test "a predefined rule of a list, of its elements, and of a map's keys and values" {
    var checked: Checked = undefined;
    var message = valid();
    message.items = .of(&.{two});
    try walk_test.expect_one(try checked.of(Message, &message), "items", "repeated.[t.at_least]", "repeated.at_least");
    message.items = .of(&.{ two, five });
    try walk_test.expect_one(try checked.of(Message, &message), "items[1]", "repeated.items.int32.[t.even]", "int32.even");
    message = valid();
    message.tags = .of(&.{.{ .key = "x1", .value = two }});
    const keyed = try checked.of(Message, &message);
    try walk_test.expect_one(keyed, "tags[\"x1\"]", "map.keys.string.[t.prefixed]", "string.prefixed");
    try testing.expectEqual(@as(?bool, true), keyed[0].for_key);
    message.tags = .of(&.{.{ .key = "k1", .value = five }});
    const valued = try checked.of(Message, &message);
    try walk_test.expect_one(valued, "tags[\"k1\"]", "map.values.int32.[t.even]", "int32.even");
    try testing.expectEqual(@as(?bool, null), valued[0].for_key);
}

fn One(comptime entry: Predefined, comptime rules: pb.FieldRules) type {
    return struct {
        val: i32 = 0,
        pub const FieldNumber = enum(u29) { val = 1 };
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.One", .fields = &.{proto.field_of(FieldNumber.val, .int32, .{})} };
        pub const protovalidate: Rules = .{ .fields = &.{.{ .number = 1, .rules = rules, .predefined = &.{entry} }} };
    };
}

fn expect_problem(comptime entry: Predefined, comptime rules: pb.FieldRules, comptime expected: []const u8) !void {
    const problem = comptime check_file.rules_error(One(entry, rules));
    try testing.expect(std.mem.indexOf(u8, problem orelse return error.TestExpectedProblem, expected) != null);
}

/// `even` with one rule of `expression` in the place of its own.
fn with_rule(comptime expression: []const u8) Predefined {
    var changed = even;
    changed.cel = &.{.{ .id = "a", .expression = expression }};
    return changed;
}

test "a predefined rule that does not compile stops the type" {
    const typed: pb.FieldRules = .{ .type = .{ .int32 = .{} } };
    try testing.expect(comptime check_file.rules_error(One(even, typed)) == null);
    try expect_problem(with_rule("this.startsWith(rule)"), typed, "t.One.val: (t.even): `this.startsWith(rule)`: found no matching overload for `startsWith` applied to (int, bool)");
    try testing.expect(comptime check_file.rules_error(One(with_rule("rule"), typed)) == null);
    try expect_problem(with_rule("this"), typed, "(t.even): `this`: a rule's expression gives a bool or a string, not a int");
    try expect_problem(with_rule("rules.missing"), typed, "undefined field `missing` of buf.validate.Int32Rules");
    // An extension lies in a rule message, which the field's rules must hold.
    try expect_problem(even, .{}, "a predefined rule's extension has no rule message to lie in");
}
