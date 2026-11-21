//! One value against the rules that apply to it: a field's own value, an element of a repeated
//! field, or a map entry's key or value (decision 47). The rules are comptime, so the compiler
//! keeps the checks of the rules the schema states and nothing else.
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("table.zig");
const shape = @import("shape.zig");
const walk_file = @import("walk.zig");
const message_file = @import("message.zig");
const rule_number = @import("rule_number.zig");
const rule_scalar = @import("rule_scalar.zig");
const rule_string = @import("rule_string.zig");
const rule_bytes = @import("rule_bytes.zig");
const rule_time = @import("rule_time.zig");
const rule_field_mask = @import("rule_field_mask.zig");
const Walk = walk_file.Walk;
const Path = walk_file.Path;
const Site = walk_file.Site;
const Fault = walk_file.Fault;

/// Whether `rules` state nothing that a value is checked against.
pub fn states_nothing(comptime rules: pb.FieldRules) bool {
    return rules.type == null and rules.cel.is_empty() and rules.cel_expression.is_empty();
}

/// Whether the walk reads a value of type `V`: it has rules, or it is a message with a table.
pub fn is_read(comptime V: type, comptime rules: pb.FieldRules) bool {
    return !states_nothing(rules) or table.has_rules(V);
}

/// Checks `value` against the rules of its type, then, for a message, against the message's
/// own table.
pub fn check(comptime V: type, comptime rules: pb.FieldRules, comptime site: Site, value: *const V, walk: *Walk, path: *const Path) Fault!void {
    if (comptime rules.type) |typed| try check_typed(V, typed, site, value, walk, path);
    if (comptime table.has_rules(V)) try message_file.check(V, value, walk, path);
}

/// The type of the value that `H` holds: `H` itself, an optional's payload, or a lazy field's
/// message. A map entry holds its value so, and a oneof its member.
pub fn Held(comptime H: type) type {
    if (shape.is_lazy(H)) return H.Message;
    if (@typeInfo(H) == .optional) return @typeInfo(H).optional.child;
    return H;
}

/// Checks the value that `holder` holds. A message that is absent is read as its default: a map
/// entry with no value holds the value's default ("Maps", language guide).
pub fn check_held(comptime H: type, comptime rules: pb.FieldRules, comptime site: Site, holder: *const H, walk: *Walk, path: *const Path) Fault!void {
    const V = Held(H);
    if (comptime shape.is_lazy(H)) {
        const decoded = (holder.get() catch |failure| return walk_file.malformed(failure)) orelse V{};
        return check(V, rules, site, &decoded, walk, path);
    }
    if (comptime @typeInfo(H) == .optional) {
        const absent: V = .{};
        return check(V, rules, site, if (holder.*) |*set| set else &absent, walk, path);
    }
    return check(V, rules, site, holder, walk, path);
}

/// The scalar a value holds: itself, or a well-known wrapper's `value`.
fn scalar_of(comptime V: type, value: *const V) if (shape.wrapper_kind(V) != null) @FieldType(V, "value") else V {
    if (comptime shape.wrapper_kind(V) != null) return value.value;
    return value.*;
}

fn check_typed(comptime V: type, comptime typed: @typeInfo(@FieldType(pb.FieldRules, "type")).optional.child, comptime site: Site, value: *const V, walk: *Walk, path: *const Path) Fault!void {
    switch (typed) {
        inline .float, .double, .int32, .int64, .uint32, .uint64, .sint32, .sint64, .fixed32, .fixed64, .sfixed32, .sfixed64 => |rules, tag| {
            try rule_number.check(@TypeOf(rules), rules, @tagName(tag), site, scalar_of(V, value), walk, path);
        },
        .bool => |rules| try rule_scalar.check_bool(rules, site, scalar_of(V, value), walk, path),
        .string => |rules| try rule_string.check(rules, site, scalar_of(V, value), walk, path),
        .bytes => |rules| try rule_bytes.check(rules, site, scalar_of(V, value), walk, path),
        .@"enum" => |rules| try rule_scalar.check_enum(V, rules, site, value.*, walk, path),
        .any => |rules| try rule_scalar.check_any(rules, site, value, walk, path),
        .duration => |rules| try rule_time.check_duration(rules, site, value, walk, path),
        .timestamp => |rules| try rule_time.check_timestamp(rules, site, value, walk, path),
        .field_mask => |rules| try rule_field_mask.check(rules, site, value, walk, path),
        // `list.zig` and `map.zig` read these, with the rules of their elements.
        .repeated, .map => {},
    }
}
