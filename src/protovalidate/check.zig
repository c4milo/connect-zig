//! `rules_error`: why the module cannot check a type's rules, as a comptime value (decision 47).
//! `validate` stops the build with it, so no rule goes unchecked: a rule that does not fit its
//! field, a rule the module has no check for, or a rule the plugin could not write. A program
//! that must report such a type at run time, as the conformance executor does, reads the value
//! and never calls `validate` for that type.
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("table.zig");
const constants = @import("constants.zig");
const shape = @import("shape.zig");
const field_file = @import("field.zig");
const message_file = @import("message.zig");
const list_file = @import("list.zig");
const map_file = @import("map.zig");
const value_file = @import("value.zig");
const rule_number = @import("rule_number.zig");
const rule_scalar = @import("rule_scalar.zig");
const rule_string = @import("rule_string.zig");
const rule_bytes = @import("rule_bytes.zig");
const rule_time = @import("rule_time.zig");
const rule_field_mask = @import("rule_field_mask.zig");
const cel_rule = @import("cel/cel_rule.zig");
const cel_type = @import("cel/cel_type.zig");

/// The member of `buf.validate.FieldRules` that holds a field's typed rules.
const Typed = @typeInfo(@FieldType(pb.FieldRules, "type")).optional.child;

/// What stops the rules of `T`, or of a message it holds, from being checked, or null.
pub fn rules_error(comptime T: type) ?[]const u8 {
    return Checked(T).problem;
}

/// The check of `T`, which the compiler runs once: `of_message` raises the compiler's branch
/// quota, and the compiler keeps no answer of a function that does so, so the answer is a
/// constant's value (docs/performance.md).
fn Checked(comptime T: type) type {
    return struct {
        const problem: ?[]const u8 = of_message(T, &.{});
    };
}

fn of_message(comptime T: type, comptime visited: []const type) ?[]const u8 {
    if (!table.has_rules(T)) return null;
    // A message that holds its own type is checked once.
    for (visited) |seen| {
        if (seen == T) return null;
    }
    @setEvalBranchQuota(constants.eval_branches_per_rule * (T.protobuf.fields.len + 1));
    const name = T.protobuf.full_name;
    const rules = table.of(T);
    if (rules.unsupported) |why| return name ++ ": " ++ why;
    if (of_message_rules(T, rules.message)) |problem| return problem;
    if (of_entries(T, rules)) |problem| return problem;
    for (T.protobuf.fields) |field| {
        if (of_field(T, field, visited ++ [_]type{T})) |problem| return problem;
    }
    return null;
}

/// `(buf.validate.message)`: its CEL rules, and each `oneof` rule's field names.
fn of_message_rules(comptime T: type, comptime rules: pb.MessageRules) ?[]const u8 {
    const name = T.protobuf.full_name;
    if (cel_rule.problem_of(rules, *const T)) |problem| return name ++ ": " ++ problem;
    for (rules.oneof.items) |oneof| {
        if (of_message_oneof(T, oneof.fields.items)) |problem| return problem;
    }
    return null;
}

/// One `(buf.validate.message).oneof` rule: the names of its fields.
fn of_message_oneof(comptime T: type, comptime fields: []const []const u8) ?[]const u8 {
    const name = T.protobuf.full_name;
    // validate.proto, MessageOneofRule.fields: "At least one field must be specified".
    if (fields.len == 0) return "at least one field must be specified in oneof rule for the message " ++ name;
    for (fields, 0..) |field_name, index| {
        // validate.proto, MessageOneofRule.fields: "All field names must be defined in the
        // message".
        if (message_file.field_of_name(T, field_name) == null) return "field " ++ field_name ++ " not found in message " ++ name;
        // validate.proto, MessageOneofRule.fields: "duplicates are not permitted".
        if (names(fields[0..index], field_name)) return "duplicate " ++ field_name ++ " in oneof rule for the message " ++ name;
    }
    return null;
}

/// Each entry of the table names a field or a oneof that the message has.
fn of_entries(comptime T: type, comptime rules: table.Rules) ?[]const u8 {
    const name = T.protobuf.full_name;
    for (rules.fields, 0..) |entry, at| {
        const kept = table.entry_of(T, entry.number) orelse return std.fmt.comptimePrint("{s}: the table holds rules for field {d}, which the message lacks", .{ name, entry.number });
        // One entry for each field: a second one would state rules that no check reads.
        if (kept != at) return std.fmt.comptimePrint("{s}: the table holds two entries for field {d}", .{ name, entry.number });
    }
    for (rules.oneofs) |oneof| {
        if (!@hasField(T, oneof.field)) return name ++ ": the table holds rules for the oneof " ++ oneof.name ++ ", which the message lacks";
    }
    return null;
}

fn of_field(comptime T: type, comptime field: proto.Field, comptime visited: []const type) ?[]const u8 {
    const where = T.protobuf.full_name ++ "." ++ field.proto_name;
    const rules = field_file.rules_of(T, field);
    const F = shape.Holder(T, field);
    const sites = field_file.sites_of(T, field);
    return switch (shape.of(T, field)) {
        .repeated => of_list(F, field.kind, rules, sites, where, visited),
        .map => of_map(F, rules, sites, where, visited),
        else => of_value(shape.Value(T, field), field.kind, rules, sites.field, where, visited),
    };
}

fn of_list(comptime F: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules, comptime sites: field_file.Sites, comptime where: []const u8, comptime visited: []const type) ?[]const u8 {
    if (of_whole(F, rules, sites.field, where)) |problem| return problem;
    if (rules.type) |typed| {
        if (typed != .repeated) return where ++ ": mismatched rule type and field type: " ++ @tagName(typed) ++ " rules on a repeated field";
    }
    const list_rules = list_file.rules_of(rules);
    if (unhandled(pb.RepeatedRules, list_rules, &list_file.handled)) |rule| return where ++ ": the rule repeated." ++ rule ++ " has no check";
    // validate.proto, repeated.unique: CEL's `unique` reads a list of scalars.
    if ((list_rules.unique orelse false) and kind.holds_message()) return where ++ ": repeated.unique on a field of messages";
    return of_value(F.Element, kind, list_file.item_rules_of(rules), sites.items, where ++ " (repeated.items)", visited);
}

fn of_map(comptime F: type, comptime rules: pb.FieldRules, comptime sites: field_file.Sites, comptime where: []const u8, comptime visited: []const type) ?[]const u8 {
    if (of_whole(F, rules, sites.field, where)) |problem| return problem;
    if (rules.type) |typed| {
        if (typed != .map) return where ++ ": mismatched rule type and field type: " ++ @tagName(typed) ++ " rules on a map field";
    }
    if (unhandled(pb.MapRules, map_file.rules_of(rules), &map_file.handled)) |rule| return where ++ ": the rule map." ++ rule ++ " has no check";
    const Entry = F.Element;
    const key = table.field_named(Entry, "key");
    const value = table.field_named(Entry, "value");
    if (of_value(@FieldType(Entry, "key"), key.kind, map_file.key_rules_of(rules), sites.keys, where ++ " (map.keys)", visited)) |problem| return problem;
    return of_value(value_file.Held(@FieldType(Entry, "value")), value.kind, map_file.value_rules_of(rules), sites.values, where ++ " (map.values)", visited);
}

/// The CEL rules of a repeated field or of a map, whose `this` is the whole list or map.
fn of_whole(comptime F: type, comptime rules: pb.FieldRules, comptime predefined: []const table.Rules.Predefined, comptime where: []const u8) ?[]const u8 {
    if (!cel_rule.states(rules) and predefined.len == 0) return null;
    const This = cel_rule.Whole(F) orelse return where ++ ": a CEL rule reads no map whose values are of the message's own type";
    if (cel_rule.problem_of(rules, This)) |problem| return where ++ ": " ++ problem;
    const problem = cel_rule.predefined_problem_of(rules, predefined, This) orelse return null;
    return where ++ ": " ++ problem;
}

/// One value's rules: they fit the value's type, the module checks each one, and the value's
/// own message, if it is one, has rules that can be checked.
fn of_value(comptime V: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules, comptime predefined: []const table.Rules.Predefined, comptime where: []const u8, comptime visited: []const type) ?[]const u8 {
    if (cel_rule.problem_of(rules, cel_type.Of(kind, V))) |problem| return where ++ ": " ++ problem;
    if (cel_rule.predefined_problem_of(rules, predefined, cel_type.Of(kind, V))) |problem| return where ++ ": " ++ problem;
    if (rules.type) |typed| {
        if (!fits(typed, V, kind)) return where ++ ": mismatched rule type and field type: " ++ @tagName(typed) ++ " rules on a field of another type";
        if (of_typed(typed)) |rule| return where ++ ": the rule " ++ @tagName(typed) ++ "." ++ rule ++ " has no check";
    }
    return of_message(V, visited);
}

/// Whether the rules of `typed` are those of a value of type `V` and of kind `kind`: the rules
/// of the kind's own name, or, for a well-known wrapper, of the scalar it holds.
fn fits(comptime typed: Typed, comptime V: type, comptime kind: proto.Kind) bool {
    const wkt = proto.wkt;
    return switch (typed) {
        .repeated, .map => false,
        .any => V == wkt.Any,
        .duration => V == wkt.Duration,
        .timestamp => V == wkt.Timestamp,
        .field_mask => V == wkt.FieldMask,
        .string => kind.is_string() or V == wkt.StringValue,
        else => std.mem.eql(u8, @tagName(typed), @tagName(shape.wrapper_kind(V) orelse kind)),
    };
}

/// The first rule of `typed` that is set and that the module has no check for, or null.
fn of_typed(comptime typed: Typed) ?[]const u8 {
    return switch (typed) {
        // `of_list` and `of_map` read these, with the rules of their elements.
        .repeated, .map => null,
        inline else => |rules, tag| unhandled(@TypeOf(rules), rules, handled_by(tag)),
    };
}

/// The rules the module checks of each rule message, by their names in validate.proto.
fn handled_by(comptime tag: std.meta.Tag(Typed)) []const []const u8 {
    return switch (tag) {
        .float, .double, .int32, .int64, .uint32, .uint64, .sint32, .sint64, .fixed32, .fixed64, .sfixed32, .sfixed64 => &rule_number.handled,
        .bool => &rule_scalar.handled_bool,
        .@"enum" => &rule_scalar.handled_enum,
        .any => &rule_scalar.handled_any,
        .string => &rule_string.handled,
        .bytes => &rule_bytes.handled,
        .duration => &rule_time.handled_duration,
        .timestamp => &rule_time.handled_timestamp,
        .field_mask => &rule_field_mask.handled,
        .repeated => &list_file.handled,
        .map => &map_file.handled,
    };
}

/// The first field of the rule message `rules` that is set and that `handled` does not name.
fn unhandled(comptime R: type, comptime rules: R, comptime handled: []const []const u8) ?[]const u8 {
    for (R.protobuf.fields) |field| {
        if (!is_set(R, field, rules)) continue;
        if (!names(handled, field.proto_name)) return field.proto_name;
    }
    return null;
}

fn names(comptime list: []const []const u8, comptime name: []const u8) bool {
    for (list) |each| {
        if (std.mem.eql(u8, each, name)) return true;
    }
    return false;
}

/// Whether a rule message's field holds a value: a member of a oneof that is the one set, an
/// optional with a value, a list with an element, or a nested rule message that is present.
fn is_set(comptime R: type, comptime field: proto.Field, comptime rules: R) bool {
    if (field.oneof) |oneof| {
        const held = @field(rules, oneof) orelse return false;
        return std.mem.eql(u8, @tagName(held), field.name);
    }
    const F = @FieldType(R, field.name);
    const value = @field(rules, field.name);
    if (shape.is_repeated(F)) return value.items.len != 0;
    if (shape.is_lazy(F)) return value.value != null;
    return value != null;
}

const testing = std.testing;

fn Message(comptime Field: type, comptime kind: proto.Kind, comptime rules: table.Rules) type {
    return struct {
        val: Field = default,
        pub const default: Field = if (@typeInfo(Field) == .optional) null else if (@typeInfo(Field) == .@"struct") .{} else if (@typeInfo(Field) == .pointer) "" else 0;
        pub const FieldNumber = enum(u29) { val = 1 };
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{proto.field_of(FieldNumber.val, kind, .{})} };
        pub const protovalidate: table.Rules = rules;
    };
}

fn field_rules(comptime rules: pb.FieldRules) table.Rules {
    return .{ .fields = &.{.{ .number = 1, .rules = rules }} };
}

fn expect_problem(comptime T: type, comptime part: []const u8) !void {
    const problem = (comptime rules_error(T)) orelse return error.TestExpectedProblem;
    if (std.mem.indexOf(u8, problem, part) == null) {
        std.debug.print("problem: {s}\nlacks: {s}\n", .{ problem, part });
        return error.TestExpectedProblem;
    }
}

test "rules that fit their field and have a check raise no problem" {
    const number: pb.FieldRules = comptime .{ .required = true, .type = .{ .int32 = .{ .@"const" = 1, .less_than = .{ .lt = 5 }, .in = .of(&.{ 1, 2 }) } } };
    try testing.expect(comptime rules_error(Message(i32, .int32, field_rules(number))) == null);
    // A wrapper takes the rules of the scalar it holds.
    try testing.expect(comptime rules_error(Message(?proto.wkt.Int32Value, .message, field_rules(number))) == null);
    // A type with no table, and a table with no rule, raise none.
    try testing.expect(comptime rules_error(u32) == null);
    try testing.expect(comptime rules_error(Message(i32, .int32, .{})) == null);
}

test "rules of another type than the field's are a mismatch" {
    const number: pb.FieldRules = comptime .{ .type = .{ .int32 = .{ .@"const" = 1 } } };
    try expect_problem(Message(i64, .int64, field_rules(number)), "t.Message.val: mismatched rule type and field type: int32 rules");
    try expect_problem(Message(i32, .sint32, field_rules(number)), "mismatched rule type and field type");
    try expect_problem(Message([]const u8, .string, field_rules(number)), "mismatched rule type and field type");
    try expect_problem(Message(?proto.wkt.Int64Value, .message, field_rules(number)), "mismatched rule type and field type");
    try expect_problem(Message(?proto.wkt.Timestamp, .message, field_rules(.{ .type = .{ .duration = .{} } })), "mismatched rule type and field type: duration rules");
    try expect_problem(Message(?proto.wkt.Duration, .message, field_rules(.{ .type = .{ .any = .{} } })), "mismatched rule type and field type: any rules");
    try expect_problem(Message(i32, .int32, field_rules(.{ .type = .{ .timestamp = .{} } })), "mismatched rule type and field type: timestamp rules");
    try expect_problem(Message(i32, .int32, field_rules(.{ .type = .{ .repeated = .of(&.{ .min_items = 1 }) } })), "mismatched rule type and field type: repeated rules");
    // A list takes `repeated` rules alone, and its elements the rules of their own type.
    const List = proto.Repeated(i32, .int32);
    try expect_problem(Message(List, .int32, field_rules(number)), "int32 rules on a repeated field");
    const items: pb.FieldRules = comptime .{ .type = .{ .int64 = .{ .@"const" = 1 } } };
    try expect_problem(Message(List, .int32, field_rules(.{ .type = .{ .repeated = .of(&.{ .items = .of(&items) }) } })), "t.Message.val (repeated.items): mismatched rule type and field type: int64 rules");
    try testing.expect(comptime rules_error(Message(List, .int32, field_rules(.{ .type = .{ .repeated = .of(&.{ .items = .of(&number) }) } }))) == null);
}

test "a rule with no check, a CEL rule and a rule the plugin could not write each stop the type" {
    try expect_problem(Message([]const u8, .string, field_rules(.{ .type = .{ .string = .{ .pattern = "a" } } })), "t.Message.val: the rule string.pattern has no check");
    try expect_problem(Message(i32, .int32, field_rules(.{ .cel_expression = .of(&.{"this > "}) })), "t.Message.val: `this > `: the expression ends early");
    try expect_problem(Message(i32, .int32, field_rules(.{ .cel = .of(&.{.{ .id = "a", .expression = "this.size() > 0" }}) })), "found no matching overload for `size` applied to (int)");
    try expect_problem(Message(i32, .int32, .{ .message = .{ .cel_expression = .of(&.{"this.missing > 0"}) } }), "t.Message: `this.missing > 0`: undefined field `missing` of t.Message");
    try expect_problem(Message(i32, .int32, .{ .message = .{ .cel = .of(&.{.{ .id = "a", .expression = "this.val" }}) } }), "a rule's expression gives a bool or a string, not a int");
    try expect_problem(Message(i32, .int32, field_rules(.{ .cel = .of(&.{.{ .id = "a" }}) })), "t.Message.val: ``: the expression ends early");
    try expect_problem(Message(proto.Repeated(i32, .int32), .int32, field_rules(.{ .cel_expression = .of(&.{"this.size() > 'a'"}) })), "t.Message.val: `this.size() > 'a'`: found no matching overload for `>` applied to (int, string)");
    try testing.expect(comptime rules_error(Message(proto.Repeated(i32, .int32), .int32, field_rules(.{ .cel_expression = .of(&.{"this.size() > 0"}) }))) == null);
    try expect_problem(Message(i32, .int32, .{ .unsupported = "an extension's rule" }), "t.Message: an extension's rule");
    try expect_problem(Message(i32, .int32, .{ .fields = &.{.{ .number = 2, .rules = .{} }} }), "rules for field 2, which the message lacks");
    try expect_problem(Message(i32, .int32, .{ .fields = &.{ .{ .number = 1, .rules = .{} }, .{ .number = 1, .rules = .{} } } }), "t.Message: the table holds two entries for field 1");
    try expect_problem(Message(i32, .int32, .{ .oneofs = &.{.{ .field = "choice", .name = "choice", .rules = .{} }} }), "rules for the oneof choice, which the message lacks");
}

test "a message's oneof rule names fields of the message, each once, and at least one" {
    try expect_problem(Message(i32, .int32, .{ .message = .{ .oneof = .of(&.{.{ .fields = .of(&.{"other"}) }}) } }), "field other not found in message t.Message");
    try expect_problem(Message(i32, .int32, .{ .message = .{ .oneof = .of(&.{.{ .fields = .of(&.{ "val", "val" }) }}) } }), "duplicate val in oneof rule for the message t.Message");
    try expect_problem(Message(i32, .int32, .{ .message = .{ .oneof = .of(&.{.{ .required = true }}) } }), "at least one field must be specified in oneof rule for the message t.Message");
    try testing.expect(comptime rules_error(Message(i32, .int32, .{ .message = .{ .oneof = .of(&.{.{ .fields = .of(&.{"val"}) }}) } })) == null);
}

test "a problem of a message that a field holds stops the message that holds it, and a cycle ends" {
    const Inner = Message(i64, .int64, field_rules(.{ .type = .{ .int32 = .{ .@"const" = 1 } } }));
    try expect_problem(Message(?Inner, .message, .{}), "mismatched rule type and field type");
    try expect_problem(Message(proto.Repeated(Inner, .message), .message, .{}), "mismatched rule type and field type");
    const Loop = struct {
        next: proto.Lazy(@This()) = .{},
        pub const FieldNumber = enum(u29) { next = 1 };
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.Loop", .fields = &.{proto.field_of(FieldNumber.next, .message, .{})} };
        pub const protovalidate: table.Rules = .{};
    };
    try testing.expect(comptime rules_error(Loop) == null);
}
