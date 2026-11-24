//! Tests of the walk: messages written by hand, as the plugin writes them, and the violations
//! `validate` reports for each: the field's path, the rule's path and the rule's id.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
/// The tests decode and encode with the build target's CPU features.
const protobuf_decoder: proto.Decoder = .init(.target());
const pb = @import("buf_validate_validate");
const table = @import("table.zig");
const constants = @import("constants.zig");
const report_file = @import("report.zig");
const validate_file = @import("validate.zig");
const Rules = table.Rules;
const Report = report_file.Report;
const validate = validate_file.validate;

const positive: pb.FieldRules = .{ .type = .{ .int32 = .{ .greater_than = .{ .gt = 0 } } } };

pub const Inner = struct {
    count: i32 = 0,
    pub const FieldNumber = enum(u29) { count = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Inner", .fields = &.{proto.field_of(FieldNumber.count, .int32, .{})} };
    pub const protovalidate: Rules = .{ .fields = &.{.{ .number = 1, .rules = positive }} };
};

const Entry = struct {
    key: i32 = 0,
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Outer.PairsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .sint32, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

const NamedEntry = struct {
    key: []const u8 = "",
    value: ?Inner = null,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Outer.NamedEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .message, .{}),
    } };
};

pub const Outer = struct {
    id: i32 = 0,
    maybe: ?i32 = null,
    inner: ?Inner = null,
    items: proto.Repeated(i32, .int32) = .{},
    inners: proto.Repeated(Inner, .message) = .{},
    choice: ?union(enum) { first: i32, second: i32, third: proto.Lazy(Outer) } = null,
    pairs: proto.Repeated(Entry, .message) = .{},
    named: proto.Repeated(NamedEntry, .message) = .{},
    again: proto.Lazy(Outer) = .{},
    skipped: ?Inner = null,
    light: i32 = 0,

    pub const FieldNumber = enum(u29) { id = 1, maybe = 2, inner = 3, items = 4, inners = 5, first = 6, second = 7, third = 8, pairs = 9, named = 10, again = 11, skipped = 12, light = 13 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Outer", .fields = &.{
        proto.field_of(FieldNumber.id, .int32, .{}),
        proto.field_of(FieldNumber.maybe, .int32, .{}),
        proto.field_of(FieldNumber.inner, .message, .{}),
        proto.field_of(FieldNumber.items, .int32, .{}),
        proto.field_of(FieldNumber.inners, .message, .{}),
        proto.field_of(FieldNumber.first, .int32, .{ .oneof = "choice" }),
        proto.field_of(FieldNumber.second, .int32, .{ .oneof = "choice" }),
        proto.field_of(FieldNumber.third, .message, .{ .oneof = "choice" }),
        proto.field_of(FieldNumber.pairs, .message, .{}),
        proto.field_of(FieldNumber.named, .message, .{}),
        proto.field_of(FieldNumber.again, .message, .{}),
        proto.field_of(FieldNumber.skipped, .message, .{}),
        proto.field_of(FieldNumber.light, .int32, .{}),
    } };

    /// The numbers of the rules, named as the plugin names them (decision 17).
    pub const RuleNumber = struct {
        pub const maybe_lt = 10;
        pub const items_max = 3;
        pub const pairs_max = 2;
        pub const light_gte = 5;
    };
    const list_rules: pb.RepeatedRules = .{ .min_items = 1, .max_items = RuleNumber.items_max, .unique = true, .items = .of(&positive) };
    const map_rules: pb.MapRules = .{ .min_pairs = 1, .max_pairs = RuleNumber.pairs_max, .keys = .of(&positive_key), .values = .of(&positive) };
    const positive_key: pb.FieldRules = .{ .type = .{ .sint32 = .{ .greater_than = .{ .gt = 0 } } } };
    pub const protovalidate: Rules = .{
        .fields = &.{
            .{ .number = @intFromEnum(FieldNumber.id), .rules = .{ .required = true, .type = .{ .int32 = .{ .greater_than = .{ .gt = 0 } } } } },
            .{ .number = @intFromEnum(FieldNumber.maybe), .rules = .{ .type = .{ .int32 = .{ .less_than = .{ .lt = RuleNumber.maybe_lt } } } } },
            .{ .number = @intFromEnum(FieldNumber.inner), .rules = .{ .required = true } },
            .{ .number = @intFromEnum(FieldNumber.items), .rules = .{ .type = .{ .repeated = .of(&list_rules) } } },
            .{ .number = @intFromEnum(FieldNumber.first), .rules = positive },
            .{ .number = @intFromEnum(FieldNumber.pairs), .rules = .{ .type = .{ .map = .of(&map_rules) } } },
            .{ .number = @intFromEnum(FieldNumber.skipped), .rules = .{ .ignore = .ignore_always } },
            .{ .number = @intFromEnum(FieldNumber.light), .rules = .{ .ignore = .ignore_if_zero_value, .type = .{ .int32 = .{ .greater_than = .{ .gte = RuleNumber.light_gte } } } } },
        },
        .oneofs = &.{.{ .field = "choice", .name = "choice", .rules = .{ .required = true } }},
    };
};

/// A message that every rule of `Outer` passes.
pub fn valid() Outer {
    return .{
        .id = 1,
        .inner = .{ .count = 1 },
        .items = .of(&.{1}),
        .choice = .{ .first = 1 },
        .pairs = .of(&.{.{ .key = 1, .value = 1 }}),
    };
}

pub const Checked = struct {
    storage: [constants.report_bytes_default]u8 align(report_file.storage_alignment),
    report: Report,

    /// The violations of `message`, or none when it passes.
    pub fn of(checked: *Checked, comptime T: type, message: *const T) ![]const pb.Violation {
        checked.report = .init(&checked.storage);
        validate(T, message, .{ .cpu_features = .target() }, &checked.report) catch |failure| switch (failure) {
            error.Invalid => return checked.report.violations(),
            else => return failure,
        };
        try testing.expectEqual(@as(usize, 0), checked.report.violations().len);
        return &.{};
    }
};

/// A path as the conformance suite writes one: "inner.count", "items[1]", "pairs[-2]".
pub fn path_text(buffer: []u8, path: ?pb.FieldPath) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const elements = if (path) |set| set.elements.items else return "";
    for (elements, 0..) |element, index| {
        writer.print("{s}{s}", .{ if (index == 0) "" else ".", element.field_name.? }) catch unreachable;
        if (element.subscript) |subscript| write_subscript(&writer, subscript) catch unreachable;
    }
    return writer.buffered();
}

fn write_subscript(writer: *std.Io.Writer, subscript: @typeInfo(@FieldType(pb.FieldPathElement, "subscript")).optional.child) !void {
    switch (subscript) {
        .index, .uint_key => |number| try writer.print("[{d}]", .{number}),
        .int_key => |number| try writer.print("[{d}]", .{number}),
        .bool_key => |key| try writer.print("[{}]", .{key}),
        .string_key => |key| try writer.print("[\"{s}\"]", .{key}),
    }
}

/// Requires one violation, of the rule `id` at the rule path `rule`, by the field at `field`.
pub fn expect_one(violations: []const pb.Violation, field: []const u8, rule: []const u8, id: []const u8) !void {
    try testing.expectEqual(@as(usize, 1), violations.len);
    try expect_violation(violations[0], field, rule, id);
}

/// The longest path a test writes as text.
const path_text_len_max = 256;

pub fn expect_violation(violation: pb.Violation, field: []const u8, rule: []const u8, id: []const u8) !void {
    var buffer: [path_text_len_max]u8 = undefined;
    try testing.expectEqualStrings(field, path_text(&buffer, violation.field));
    try testing.expectEqualStrings(rule, path_text(&buffer, violation.rule));
    try testing.expectEqualStrings(id, violation.rule_id.?);
}

test "a message that keeps every rule passes, and a type with no table passes" {
    var checked: Checked = undefined;
    const message = valid();
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &message)).len);
    try testing.expect(!checked.report.truncated);
    const plain: Entry = .{};
    try testing.expectEqual(@as(usize, 0), (try checked.of(Entry, &plain)).len);
}

test "a value with no presence breaks required at its zero value, and its other rules elsewhere" {
    var checked: Checked = undefined;
    var message = valid();
    message.id = 0;
    try expect_one(try checked.of(Outer, &message), "id", "required", "required");
    try testing.expectEqualStrings("value is required", checked.report.violations()[0].message.?);
    message.id = -1;
    try expect_one(try checked.of(Outer, &message), "id", "int32.gt", "int32.gt");
    try testing.expectEqualStrings("must be greater than 0", checked.report.violations()[0].message.?);
    const element = checked.report.violations()[0].field.?.elements.items[0];
    try testing.expectEqual(@as(?i32, 1), element.field_number);
    try testing.expectEqual(@as(?table.Type, .type_int32), element.field_type);
    try testing.expect(element.subscript == null and element.key_type == null);
}

test "a field with presence passes its rules while it is not set, and breaks required" {
    var checked: Checked = undefined;
    var message = valid();
    message.maybe = 10;
    try expect_one(try checked.of(Outer, &message), "maybe", "int32.lt", "int32.lt");
    message.maybe = 0;
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &message)).len);
    message.maybe = null;
    message.inner = null;
    try expect_one(try checked.of(Outer, &message), "inner", "required", "required");
    try testing.expectEqual(@as(?table.Type, .type_message), checked.report.violations()[0].field.?.elements.items[0].field_type);
}

test "IGNORE_IF_ZERO_VALUE passes over a zero value, and IGNORE_ALWAYS over the field and its message" {
    var checked: Checked = undefined;
    var message = valid();
    message.light = 0;
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &message)).len);
    message.light = 4;
    try expect_one(try checked.of(Outer, &message), "light", "int32.gte", "int32.gte");
    message.light = 5;
    // `skipped` holds a message that breaks its own rule, which IGNORE_ALWAYS never reads.
    message.skipped = .{ .count = -1 };
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &message)).len);
}

test "a message a field holds is checked against its own table, under the field's path" {
    var checked: Checked = undefined;
    var message = valid();
    message.inner = .{ .count = 0 };
    try expect_one(try checked.of(Outer, &message), "inner.count", "int32.gt", "int32.gt");
    message.inner = .{ .count = 1 };
    message.inners = .of(&.{ .{ .count = 1 }, .{ .count = -1 } });
    try expect_one(try checked.of(Outer, &message), "inners[1].count", "int32.gt", "int32.gt");
    message.inners = .{};
    const deep: Outer = .{ .id = -5, .inner = .{ .count = 1 }, .items = .of(&.{1}), .choice = .{ .second = 0 }, .pairs = .of(&.{.{ .key = 1, .value = 1 }}) };
    message.again = .of(&deep);
    try expect_one(try checked.of(Outer, &message), "again.id", "int32.gt", "int32.gt");
    message.again = .{};
    message.choice = .{ .third = .of(&deep) };
    try expect_one(try checked.of(Outer, &message), "third.id", "int32.gt", "int32.gt");
}

test "a oneof's required needs a member, and a member's rules read the member that is set" {
    var checked: Checked = undefined;
    var message = valid();
    message.choice = null;
    const violations = try checked.of(Outer, &message);
    try expect_one(violations, "choice", "", "required");
    // A oneof's path element holds its name alone.
    const element = violations[0].field.?.elements.items[0];
    try testing.expect(element.field_number == null and element.field_type == null);
    try testing.expect(violations[0].rule == null);
    message.choice = .{ .first = 0 };
    try expect_one(try checked.of(Outer, &message), "first", "int32.gt", "int32.gt");
    // `second` has no rule, and `first`'s is not read while `second` is set.
    message.choice = .{ .second = 0 };
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &message)).len);
}

test "a repeated field's size, its unique elements and each element's rules are checked" {
    var checked: Checked = undefined;
    var message = valid();
    message.items = .{};
    try expect_one(try checked.of(Outer, &message), "items", "repeated.min_items", "repeated.min_items");
    try testing.expectEqualStrings("must contain at least 1 item(s)", checked.report.violations()[0].message.?);
    message.items = .of(&.{ 1, 2, 3, 4 });
    try expect_one(try checked.of(Outer, &message), "items", "repeated.max_items", "repeated.max_items");
    message.items = .of(&.{ 1, 2, 3 });
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &message)).len);
    message.items = .of(&.{ 2, 1, 2 });
    try expect_one(try checked.of(Outer, &message), "items", "repeated.unique", "repeated.unique");
    message.items = .of(&.{ 2, -1, 0 });
    const violations = try checked.of(Outer, &message);
    try testing.expectEqual(@as(usize, 2), violations.len);
    try expect_violation(violations[0], "items[1]", "repeated.items.int32.gt", "int32.gt");
    try expect_violation(violations[1], "items[2]", "repeated.items.int32.gt", "int32.gt");
    try testing.expectEqual(@as(u64, 1), violations[0].field.?.elements.items[0].subscript.?.index);
    // The same elements, as `decode` leaves them: a view of the message's octets.
    const packed_items = [_]u8{ 0x22, 0x03, 0x02, 0x01, 0x02 };
    var decoded = try protobuf_decoder.decode(Outer, &packed_items);
    decoded.id = 1;
    decoded.inner = .{ .count = 1 };
    decoded.choice = .{ .first = 1 };
    decoded.pairs = message.pairs;
    try expect_one(try checked.of(Outer, &decoded), "items", "repeated.unique", "repeated.unique");
}

test "a map's size, each key and each value are checked, and a key's violation says so" {
    var checked: Checked = undefined;
    var message = valid();
    message.pairs = .{};
    try expect_one(try checked.of(Outer, &message), "pairs", "map.min_pairs", "map.min_pairs");
    try testing.expectEqualStrings("map must be at least 1 entries", checked.report.violations()[0].message.?);
    message.pairs = .of(&.{ .{ .key = 1, .value = 1 }, .{ .key = 2, .value = 1 }, .{ .key = 3, .value = 1 } });
    try expect_one(try checked.of(Outer, &message), "pairs", "map.max_pairs", "map.max_pairs");
    // The map's own violation names the field alone: no key, and no key's or value's type.
    const whole = checked.report.violations()[0].field.?.elements.items[0];
    try testing.expect(whole.subscript == null and whole.key_type == null and whole.value_type == null);
    message.pairs = .of(&.{ .{ .key = -2, .value = 1 }, .{ .key = 3, .value = 0 } });
    const violations = try checked.of(Outer, &message);
    try testing.expectEqual(@as(usize, 2), violations.len);
    try expect_violation(violations[0], "pairs[-2]", "map.keys.sint32.gt", "sint32.gt");
    try testing.expectEqual(@as(?bool, true), violations[0].for_key);
    try expect_violation(violations[1], "pairs[3]", "map.values.int32.gt", "int32.gt");
    try testing.expectEqual(@as(?bool, null), violations[1].for_key);
    const element = violations[1].field.?.elements.items[0];
    try testing.expectEqual(@as(?table.Type, .type_message), element.field_type);
    try testing.expectEqual(@as(?table.Type, .type_sint32), element.key_type);
    try testing.expectEqual(@as(?table.Type, .type_int32), element.value_type);
    // A message a map's value holds is checked under the entry's key.
    message.pairs = .of(&.{.{ .key = 1, .value = 1 }});
    message.named = .of(&.{ .{ .key = "a", .value = .{ .count = 1 } }, .{ .key = "b", .value = .{ .count = 0 } } });
    try expect_one(try checked.of(Outer, &message), "named[\"b\"].count", "int32.gt", "int32.gt");
}

test "the last entry of a key is the map's, so an earlier one is neither counted nor checked" {
    var checked: Checked = undefined;
    var message = valid();
    // Key 1 three times: one pair, whose value is the last entry's.
    message.pairs = .of(&.{ .{ .key = 1, .value = -1 }, .{ .key = 1, .value = -2 }, .{ .key = 1, .value = 7 } });
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &message)).len);
    message.pairs = .of(&.{ .{ .key = 1, .value = 7 }, .{ .key = 1, .value = -2 } });
    try expect_one(try checked.of(Outer, &message), "pairs[1]", "map.values.int32.gt", "int32.gt");
}

test "a report with no room ends the walk as Invalid and says it is truncated" {
    var storage: [@sizeOf(pb.Violation) + @sizeOf(pb.FieldPathElement)]u8 align(report_file.storage_alignment) = undefined;
    var report: Report = .init(&storage);
    var message = valid();
    message.items = .of(&.{ -1, -2, -3 });
    try testing.expectError(error.Invalid, validate(Outer, &message, .{ .cpu_features = .target() }, &report));
    try testing.expectEqual(@as(usize, 1), report.violations().len);
    try testing.expect(report.truncated);
    // A report with no room at all still refuses the message.
    var none: Report = .init(storage[0..0]);
    try testing.expectError(error.Invalid, validate(Outer, &message, .{ .cpu_features = .target() }, &none));
    try testing.expect(none.truncated);
    // A second message's violations follow the first's, and a valid one adds none.
    var roomy: [constants.report_bytes_default]u8 align(report_file.storage_alignment) = undefined;
    var both: Report = .init(&roomy);
    try testing.expectError(error.Invalid, validate(Outer, &message, .{ .cpu_features = .target() }, &both));
    const first = both.violations().len;
    const fine = valid();
    try validate(Outer, &fine, .{ .cpu_features = .target() }, &both);
    try testing.expectEqual(first, both.violations().len);
}

test "a message deeper than the limit, and a unique list too long to compare, are refused" {
    var checked: Checked = undefined;
    var links: [constants.path_depth_max]Outer = undefined;
    for (&links, 0..) |*link, index| {
        link.* = valid();
        if (index != 0) link.again = .of(&links[index - 1]);
    }
    // 99 messages one inside the other, and the `inner` of the last, are 100 deep and pass. One
    // more is too deep.
    try testing.expectEqual(@as(usize, 0), (try checked.of(Outer, &links[constants.path_depth_max - 2])).len);
    try testing.expectError(error.TooDeep, checked.of(Outer, &links[constants.path_depth_max - 1]));

    const Many = struct {
        items: proto.Repeated(i32, .int32) = .{},
        pub const FieldNumber = enum(u29) { items = 1 };
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.Many", .fields = &.{proto.field_of(FieldNumber.items, .int32, .{})} };
        pub const protovalidate: Rules = .{ .fields = &.{.{ .number = 1, .rules = .{ .type = .{ .repeated = .of(&.{ .unique = true }) } } }} };
    };
    var numbers: [constants.compared_items_max + 1]i32 = undefined;
    for (&numbers, 0..) |*number, index| number.* = @intCast(index);
    const at_limit: Many = .{ .items = .of(numbers[0..constants.compared_items_max]) };
    try testing.expectEqual(@as(usize, 0), (try checked.of(Many, &at_limit)).len);
    const over: Many = .{ .items = .of(&numbers) };
    try testing.expectError(error.TooManyItems, checked.of(Many, &over));
}
