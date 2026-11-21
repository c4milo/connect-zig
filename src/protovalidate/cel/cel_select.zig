//! A message's field as a CEL value, and `has` (CEL language definition, "Field Selection"). A
//! field that is not set reads as its type's default, and a wrapper that is not set as null.
const std = @import("std");
const proto = @import("protobuf");
const shape = @import("../shape.zig");
const field_file = @import("../field.zig");
const table = @import("../table.zig");
const type_file = @import("cel_type.zig");
const list_file = @import("cel_list.zig");

/// The field of `M` that an expression names: its name in the .proto file.
pub fn field_of(comptime M: type, comptime name: []const u8) ?proto.Field {
    const place = table.place_of_name(M, .proto, name) orelse return null;
    return M.protobuf.fields[place];
}

/// The CEL type of `field` of `M`, or null for a field the module does not read: a field of
/// the message's own type, and a map whose values are of it.
pub fn Type(comptime M: type, comptime field: proto.Field) ?type {
    const kind = shape.of(M, field);
    const F = shape.Holder(M, field);
    if (kind == .repeated) return list_file.List(F);
    if (kind == .map) return if (list_file.map_is_read(F)) list_file.Map(F) else null;
    if (shape.is_lazy(F)) return null;
    const V = shape.Value(M, field);
    const T = type_file.Of(field.kind, V);
    // A wrapper that is not set is null (CEL language definition, "Protocol Buffer Data
    // Conversion").
    if (shape.wrapper_kind(V) != null) return ?T;
    return T;
}

pub fn read(comptime M: type, comptime field: proto.Field, message: *const M) Type(M, field).? {
    const T = comptime Type(M, field).?;
    const V = shape.Value(M, field);
    const value: *const V = switch (comptime shape.of(M, field)) {
        .plain => &@field(message, field.name),
        .optional => if (@field(message, field.name)) |*set| set else return absent(T),
        .member => field_file.member_of(M, field, message) orelse return absent(T),
        // A list and a map are views of the field where it lies.
        .repeated, .map => return .{ .field = &@field(message, field.name) },
        .lazy => comptime unreachable,
    };
    return type_file.from(field.kind, V, value);
}

fn absent(comptime T: type) T {
    if (comptime @typeInfo(T) == .optional) return null;
    return type_file.default_of(T);
}

/// `has(message.field)`: the field is set, or, for a field with no presence, is not its zero
/// value (CEL language definition, "Field Selection").
pub fn has(comptime M: type, comptime field: proto.Field, message: *const M) bool {
    return field_file.is_set(M, field, message);
}

const testing = std.testing;

const Inner = struct {
    count: i32 = 0,
    pub const FieldNumber = enum(u29) { count = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Inner", .fields = &.{proto.field_of(FieldNumber.count, .int32, .{})} };
};

const Sample = struct {
    plain: u32 = 0,
    maybe: ?[]const u8 = null,
    wrapped: ?proto.wkt.Int32Value = null,
    inner: ?Inner = null,
    at: ?proto.wkt.Timestamp = null,
    choice: ?union(enum) { text: []const u8, count: i64, boxed: proto.wkt.BoolValue } = null,
    list: proto.Repeated(f32, .float) = .{},
    again: proto.Lazy(Sample) = .{},
    pub const FieldNumber = enum(u29) { plain = 1, maybe = 2, wrapped = 3, inner = 4, at = 5, text = 6, count = 7, boxed = 8, list = 9, again = 10 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Sample", .fields = &.{
        proto.field_of(FieldNumber.plain, .uint32, .{}),                   proto.field_of(FieldNumber.maybe, .string, .{}),
        proto.field_of(FieldNumber.wrapped, .message, .{}),                proto.field_of(FieldNumber.inner, .message, .{}),
        proto.field_of(FieldNumber.at, .message, .{}),                     proto.field_of(FieldNumber.text, .string, .{ .oneof = "choice" }),
        proto.field_of(FieldNumber.count, .int64, .{ .oneof = "choice" }), proto.field_of(FieldNumber.boxed, .message, .{ .oneof = "choice" }),
        proto.field_of(FieldNumber.list, .float, .{}),                     proto.field_of(FieldNumber.again, .message, .{}),
    } };
};

fn named(comptime name: []const u8) proto.Field {
    return comptime field_of(Sample, name).?;
}

test "a field's type follows its kind and how the message holds it" {
    try testing.expect(comptime Type(Sample, named("plain")).? == u64);
    try testing.expect(comptime Type(Sample, named("maybe")).? == []const u8);
    try testing.expect(comptime Type(Sample, named("wrapped")).? == ?i64);
    try testing.expect(comptime Type(Sample, named("inner")).? == *const Inner);
    try testing.expect(comptime Type(Sample, named("at")).? == proto.wkt.Timestamp);
    try testing.expect(comptime Type(Sample, named("count")).? == i64);
    try testing.expect(comptime Type(Sample, named("boxed")).? == ?bool);
    try testing.expect(comptime Type(Sample, named("list")).? == list_file.List(proto.Repeated(f32, .float)));
    try testing.expect(comptime Type(Sample, named("again")) == null);
    try testing.expect(comptime field_of(Sample, "missing") == null);
}

test "a field that is not set reads as its default, and a wrapper as null" {
    const empty: Sample = .{};
    try testing.expectEqual(@as(u64, 0), read(Sample, named("plain"), &empty));
    try testing.expectEqualStrings("", read(Sample, named("maybe"), &empty));
    try testing.expectEqual(@as(?i64, null), read(Sample, named("wrapped"), &empty));
    try testing.expectEqual(@as(i32, 0), read(Sample, named("inner"), &empty).count);
    try testing.expectEqual(@as(i64, 0), read(Sample, named("at"), &empty).seconds);
    try testing.expectEqualStrings("", read(Sample, named("text"), &empty));
    try testing.expectEqual(@as(?bool, null), read(Sample, named("boxed"), &empty));
    inline for (.{ "plain", "maybe", "wrapped", "inner", "text", "list", "again" }) |name| try testing.expect(!has(Sample, named(name), &empty));
}

test "a field that is set reads as its value, and a oneof's other member as its default" {
    const seven = 7;
    const full: Sample = .{ .plain = seven, .maybe = "m", .wrapped = .{ .value = -seven }, .inner = .{ .count = seven }, .at = .{ .seconds = seven }, .choice = .{ .count = seven } };
    try testing.expectEqual(@as(u64, seven), read(Sample, named("plain"), &full));
    try testing.expectEqualStrings("m", read(Sample, named("maybe"), &full));
    try testing.expectEqual(@as(?i64, -seven), read(Sample, named("wrapped"), &full));
    try testing.expectEqual(@as(i32, seven), read(Sample, named("inner"), &full).count);
    try testing.expectEqual(@as(i64, seven), read(Sample, named("at"), &full).seconds);
    try testing.expectEqual(@as(i64, seven), read(Sample, named("count"), &full));
    try testing.expectEqualStrings("", read(Sample, named("text"), &full));
    inline for (.{ "plain", "maybe", "wrapped", "inner", "count" }) |name| try testing.expect(has(Sample, named(name), &full));
    try testing.expect(!has(Sample, named("text"), &full));
    const boxed: Sample = .{ .choice = .{ .boxed = .{ .value = true } } };
    try testing.expectEqual(@as(?bool, true), read(Sample, named("boxed"), &boxed));
}

/// A message whose field has one name in Zig and another in its .proto file.
const Renamed = struct {
    kind_: i32 = 0,
    pub const FieldNumber = enum(u29) { kind = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Renamed", .fields = &.{
        .{ .name = "kind_", .number = @intFromEnum(FieldNumber.kind), .kind = .int32, .json_name = "kind", .proto_name = "kind" },
    } };
};

test "an expression names a field as its .proto file names it" {
    const field = (comptime field_of(Renamed, "kind")) orelse return error.TestExpectedField;
    try testing.expectEqualStrings("kind_", field.name);
    try testing.expect(comptime field_of(Renamed, "kind_") == null);
    const seven = 7;
    try testing.expectEqual(@as(i64, seven), read(Renamed, field, &.{ .kind_ = seven }));
}
