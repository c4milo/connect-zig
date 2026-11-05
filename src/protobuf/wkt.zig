//! The well-known types of `google/protobuf/*.proto` that have their own JSON form, as the
//! generated structs `protoc-gen-connect-zig` maps them to (design §5). Their binary encoding is
//! an ordinary message's. Struct, Value and ListValue read and write any JSON value. Any's JSON
//! form names its type, so it needs the type: the well-known types are always known, and a
//! program names its own (decision 21).
const descriptor = @import("descriptor.zig");
const repeated = @import("repeated.zig");
const Descriptor = descriptor.Descriptor;
const field_of = descriptor.field_of;

/// An instant: seconds since the Unix epoch, and nanoseconds within the second.
pub const Timestamp = struct {
    seconds: i64 = 0,
    nanos: i32 = 0,
    pub const FieldNumber = enum(u29) { seconds = 1, nanos = 2 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.Timestamp", .fields = &.{
        field_of(FieldNumber.seconds, .int64, .{}), field_of(FieldNumber.nanos, .int32, .{}),
    } };
};

/// A signed span of time. `seconds` and `nanos` carry the same sign.
pub const Duration = struct {
    seconds: i64 = 0,
    nanos: i32 = 0,
    pub const FieldNumber = enum(u29) { seconds = 1, nanos = 2 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.Duration", .fields = &.{
        field_of(FieldNumber.seconds, .int64, .{}), field_of(FieldNumber.nanos, .int32, .{}),
    } };
};

pub const Empty = struct {
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.Empty", .fields = &.{} };
};

/// A set of field paths, written in JSON as one string of lowerCamelCase paths joined by commas.
pub const FieldMask = struct {
    paths: repeated.Repeated([]const u8, .string) = .{},
    pub const FieldNumber = enum(u29) { paths = 1 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.FieldMask", .fields = &.{field_of(FieldNumber.paths, .string, .{})} };
};

/// A message of any type: its type URL and its encoded bytes.
pub const Any = struct {
    type_url: []const u8 = "",
    value: []const u8 = "",
    pub const FieldNumber = enum(u29) { type_url = 1, value = 2 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.Any", .fields = &.{
        field_of(FieldNumber.type_url, .string, .{ .json_name = "typeUrl" }), field_of(FieldNumber.value, .bytes, .{}),
    } };
};

/// The one value of NullValue, which JSON writes as `null`.
pub const NullValue = enum(i32) {
    null_value = 0,
    _,
    pub const protobuf: descriptor.EnumDescriptor = .{ .full_name = "google.protobuf.NullValue", .values = &.{
        .{ .name = "NULL_VALUE", .number = @intFromEnum(@This().null_value) },
    } };
};

/// A JSON object: names mapped to values.
pub const Struct = struct {
    fields: repeated.Repeated(FieldsEntry, .message) = .{},
    pub const FieldNumber = enum(u29) { fields = 1 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.Struct", .fields = &.{field_of(@This().FieldNumber.fields, .message, .{})} };

    pub const FieldsEntry = struct {
        key: []const u8 = "",
        value: repeated.Lazy(Value) = .{},
        pub const FieldNumber = enum(u29) { key = 1, value = 2 };
        pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.Struct.FieldsEntry", .map_entry = true, .fields = &.{
            field_of(@This().FieldNumber.key, .string, .{}), field_of(@This().FieldNumber.value, .message, .{}),
        } };
    };
};

/// One JSON value of any kind.
pub const Value = struct {
    kind: ?union(enum) {
        null_value: NullValue,
        number_value: f64,
        string_value: []const u8,
        bool_value: bool,
        struct_value: repeated.Lazy(Struct),
        list_value: repeated.Lazy(ListValue),
    } = null,
    pub const FieldNumber = enum(u29) { null_value = 1, number_value = 2, string_value = 3, bool_value = 4, struct_value = 5, list_value = 6 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.Value", .fields = &.{
        field_of(FieldNumber.null_value, .@"enum", .{ .json_name = "nullValue", .oneof = "kind" }),
        field_of(FieldNumber.number_value, .double, .{ .json_name = "numberValue", .oneof = "kind" }),
        field_of(FieldNumber.string_value, .string, .{ .json_name = "stringValue", .oneof = "kind" }),
        field_of(FieldNumber.bool_value, .bool, .{ .json_name = "boolValue", .oneof = "kind" }),
        field_of(FieldNumber.struct_value, .message, .{ .json_name = "structValue", .oneof = "kind" }),
        field_of(FieldNumber.list_value, .message, .{ .json_name = "listValue", .oneof = "kind" }),
    } };
};

/// A JSON array.
pub const ListValue = struct {
    values: repeated.Repeated(Value, .message) = .{},
    pub const FieldNumber = enum(u29) { values = 1 };
    pub const protobuf: Descriptor = .{ .full_name = "google.protobuf.ListValue", .fields = &.{field_of(FieldNumber.values, .message, .{})} };
};

fn Wrapper(comptime full_name: []const u8, comptime V: type, comptime kind: descriptor.Kind) type {
    return struct {
        value: V = @as(V, if (V == []const u8) "" else if (V == bool) false else 0),
        pub const FieldNumber = enum(u29) { value = 1 };
        pub const protobuf: Descriptor = .{ .full_name = full_name, .fields = &.{field_of(FieldNumber.value, kind, .{})} };
    };
}

pub const DoubleValue = Wrapper("google.protobuf.DoubleValue", f64, .double);
pub const FloatValue = Wrapper("google.protobuf.FloatValue", f32, .float);
pub const Int64Value = Wrapper("google.protobuf.Int64Value", i64, .int64);
pub const UInt64Value = Wrapper("google.protobuf.UInt64Value", u64, .uint64);
pub const Int32Value = Wrapper("google.protobuf.Int32Value", i32, .int32);
pub const UInt32Value = Wrapper("google.protobuf.UInt32Value", u32, .uint32);
pub const BoolValue = Wrapper("google.protobuf.BoolValue", bool, .bool);
pub const StringValue = Wrapper("google.protobuf.StringValue", []const u8, .string);
pub const BytesValue = Wrapper("google.protobuf.BytesValue", []const u8, .bytes);

/// Which JSON form a message takes.
pub const Form = enum { message, timestamp, duration, field_mask, wrapper, struct_object, value, list_value, any };

pub fn form(comptime T: type) Form {
    const name = T.protobuf.full_name;
    const prefix = "google.protobuf.";
    if (!comptime starts_with(name, prefix)) return .message;
    const short = name[prefix.len..];
    if (comptime eql(short, "Timestamp")) return .timestamp;
    if (comptime eql(short, "Duration")) return .duration;
    if (comptime eql(short, "Empty")) return .message;
    if (comptime eql(short, "FieldMask")) return .field_mask;
    if (comptime ends_with(short, "Value") and !eql(short, "Value") and !eql(short, "ListValue")) return .wrapper;
    if (comptime eql(short, "Struct")) return .struct_object;
    if (comptime eql(short, "Value")) return .value;
    if (comptime eql(short, "ListValue")) return .list_value;
    if (comptime eql(short, "Any")) return .any;
    return .message;
}

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}

fn starts_with(comptime a: []const u8, comptime prefix: []const u8) bool {
    return @import("std").mem.startsWith(u8, a, prefix);
}

fn ends_with(comptime a: []const u8, comptime suffix: []const u8) bool {
    return @import("std").mem.endsWith(u8, a, suffix);
}

test "each well-known type takes its JSON form" {
    const std = @import("std");
    try std.testing.expectEqual(Form.timestamp, comptime form(Timestamp));
    try std.testing.expectEqual(Form.wrapper, comptime form(BoolValue));
    try std.testing.expectEqual(Form.field_mask, comptime form(FieldMask));
    try std.testing.expectEqual(Form.any, comptime form(Any));
    try std.testing.expectEqual(Form.struct_object, comptime form(Struct));
    try std.testing.expectEqual(Form.value, comptime form(Value));
    try std.testing.expectEqual(Form.list_value, comptime form(ListValue));
    try std.testing.expectEqual(Form.message, comptime form(Empty));
}
