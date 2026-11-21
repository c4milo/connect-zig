//! More tests of the walk: a message's `oneof` rules, `required` and `ignore` on repeated
//! fields and maps and on their elements, and the lists and maps too long to compare.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("table.zig");
const constants = @import("constants.zig");
const check_file = @import("check.zig");
const support = @import("rule_test_support.zig");
const validate_test = @import("validate_test.zig");
const Rules = table.Rules;
const expect = support.expect;
const expect_one = validate_test.expect_one;

const positive: pb.FieldRules = .{ .type = .{ .int32 = .{ .greater_than = .{ .gt = 0 } } } };

/// A message with a field of each shape, which `(buf.validate.message).oneof` rules name.
const Choice = struct {
    plain: i32 = 0,
    text: []const u8 = "",
    maybe: ?i32 = null,
    list: proto.Repeated(i32, .int32) = .{},
    held: ?union(enum) { first: i32, second: i32 } = null,
    again: proto.Lazy(Choice) = .{},

    pub const FieldNumber = enum(u29) { plain = 1, text = 2, maybe = 3, list = 4, first = 5, second = 6, again = 7 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Choice", .fields = &.{
        proto.field_of(FieldNumber.plain, .int32, .{}),
        proto.field_of(FieldNumber.text, .string, .{}),
        proto.field_of(FieldNumber.maybe, .int32, .{}),
        proto.field_of(FieldNumber.list, .int32, .{}),
        proto.field_of(FieldNumber.first, .int32, .{ .oneof = "held" }),
        proto.field_of(FieldNumber.second, .int32, .{ .oneof = "held" }),
        proto.field_of(FieldNumber.again, .message, .{}),
    } };
    pub const protovalidate: Rules = .{
        .message = .{ .oneof = .of(&.{
            .{ .fields = .of(&.{ "plain", "text", "maybe" }), .required = true },
            .{ .fields = .of(&.{ "list", "first", "again" }) },
        }) },
        // A oneof whose rules state no `required` asks for no member.
        .oneofs = &.{.{ .field = "held", .name = "held", .rules = .{} }},
        .fields = &.{
            // A field a oneof rule names takes IGNORE_IF_ZERO_VALUE unless it states an ignore.
            .{ .number = @intFromEnum(FieldNumber.plain), .rules = positive },
            .{ .number = @intFromEnum(FieldNumber.text), .rules = .{ .ignore = .ignore_unspecified, .type = .{ .string = .{ .min_len = 1 } } } },
        },
    };
};

test "a message's oneof rule takes at most one of its fields, and one when it is required" {
    var checked: validate_test.Checked = undefined;
    var message: Choice = .{ .plain = 1, .text = "a" };
    try expect_one(try checked.of(Choice, &message), "", "", "message.oneof");
    try testing.expectEqualStrings("only one of plain, text, maybe can be set", checked.report.violations()[0].message.?);
    try testing.expect(checked.report.violations()[0].field == null);
    message = .{ .text = "a" };
    try testing.expectEqual(@as(usize, 0), (try checked.of(Choice, &message)).len);
    // None of the required three is set: `text` then breaks its own rule too, since it states
    // an ignore of its own, and `plain` does not.
    message = .{};
    const violations = try checked.of(Choice, &message);
    try testing.expectEqual(@as(usize, 2), violations.len);
    try testing.expectEqualStrings("message.oneof", violations[0].rule_id.?);
    try testing.expectEqualStrings("one of plain, text, maybe must be set", violations[0].message.?);
    try testing.expectEqualStrings("string.min_len", violations[1].rule_id.?);
}

test "a field is set by its presence, or by a value that is not zero when it has none" {
    var checked: validate_test.Checked = undefined;
    // An optional that holds zero is set, and counts beside a string that is not empty.
    var message: Choice = .{ .text = "a", .maybe = 0 };
    try expect_one(try checked.of(Choice, &message), "", "", "message.oneof");
    // The second rule is not required: none of its fields is as good as one.
    message = .{ .text = "a", .list = .of(&.{1}) };
    try testing.expectEqual(@as(usize, 0), (try checked.of(Choice, &message)).len);
    message = .{ .text = "a", .list = .of(&.{1}), .held = .{ .first = 0 } };
    try expect_one(try checked.of(Choice, &message), "", "", "message.oneof");
    // Another member of the union is not the field the rule names.
    message = .{ .text = "a", .list = .of(&.{1}), .held = .{ .second = 1 } };
    try testing.expectEqual(@as(usize, 0), (try checked.of(Choice, &message)).len);
    const inner: Choice = .{ .text = "a" };
    message = .{ .text = "a", .held = .{ .first = 1 }, .again = .of(&inner) };
    try expect_one(try checked.of(Choice, &message), "", "", "message.oneof");
    // A violation inside a message names the field that holds the message.
    const broken: Choice = .{ .plain = 1, .text = "a" };
    message = .{ .text = "a", .again = .of(&broken) };
    try expect_one(try checked.of(Choice, &message), "again", "", "message.oneof");
}

const List = proto.Repeated(i32, .int32);

fn list_rules(comptime rules: pb.RepeatedRules, comptime outer: pb.FieldRules) pb.FieldRules {
    var all = outer;
    all.type = .{ .repeated = .of(&rules) };
    return all;
}

test "required and ignore read a repeated field by whether it holds an element" {
    const sized = comptime list_rules(.{ .min_items = 2 }, .{});
    try expect(List, .int32, sized, .{}, "repeated.min_items");
    try expect(List, .int32, comptime list_rules(.{ .min_items = 2 }, .{ .ignore = .ignore_if_zero_value }), .{}, "");
    try expect(List, .int32, comptime list_rules(.{ .min_items = 2 }, .{ .ignore = .ignore_if_zero_value }), .of(&.{1}), "repeated.min_items");
    try expect(List, .int32, comptime list_rules(.{ .min_items = 2 }, .{ .required = true }), .{}, "required");
    try expect(List, .int32, comptime list_rules(.{ .min_items = 2 }, .{ .required = true }), .of(&.{1}), "repeated.min_items");
    try expect(List, .int32, comptime list_rules(.{ .min_items = 2 }, .{ .ignore = .ignore_always, .required = true }), .{}, "");
    try expect(List, .int32, comptime .{ .required = true }, .{}, "required");
    try expect(List, .int32, comptime .{ .required = true }, .of(&.{0}), "");
}

test "an element's rules follow the ignore of repeated.items" {
    const items = comptime positive;
    try expect(List, .int32, comptime list_rules(.{ .items = .of(&items) }, .{}), .of(&.{ 0, 1, -1 }), "int32.gt int32.gt");
    const skips_zero: pb.FieldRules = comptime .{ .ignore = .ignore_if_zero_value, .type = positive.type };
    try expect(List, .int32, comptime list_rules(.{ .items = .of(&skips_zero) }, .{}), .of(&.{ 0, 1, -1 }), "int32.gt");
    const never: pb.FieldRules = comptime .{ .ignore = .ignore_always, .type = positive.type };
    try expect(List, .int32, comptime list_rules(.{ .items = .of(&never) }, .{}), .of(&.{ 0, 1, -1 }), "");
    // An element is always set, so `required` asks nothing of it.
    const required: pb.FieldRules = comptime .{ .required = true };
    try expect(List, .int32, comptime list_rules(.{ .items = .of(&required) }, .{}), .of(&.{0}), "");
}

test "unique compares strings by their octets, and floats by value" {
    const Names = proto.Repeated([]const u8, .string);
    const unique = comptime list_rules(.{ .unique = true }, .{});
    try expect(Names, .string, unique, .of(&.{ "a", "b", "ab" }), "");
    // Two strings of the same octets, each at a place of its own.
    const letters = [_]u8{ 'a', 'a' };
    try expect(Names, .string, unique, .of(&.{ letters[0..1], "b", letters[1..] }), "repeated.unique");
    try expect(Names, .string, comptime list_rules(.{ .unique = false }, .{}), .of(&.{ "a", "a" }), "");
    const Floats = proto.Repeated(f64, .double);
    try expect(Floats, .double, unique, .of(&.{ 1.5, 2.5 }), "");
    try expect(Floats, .double, unique, .of(&.{ 1.5, 1.5 }), "repeated.unique");
    // A list of messages has no unique rule: CEL's `unique` reads scalars.
    const Messages = proto.Repeated(validate_test.Inner, .message);
    const problem = (comptime check_file.rules_error(support.One(Messages, .message, unique))) orelse return error.TestExpectedProblem;
    try testing.expect(std.mem.indexOf(u8, problem, "repeated.unique on a field of messages") != null);
}

const Pair = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Pair", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};
const Map = proto.Repeated(Pair, .message);

fn map_rules(comptime rules: pb.MapRules, comptime outer: pb.FieldRules) pb.FieldRules {
    var all = outer;
    all.type = .{ .map = .of(&rules) };
    return all;
}

test "required and ignore read a map by whether it holds an entry" {
    try expect(Map, .message, comptime map_rules(.{ .min_pairs = 1 }, .{}), .{}, "map.min_pairs");
    try expect(Map, .message, comptime map_rules(.{ .min_pairs = 1 }, .{ .ignore = .ignore_if_zero_value }), .{}, "");
    try expect(Map, .message, comptime map_rules(.{ .min_pairs = 2 }, .{ .ignore = .ignore_if_zero_value }), .of(&.{.{ .key = "a" }}), "map.min_pairs");
    try expect(Map, .message, comptime map_rules(.{ .min_pairs = 1 }, .{ .required = true }), .{}, "required");
    try expect(Map, .message, comptime .{ .required = true }, .{}, "required");
    try expect(Map, .message, comptime .{ .required = true }, .of(&.{.{}}), "");
    try expect(Map, .message, comptime map_rules(.{ .min_pairs = 1 }, .{ .ignore = .ignore_always }), .{}, "");
}

test "a key's and a value's rules follow the ignore of map.keys and of map.values" {
    const short: pb.FieldRules = comptime .{ .type = .{ .string = .{ .min_len = 2 } } };
    const entries: Map = .of(&.{ .{ .key = "", .value = 0 }, .{ .key = "a", .value = -1 } });
    try expect(Map, .message, comptime map_rules(.{ .keys = .of(&short), .values = .of(&positive) }, .{}), entries, "string.min_len int32.gt string.min_len int32.gt");
    const short_or_empty: pb.FieldRules = comptime .{ .ignore = .ignore_if_zero_value, .type = short.type };
    const positive_or_zero: pb.FieldRules = comptime .{ .ignore = .ignore_if_zero_value, .type = positive.type };
    try expect(Map, .message, comptime map_rules(.{ .keys = .of(&short_or_empty), .values = .of(&positive) }, .{}), entries, "int32.gt string.min_len int32.gt");
    try expect(Map, .message, comptime map_rules(.{ .keys = .of(&short), .values = .of(&positive_or_zero) }, .{}), entries, "string.min_len string.min_len int32.gt");
    const no_key: pb.FieldRules = comptime .{ .ignore = .ignore_always, .type = short.type };
    const no_value: pb.FieldRules = comptime .{ .ignore = .ignore_always, .type = positive.type };
    try expect(Map, .message, comptime map_rules(.{ .keys = .of(&no_key), .values = .of(&positive) }, .{}), entries, "int32.gt int32.gt");
    try expect(Map, .message, comptime map_rules(.{ .keys = .of(&short), .values = .of(&no_value) }, .{}), entries, "string.min_len string.min_len");
}

test "a map too long to compare is read entry by entry, and refused when min_pairs counts it" {
    const Numbered = struct {
        key: u32 = 0,
        value: i32 = 0,
        pub const FieldNumber = enum(u29) { key = 1, value = 2 };
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.Numbered", .map_entry = true, .fields = &.{
            proto.field_of(FieldNumber.key, .uint32, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
        } };
    };
    const Long = proto.Repeated(Numbered, .message);
    var entries: [constants.compared_items_max + 1]Numbered = undefined;
    // Every entry holds key 7, and the last alone has a value that passes.
    for (&entries, 0..) |*entry, index| entry.* = .{ .key = 7, .value = if (index == entries.len - 1) 1 else -1 };
    const at_limit: Long = .of(entries[1..]);
    const over: Long = .of(&entries);
    const values = comptime map_rules(.{ .values = .of(&positive) }, .{});
    // At the limit the map is one pair, whose value is the last entry's.
    try expect(Long, .message, values, at_limit, "");
    try expect(Long, .message, comptime map_rules(.{ .max_pairs = 1, .values = .of(&positive) }, .{}), at_limit, "");
    try expect(Long, .message, comptime map_rules(.{ .min_pairs = 2 }, .{}), at_limit, "map.min_pairs");
    // Past it every entry is read, which the small report here cannot hold.
    try expect(Long, .message, comptime map_rules(.{ .max_pairs = 1 }, .{}), over, "map.max_pairs");
    try testing.expectError(error.TooManyItems, expect(Long, .message, comptime map_rules(.{ .min_pairs = 2 }, .{}), over, ""));
    // A key's subscript is unsigned for an unsigned key.
    var checked: validate_test.Checked = undefined;
    const one: support.One(Long, .message, values) = .{ .val = .of(&.{.{ .key = 7, .value = -1 }}) };
    const violations = try checked.of(@TypeOf(one), &one);
    try testing.expectEqual(@as(u64, 7), violations[0].field.?.elements.items[0].subscript.?.uint_key);
}
