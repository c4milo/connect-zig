//! One field of a message: whether its rules apply, by its presence and by `required` and
//! `ignore`, and then its value, its elements or its entries (validate.proto, FieldRules.required
//! and Ignore).
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("table.zig");
const shape = @import("shape.zig");
const walk_file = @import("walk.zig");
const value_file = @import("value.zig");
const list_file = @import("list.zig");
const map_file = @import("map.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;
const Broken = walk_file.Broken;

/// The violation of `required`, under the rules at `site`.
pub fn required_broken(comptime site: Site) Broken {
    return .{
        .rule = table.rule_path(site.prefix, &.{.{ .message = pb.FieldRules, .name = "required" }}),
        .id = "required",
        .message = "value is required",
    };
}

/// The rules of `field`: its table entry's, or none. A field that a `(buf.validate.message).oneof`
/// rule names, and that states no `ignore`, takes IGNORE_IF_ZERO_VALUE (validate.proto,
/// MessageRules.oneof: "adding a field to a `oneof` will also set the IGNORE_IF_ZERO_VALUE").
pub fn rules_of(comptime T: type, comptime field: proto.Field) pb.FieldRules {
    comptime {
        var rules: pb.FieldRules = table.field_rules(T, field.number) orelse .{};
        if (rules.ignore == null and in_message_oneof(T, field)) rules.ignore = .ignore_if_zero_value;
        return rules;
    }
}

fn in_message_oneof(comptime T: type, comptime field: proto.Field) bool {
    for (table.of(T).message.oneof.items) |oneof| {
        for (oneof.fields.items) |name| {
            if (std.mem.eql(u8, name, field.proto_name)) return true;
        }
    }
    return false;
}

/// The path element of `field`: its number, its name in the .proto file and its type.
pub fn element_of(comptime field: proto.Field) table.Element {
    return .{ .field_number = @intCast(field.number), .field_name = field.proto_name, .field_type = table.type_of(field.kind) };
}

/// Whether `field` of `message` is set: present, for a field with presence, and not the zero
/// value for any other (validate.proto, MessageRules.oneof, point 2).
pub fn is_set(comptime T: type, comptime field: proto.Field, message: *const T) bool {
    return switch (comptime shape.of(T, field)) {
        .plain => !shape.is_zero(shape.Holder(T, field), &@field(message, field.name)),
        .optional => @field(message, field.name) != null,
        .lazy => @field(message, field.name).present(),
        .member => member_of(T, field, message) != null,
        .repeated, .map => !@field(message, field.name).is_empty(),
    };
}

/// The value of a oneof's member, or null when the oneof holds another member or none.
pub fn member_of(comptime T: type, comptime field: proto.Field, message: *const T) ?*const shape.Holder(T, field) {
    const held = if (@field(message, field.oneof.?)) |*set| set else return null;
    const Union = @TypeOf(held.*);
    if (std.meta.activeTag(held.*) != @field(std.meta.Tag(Union), field.name)) return null;
    return &@field(held.*, field.name);
}

pub fn check(comptime T: type, comptime field: proto.Field, message: *const T, walk: *Walk, parent: ?*const Path) Fault!void {
    const rules = comptime rules_of(T, field);
    const kind = comptime shape.of(T, field);
    // validate.proto, Ignore.IGNORE_ALWAYS: "Always ignore rules, including the `required`
    // rule", and "any validations on value's fields".
    if (comptime (rules.ignore orelse .ignore_unspecified) == .ignore_always) return;
    const required = comptime rules.required orelse false;
    if (comptime !required and !reads(T, field, kind, rules)) return;
    var step: Path = .{ .parent = parent, .element = comptime element_of(field) };
    switch (comptime kind) {
        .repeated => try list_file.check(shape.Holder(T, field), field.kind, rules, &@field(message, field.name), walk, &step),
        .map => try map_file.check(shape.Holder(T, field), rules, &@field(message, field.name), walk, &step),
        .plain => try check_plain(shape.Holder(T, field), field.kind, rules, &@field(message, field.name), walk, &step),
        .optional => {
            const value = if (@field(message, field.name)) |*set| set else return unset(required, walk, &step);
            try value_file.check(@TypeOf(value.*), field.kind, rules, .{}, value, walk, &step);
        },
        .member => {
            const value = member_of(T, field, message) orelse return unset(required, walk, &step);
            try check_held(@TypeOf(value.*), field.kind, rules, value, required, walk, &step);
        },
        .lazy => try check_held(shape.Holder(T, field), field.kind, rules, &@field(message, field.name), required, walk, &step),
    }
}

/// Whether the walk has anything to read of the field: a rule of its own, or a message with a
/// table in it.
fn reads(comptime T: type, comptime field: proto.Field, comptime kind: shape.Shape, comptime rules: pb.FieldRules) bool {
    const F = shape.Holder(T, field);
    return switch (kind) {
        .repeated => !value_file.states_nothing(rules) or table.has_rules(F.Element),
        .map => !value_file.states_nothing(rules) or table.has_rules(value_file.Held(@FieldType(F.Element, "value"))),
        else => value_file.is_read(shape.Value(T, field), rules),
    };
}

/// A field with presence that is not set breaks `required` and passes every other rule
/// (validate.proto, Ignore.IGNORE_UNSPECIFIED: "Ignore rules if the field tracks presence and
/// is unset").
fn unset(comptime required: bool, walk: *Walk, step: *const Path) Fault!void {
    if (required) try walk_file.violate(walk, step, comptime required_broken(.{}), false);
}

/// A value with no presence: the zero value breaks `required`, and IGNORE_IF_ZERO_VALUE passes
/// over it (validate.proto, FieldRules.required: "the value of the field can't be the zero
/// value").
fn check_plain(comptime V: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules, value: *const V, walk: *Walk, step: *const Path) Fault!void {
    const required = comptime rules.required orelse false;
    const skips_zero = comptime (rules.ignore orelse .ignore_unspecified) == .ignore_if_zero_value;
    if (comptime required or skips_zero) {
        if (shape.is_zero(V, value)) return unset(required, walk, step);
    }
    try value_file.check(V, kind, rules, .{}, value, walk, step);
}

/// A member of a oneof, or a lazy field, whose message may be a `proto.Lazy`: the walk decodes
/// it and reads the message.
fn check_held(comptime H: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules, held: *const H, comptime required: bool, walk: *Walk, step: *const Path) Fault!void {
    if (comptime !shape.is_lazy(H)) return value_file.check(H, kind, rules, .{}, held, walk, step);
    const decoded = held.get() catch |failure| return walk_file.malformed(failure);
    const value = decoded orelse return unset(required, walk, step);
    try value_file.check(H.Message, kind, rules, .{}, &value, walk, step);
}
