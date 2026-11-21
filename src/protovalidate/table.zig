//! `Rules`: the table a generated message declares as `pub const protovalidate`, which the
//! plugin writes from the message's `buf.validate` options (decision 47), and what `validate`
//! reads of a table and of a descriptor at comptime.
const std = @import("std");
const assert = std.debug.assert;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const descriptor_pb = @import("google_protobuf_descriptor");
const constants = @import("constants.zig");

/// A field's type as a path element states it: descriptor.proto's FieldDescriptorProto.Type.
pub const Type = descriptor_pb.FieldDescriptorProto.Type;
pub const Element = pb.FieldPathElement;

/// The name of the declaration that holds a message's table.
pub const declaration = "protovalidate";

pub const Rules = struct {
    /// `(buf.validate.message)`: the rules of the message itself.
    message: pb.MessageRules = .{},
    /// `(buf.validate.field)` of each field that has rules.
    fields: []const Field = &.{},
    /// `(buf.validate.oneof)` of each oneof that has rules.
    oneofs: []const Oneof = &.{},
    /// Why the plugin wrote no table for one of the message's rules: a rule it cannot write
    /// yet. `validate` fails the build with this text, so no such rule goes unchecked.
    unsupported: ?[]const u8 = null,

    pub const Field = struct {
        /// The field's number, which names it in the message's descriptor.
        number: u32,
        rules: pb.FieldRules,
    };

    pub const Oneof = struct {
        /// The Zig name of the oneof's union field, as the descriptor's `Field.oneof` holds it.
        field: []const u8,
        /// The oneof's name in the .proto file, which a violation's path states.
        name: []const u8,
        rules: pb.OneofRules,
    };
};

/// Whether `T` declares a table: it has a rule, or holds a message that has one.
pub fn has_rules(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, declaration);
}

/// The table of `T`.
pub fn of(comptime T: type) Rules {
    comptime assert(has_rules(T));
    return @field(T, declaration);
}

/// The rules of the field of `T` numbered `number`, or none.
pub fn field_rules(comptime T: type, comptime number: u32) ?pb.FieldRules {
    comptime {
        if (!has_rules(T)) return null;
        for (of(T).fields) |entry| {
            if (entry.number == number) return entry.rules;
        }
        return null;
    }
}

/// The type a path element states for a field of `kind`: the same name in descriptor.proto,
/// where a string is one type whether its UTF-8 is checked or not.
pub fn type_of(comptime kind: proto.Kind) Type {
    return switch (kind) {
        .double => .type_double,
        .float => .type_float,
        .int64 => .type_int64,
        .uint64 => .type_uint64,
        .int32 => .type_int32,
        .fixed64 => .type_fixed64,
        .fixed32 => .type_fixed32,
        .bool => .type_bool,
        .string, .unvalidated_string => .type_string,
        .group => .type_group,
        .message => .type_message,
        .bytes => .type_bytes,
        .uint32 => .type_uint32,
        .@"enum" => .type_enum,
        .sfixed32 => .type_sfixed32,
        .sfixed64 => .type_sfixed64,
        .sint32 => .type_sint32,
        .sint64 => .type_sint64,
    };
}

/// The descriptor's entry of the field of `Message` whose Zig name is `name`.
pub fn field_named(comptime Message: type, comptime name: []const u8) proto.Field {
    comptime {
        @setEvalBranchQuota(constants.eval_branches_per_rule);
        for (Message.protobuf.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field;
        }
        @compileError(Message.protobuf.full_name ++ " has no field " ++ name);
    }
}

/// The path element of the rule `name` of the rule message `Message`: its number, its name in
/// validate.proto and its type.
pub fn rule_element(comptime Message: type, comptime name: []const u8) Element {
    const field = comptime field_named(Message, name);
    return .{ .field_number = @intCast(field.number), .field_name = field.proto_name, .field_type = comptime type_of(field.kind) };
}

/// The path of a rule within `buf.validate.FieldRules`: `prefix`, then one element for each
/// of `steps`, where a step names a rule message and one of its fields.
pub fn rule_path(comptime prefix: []const Element, comptime steps: []const Step) pb.FieldPath {
    comptime {
        var elements: []const Element = prefix;
        for (steps) |step| elements = elements ++ [_]Element{rule_element(step.message, step.name)};
        return .{ .elements = .of(elements) };
    }
}

pub const Step = struct { message: type, name: []const u8 };

const testing = std.testing;

const Sample = struct {
    name: []const u8 = "",
    pub const FieldNumber = enum(u29) { name = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Sample", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),
    } };
    pub const protovalidate: Rules = .{
        .fields = &.{.{ .number = @intFromEnum(FieldNumber.name), .rules = .{ .type = .{ .string = .{ .min_len = 1 } } } }},
    };
};

const Plain = struct {
    name: []const u8 = "",
    pub const FieldNumber = enum(u29) { name = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Plain", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),
    } };
};

test "a table is found by its declaration, and a field's rules by its number" {
    try testing.expect(comptime has_rules(Sample));
    try testing.expect(comptime !has_rules(Plain));
    try testing.expect(comptime !has_rules(u32));
    const rules = (comptime field_rules(Sample, 1)) orelse return error.TestExpectedRules;
    const typed = rules.type orelse return error.TestExpectedRules;
    try testing.expectEqual(@as(?u64, 1), typed.string.min_len);
    try testing.expect(comptime field_rules(Sample, 2) == null);
    try testing.expect(comptime field_rules(Plain, 1) == null);
}

test "a rule's path takes each number, name and type from validate.proto's descriptors" {
    const path = comptime rule_path(&.{}, &.{ .{ .message = pb.FieldRules, .name = "string" }, .{ .message = pb.StringRules, .name = "min_len" } });
    const elements = path.elements.items;
    try testing.expectEqual(@as(usize, 2), elements.len);
    try testing.expectEqual(@as(?i32, 14), elements[0].field_number);
    try testing.expectEqualStrings("string", elements[0].field_name.?);
    try testing.expectEqual(@as(?Type, .type_message), elements[0].field_type);
    try testing.expectEqual(@as(?i32, 2), elements[1].field_number);
    try testing.expectEqualStrings("min_len", elements[1].field_name.?);
    try testing.expectEqual(@as(?Type, .type_uint64), elements[1].field_type);
    // A prefix leads the path, as `repeated.items` leads an element's rule.
    const nested = comptime rule_path(path.elements.items, &.{.{ .message = pb.Int32Rules, .name = "const" }});
    try testing.expectEqual(@as(usize, 3), nested.elements.items.len);
    try testing.expectEqualStrings("const", nested.elements.items[2].field_name.?);
    try testing.expectEqual(@as(?Type, .type_int32), nested.elements.items[2].field_type);
}

test "a path element's type is the descriptor's, and a string's is one type" {
    try testing.expectEqual(Type.type_string, type_of(.unvalidated_string));
    try testing.expectEqual(Type.type_string, type_of(.string));
    try testing.expectEqual(Type.type_group, type_of(.group));
    try testing.expectEqual(Type.type_sint64, type_of(.sint64));
    try testing.expectEqual(Type.type_enum, type_of(.@"enum"));
}
