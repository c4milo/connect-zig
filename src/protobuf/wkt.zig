//! The well-known types of `google/protobuf/*.proto` that have their own JSON form, as the
//! generated structs `protoc-gen-connect-zig` maps them to (design §5). Their binary encoding is
//! an ordinary message's. Any's JSON form needs a registry of types, and Struct, Value and
//! ListValue come in a later step, so `encode_json` and `decode_json` refuse them with
//! `error.Unsupported`.
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
pub const Form = enum { message, timestamp, duration, field_mask, wrapper, unsupported };

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
    if (comptime eql(short, "Any") or eql(short, "Struct") or eql(short, "Value") or eql(short, "ListValue")) return .unsupported;
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
    try std.testing.expectEqual(Form.unsupported, comptime form(Any));
    try std.testing.expectEqual(Form.message, comptime form(Empty));
}
