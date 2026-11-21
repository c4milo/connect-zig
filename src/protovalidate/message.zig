//! One message against its table: the rules of the message itself, each oneof's `required`,
//! then each field (decision 47).
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("table.zig");
const constants = @import("constants.zig");
const walk_file = @import("walk.zig");
const field_file = @import("field.zig");
const cel_rule = @import("cel/cel_rule.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Fault = walk_file.Fault;
const Broken = walk_file.Broken;

pub fn check(comptime T: type, message: *const T, walk: *Walk, parent: ?*const Path) Fault!void {
    comptime std.debug.assert(table.has_rules(T));
    // The compiler counts each field of the loop below against this function's quota, and its
    // default stops at a message of about 500 fields.
    @setEvalBranchQuota(constants.eval_branches_per_rule * (T.protobuf.fields.len + 1));
    if (walk.depth == constants.path_depth_max) return error.TooDeep;
    walk.depth += 1;
    defer walk.depth -= 1;
    const rules = comptime table.of(T);
    if (comptime cel_rule.states(rules.message)) try cel_rule.check_message(T, rules.message, message, walk, parent);
    inline for (rules.message.oneof.items) |oneof| try check_message_oneof(T, oneof, message, walk, parent);
    inline for (rules.oneofs) |oneof| try check_oneof(T, oneof, message, walk, parent);
    inline for (T.protobuf.fields) |field| try field_file.check(T, field, message, walk, parent);
}

/// The field of `T` whose name in the .proto file is `name`.
pub fn field_of_name(comptime T: type, comptime name: []const u8) ?proto.Field {
    const place = table.place_of_name(T, .proto, name) orelse return null;
    return T.protobuf.fields[place];
}

/// The names of a `(buf.validate.message).oneof` rule's fields, as its messages list them.
fn names_of(comptime oneof: pb.MessageOneofRule) []const u8 {
    comptime {
        var joined: []const u8 = "";
        for (oneof.fields.items, 0..) |name, index| joined = joined ++ (if (index == 0) "" else ", ") ++ name;
        return joined;
    }
}

/// `(buf.validate.message).oneof`: at most one of the fields it names is set, and exactly one
/// when it is `required` (validate.proto, MessageRules.oneof).
fn check_message_oneof(comptime T: type, comptime oneof: pb.MessageOneofRule, message: *const T, walk: *Walk, parent: ?*const Path) Fault!void {
    var set: usize = 0;
    inline for (oneof.fields.items) |name| {
        const field = comptime field_of_name(T, name).?;
        if (field_file.is_set(T, field, message)) set += 1;
    }
    // validate.proto, MessageRules.oneof: "a list of fields of which at most one can be present".
    if (set > 1) {
        return walk_file.violate(walk, parent, comptime .{ .id = "message.oneof", .message = "only one of " ++ names_of(oneof) ++ " can be set" }, false);
    }
    // validate.proto, MessageOneofRule.required: "one of the fields specified _must_ be set".
    if (comptime oneof.required orelse false) {
        if (set == 0) try walk_file.violate(walk, parent, comptime .{ .id = "message.oneof", .message = "one of " ++ names_of(oneof) ++ " must be set" }, false);
    }
}

/// `(buf.validate.oneof).required`: a member of the oneof is set (validate.proto,
/// OneofRules.required).
fn check_oneof(comptime T: type, comptime oneof: table.Rules.Oneof, message: *const T, walk: *Walk, parent: ?*const Path) Fault!void {
    if (comptime !(oneof.rules.required orelse false)) return;
    if (@field(message, oneof.field) != null) return;
    // The path names the oneof alone: a oneof has no number and no type.
    const step: Path = .{ .parent = parent, .element = .{ .field_name = oneof.name } };
    try walk_file.violate(walk, &step, comptime .{ .id = "required", .message = "exactly one field is required in oneof" }, false);
}

const testing = std.testing;

/// A message whose field has one name in Zig and another in its .proto file.
const Renamed = struct {
    kind_: i32 = 0,
    pub const FieldNumber = enum(u29) { kind = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Renamed", .fields = &.{
        .{ .name = "kind_", .number = @intFromEnum(FieldNumber.kind), .kind = .int32, .json_name = "kind", .proto_name = "kind" },
    } };
};

test "a rule names a field as its .proto file names it" {
    const field = (comptime field_of_name(Renamed, "kind")) orelse return error.TestExpectedField;
    try testing.expectEqualStrings("kind_", field.name);
    try testing.expect(comptime field_of_name(Renamed, "kind_") == null);
    try testing.expect(comptime field_of_name(Renamed, "missing") == null);
}
