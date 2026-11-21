//! How a generated message holds each field, which decides how the walk reads it: a plain value,
//! an optional, a member of a oneof's union, a `proto.Lazy`, or a `proto.Repeated` of elements
//! or of map entries (docs/design.md §4).
const std = @import("std");
const proto = @import("protobuf");

pub const Shape = enum {
    /// A value with no presence: a proto3 scalar. The walk always reads it.
    plain,
    /// A `?V`: a scalar with presence, or a message.
    optional,
    /// A `proto.Lazy(M)`: a message that holds its own type.
    lazy,
    /// A member of a oneof's union.
    member,
    /// A `proto.Repeated` of numbers, strings, bytes, enums or messages.
    repeated,
    /// A `proto.Repeated` of a map's entries.
    map,
};

pub fn is_repeated(comptime F: type) bool {
    return @typeInfo(F) == .@"struct" and @hasDecl(F, "Iterator") and @hasDecl(F, "Element") and @hasField(F, "view");
}

pub fn is_lazy(comptime F: type) bool {
    return @typeInfo(F) == .@"struct" and @hasDecl(F, "Message") and @hasField(F, "bytes") and @hasField(F, "value");
}

/// Whether `F` is a repeated field of a map's entries.
pub fn is_map(comptime F: type) bool {
    if (!is_repeated(F)) return false;
    const Element = F.Element;
    return @typeInfo(Element) == .@"struct" and @hasDecl(Element, "protobuf") and Element.protobuf.map_entry;
}

/// The type of the struct field or of the union member that holds `field` in `T`.
pub fn Holder(comptime T: type, comptime field: proto.Field) type {
    if (field.oneof) |oneof| {
        const Union = @typeInfo(@FieldType(T, oneof)).optional.child;
        return @FieldType(Union, field.name);
    }
    return @FieldType(T, field.name);
}

pub fn of(comptime T: type, comptime field: proto.Field) Shape {
    const F = Holder(T, field);
    if (field.oneof != null) return .member;
    if (is_map(F)) return .map;
    if (is_repeated(F)) return .repeated;
    if (is_lazy(F)) return .lazy;
    if (@typeInfo(F) == .optional) return .optional;
    return .plain;
}

/// The type of one value of `field`: the holder's without its optional, and a lazy message's
/// message. A repeated field's value is the field itself.
pub fn Value(comptime T: type, comptime field: proto.Field) type {
    const F = Holder(T, field);
    if (is_lazy(F)) return F.Message;
    if (@typeInfo(F) == .optional) return @typeInfo(F).optional.child;
    return F;
}

/// The scalar kind a well-known wrapper holds in its field `value`, or null for any other type
/// (validate.proto: a type's rules "may also be applied to" its wrapper).
pub fn wrapper_kind(comptime V: type) ?proto.Kind {
    const wkt = proto.wkt;
    return switch (V) {
        wkt.DoubleValue => .double,
        wkt.FloatValue => .float,
        wkt.Int64Value => .int64,
        wkt.UInt64Value => .uint64,
        wkt.Int32Value => .int32,
        wkt.UInt32Value => .uint32,
        wkt.BoolValue => .bool,
        wkt.StringValue => .string,
        wkt.BytesValue => .bytes,
        else => null,
    };
}

/// Whether a value with no presence is its type's zero value, which `required` refuses and
/// `IGNORE_IF_ZERO_VALUE` passes over (validate.proto, Ignore.IGNORE_IF_ZERO_VALUE).
pub fn is_zero(comptime V: type, value: *const V) bool {
    return switch (@typeInfo(V)) {
        .bool => !value.*,
        .int, .float => value.* == 0,
        .@"enum" => @intFromEnum(value.*) == 0,
        .pointer => value.len == 0,
        // A message that is set is never zero: its absence is.
        else => false,
    };
}

const testing = std.testing;

const Entry = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Entry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

const Sample = struct {
    plain: i32 = 0,
    maybe: ?[]const u8 = null,
    wrapped: ?proto.wkt.Int32Value = null,
    again: proto.Lazy(Sample) = .{},
    choice: ?union(enum) { text: []const u8, count: u64 } = null,
    list: proto.Repeated(f32, .float) = .{},
    pairs: proto.Repeated(Entry, .message) = .{},
    pub const FieldNumber = enum(u29) { plain = 1, maybe = 2, wrapped = 3, again = 4, text = 5, count = 6, list = 7, pairs = 8 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Sample", .fields = &.{
        proto.field_of(FieldNumber.plain, .int32, .{}),                    proto.field_of(FieldNumber.maybe, .string, .{}),
        proto.field_of(FieldNumber.wrapped, .message, .{}),                proto.field_of(FieldNumber.again, .message, .{}),
        proto.field_of(FieldNumber.text, .string, .{ .oneof = "choice" }), proto.field_of(FieldNumber.count, .uint64, .{ .oneof = "choice" }),
        proto.field_of(FieldNumber.list, .float, .{}),                     proto.field_of(FieldNumber.pairs, .message, .{}),
    } };
};

test "each field's shape and value type follow how the message holds it" {
    const fields = Sample.protobuf.fields;
    const shapes = [_]Shape{ .plain, .optional, .optional, .lazy, .member, .member, .repeated, .map };
    inline for (fields, shapes) |field, shape| try testing.expectEqual(shape, comptime of(Sample, field));
    try testing.expect(Value(Sample, fields[0]) == i32);
    try testing.expect(Value(Sample, fields[1]) == []const u8);
    try testing.expect(Value(Sample, fields[2]) == proto.wkt.Int32Value);
    try testing.expect(Value(Sample, fields[3]) == Sample);
    try testing.expect(Value(Sample, fields[5]) == u64);
    try testing.expect(Value(Sample, fields[6]) == proto.Repeated(f32, .float));
}

test "a wrapper names the scalar it holds, and a zero value is each type's default" {
    try testing.expectEqual(@as(?proto.Kind, .int32), wrapper_kind(proto.wkt.Int32Value));
    try testing.expectEqual(@as(?proto.Kind, .bytes), wrapper_kind(proto.wkt.BytesValue));
    try testing.expectEqual(@as(?proto.Kind, null), wrapper_kind(proto.wkt.Timestamp));
    try testing.expectEqual(@as(?proto.Kind, null), wrapper_kind(i32));
    try testing.expect(is_zero(i32, &0) and !is_zero(i32, &-1));
    try testing.expect(is_zero(f64, &0.0) and !is_zero(f64, &0.5));
    try testing.expect(is_zero(bool, &false) and !is_zero(bool, &true));
    try testing.expect(is_zero([]const u8, &"") and !is_zero([]const u8, &"a"));
    try testing.expect(is_zero(pb_ignore, &.ignore_unspecified) and !is_zero(pb_ignore, &.ignore_always));
    try testing.expect(!is_zero(Entry, &.{}));
}

const pb_ignore = @import("buf_validate_validate").Ignore;
