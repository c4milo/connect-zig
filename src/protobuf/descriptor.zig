//! The tables a generated message carries, which the generic encoder and decoder read at comptime.
//! A generated struct declares `pub const protobuf: Descriptor` naming each field, and a generated
//! enum declares `pub const protobuf: EnumDescriptor` naming each value (docs/design.md §4).
const std = @import("std");
const wire = @import("wire.zig");
const constants = @import("constants.zig");

/// A field's type in the .proto file (descriptor.proto's FieldDescriptorProto.Type), without
/// groups, which `decode` skips as unknown fields.
pub const Kind = enum {
    double,
    float,
    int64,
    uint64,
    int32,
    fixed64,
    fixed32,
    bool,
    string,
    message,
    bytes,
    uint32,
    @"enum",
    sfixed32,
    sfixed64,
    sint32,
    sint64,

    /// The wire type a single value of this kind takes ("Message Structure").
    pub fn wire_type(kind: Kind) wire.WireType {
        return switch (kind) {
            .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool, .@"enum" => .varint,
            .fixed64, .sfixed64, .double => .i64,
            .fixed32, .sfixed32, .float => .i32,
            .string, .bytes, .message => .len,
        };
    }

    /// Whether a repeated field of this kind may be packed: every scalar numeric kind
    /// ("Packed Repeated Fields").
    pub fn packable(kind: Kind) bool {
        return kind.wire_type() != .len;
    }
};

/// One field of a message.
pub const Field = struct {
    /// The Zig name: the struct's field, or, for a member of a oneof, the union's tag.
    name: []const u8,
    number: u32,
    kind: Kind,
    /// The lowerCamelCase name proto3 JSON writes (proto3 JSON mapping, "JSON Mapping").
    json_name: []const u8,
    /// The name in the .proto file, which a JSON parser also accepts.
    proto_name: []const u8,
    /// The Zig name of the oneof's union field, for a member of a oneof.
    oneof: ?[]const u8 = null,
    /// Whether a repeated packable field is written packed. Proto3 packs by default
    /// ("Packed Repeated Fields").
    @"packed": bool = true,
};

/// What `field_of` takes beside a field's number and kind.
pub const FieldOptions = struct {
    /// The JSON name, when it is not the .proto name: "typeUrl" for "type_url".
    json_name: ?[]const u8 = null,
    oneof: ?[]const u8 = null,
    @"packed": bool = true,
};

/// A field of a hand-written message, named and numbered by `tag`, a member of the message's
/// `FieldNumber` enum, as generated messages number their fields: `field_of(FieldNumber.code,
/// .int32, .{})`. The Zig name and the .proto name are the tag's name.
pub fn field_of(comptime tag: anytype, comptime kind: Kind, comptime options: FieldOptions) Field {
    const name = @tagName(tag);
    return .{
        .name = name,
        .number = @intFromEnum(tag),
        .kind = kind,
        .json_name = options.json_name orelse name,
        .proto_name = name,
        .oneof = options.oneof,
        .@"packed" = options.@"packed",
    };
}

/// A message's table: its full name and its fields, ordered by number.
pub const Descriptor = struct {
    full_name: []const u8,
    fields: []const Field,
    /// Whether the message is a map field's entry, whose JSON form is a member of an object
    /// ("Maps", language guide).
    map_entry: bool = false,
};

pub const EnumValue = struct {
    name: []const u8,
    number: i32,
};

/// An enum's table: its full name and each value's name in the .proto file, aliases included.
pub const EnumDescriptor = struct {
    full_name: []const u8,
    values: []const EnumValue,

    /// The first name of `number`, or null for a number the enum does not name.
    pub fn name_of(comptime descriptor: EnumDescriptor, number: i32) ?[]const u8 {
        inline for (descriptor.values) |value| {
            if (value.number == number) return value.name;
        }
        return null;
    }

    pub fn number_of(comptime descriptor: EnumDescriptor, name: []const u8) ?i32 {
        inline for (descriptor.values) |value| {
            if (std.mem.eql(u8, value.name, name)) return value.number;
        }
        return null;
    }
};

/// Where the elements of a decoded repeated field lie: the bytes of the message that holds them,
/// and the field's number. Decoding copies nothing; an iterator reads the elements from here.
pub const View = struct {
    bytes: []const u8 = &.{},
    number: u32 = 0,
};

/// Whether `T` is a generated enum.
pub fn is_enum(comptime T: type) bool {
    return @typeInfo(T) == .@"enum" and @hasDecl(T, "protobuf") and @TypeOf(T.protobuf) == EnumDescriptor;
}

/// Checks a descriptor against its struct at comptime: each field exists, numbers rise, and no
/// number repeats or falls in the reserved range ("Field Numbers").
pub fn check(comptime T: type) void {
    comptime {
        const fields = T.protobuf.fields;
        if (fields.len > constants.limits.fields_max) @compileError(T.protobuf.full_name ++ " has too many fields");
        var previous: u32 = 0;
        for (fields) |field| {
            if (field.number <= previous) @compileError(T.protobuf.full_name ++ ": numbers must rise");
            if (field.number > constants.protocol.field_number_max) @compileError("field number too large");
            const reserved = field.number >= constants.protocol.reserved_number_first and
                field.number <= constants.protocol.reserved_number_last;
            if (reserved) @compileError(T.protobuf.full_name ++ ": reserved field number");
            const holder = field.oneof orelse field.name;
            if (!@hasField(T, holder)) @compileError(T.protobuf.full_name ++ " has no field " ++ holder);
            previous = field.number;
        }
    }
}

test "field_of names and numbers a field by its tag" {
    const FieldNumber = enum(u29) { type_url = 1, value = 2 };
    const entry = field_of(FieldNumber.type_url, .string, .{ .json_name = "typeUrl" });
    try std.testing.expectEqualStrings("type_url", entry.name);
    try std.testing.expectEqualStrings("typeUrl", entry.json_name);
    try std.testing.expectEqual(@as(u32, 2), field_of(FieldNumber.value, .bytes, .{}).number);
}

test "wire types and packing follow the encoding's table" {
    try std.testing.expectEqual(wire.WireType.varint, Kind.sint64.wire_type());
    try std.testing.expectEqual(wire.WireType.i32, Kind.float.wire_type());
    try std.testing.expect(Kind.@"enum".packable());
    try std.testing.expect(!Kind.bytes.packable());
}

test "an enum descriptor maps names and numbers both ways" {
    const table: EnumDescriptor = .{ .full_name = "t.E", .values = &.{
        .{ .name = "E_ZERO", .number = 0 },
        .{ .name = "E_ONE", .number = 1 },
        .{ .name = "E_UNO", .number = 1 },
    } };
    try std.testing.expectEqualStrings("E_ONE", table.name_of(1).?);
    try std.testing.expectEqual(@as(?i32, 1), table.number_of("E_UNO"));
    try std.testing.expectEqual(@as(?[]const u8, null), table.name_of(7));
}
