//! Unknown fields: a message decoded with an older schema keeps the fields it does not know and
//! writes them back, so a proxy or an older service passes newer fields on (decision 24).
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");

/// The newer schema: fields 1, 2 and 3.
const Newer = struct {
    a: i32 = 0,
    b: []const u8 = "",
    c: proto.Repeated(i32, .int32) = .{},
    pub const FieldNumber = enum(u29) { a = 1, b = 2, c = 3 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Message", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}),
        proto.field_of(FieldNumber.b, .string, .{}),
        proto.field_of(FieldNumber.c, .int32, .{}),
    } };
};

/// The older schema: fields 1 and 3, and room for what it does not know.
const Older = struct {
    a: i32 = 0,
    c: proto.Repeated(i32, .int32) = .{},
    _unknown: proto.Unknown = .{},
    pub const FieldNumber = enum(u29) { a = 1, c = 3 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Message", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}),
        proto.field_of(FieldNumber.c, .int32, .{}),
    } };
};

/// The older schema without room for unknown fields, which drops them.
const Dropping = struct {
    a: i32 = 0,
    pub const FieldNumber = enum(u29) { a = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Message", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}),
    } };
};

test "an older schema keeps a newer field and writes it back" {
    var newer_bytes: [64]u8 = undefined;
    const newer = try proto.encode(Newer, &.{ .a = 1, .b = "kept", .c = .of(&.{ 2, 3 }) }, &newer_bytes);
    const older = try proto.decode(Older, newer);
    try testing.expectEqual(@as(i32, 1), older.a);
    var again_bytes: [64]u8 = undefined;
    const again = try proto.encode(Older, &older, &again_bytes);
    try testing.expectEqual(newer.len, again.len);
    try testing.expectEqual(newer.len, try proto.encoded_len(Older, &older));
    // Read back with the newer schema, every field is there. The unknown field now follows the
    // known ones, as Go writes it.
    const back = try proto.decode(Newer, again);
    try testing.expectEqualStrings("kept", back.b);
    var numbers = back.c.iterator();
    try testing.expectEqual(@as(i32, 2), (try numbers.next()).?);
    try testing.expectEqual(@as(i32, 3), (try numbers.next()).?);
}

test "a known field inside the kept span is written once" {
    // a, then b unknown, then a again, then b again: the span runs from the first b to the last,
    // and the a inside it is not written a second time.
    var buffer: [64]u8 = undefined;
    var writer: @import("wire.zig").Writer = .{ .buffer = &buffer };
    for ([_][]const u8{ "x", "y" }, 0..) |text, index| {
        try writer.tag(@intFromEnum(Newer.FieldNumber.a), .varint);
        try writer.varint(index);
        try writer.tag(@intFromEnum(Newer.FieldNumber.b), .len);
        try writer.varint(text.len);
        try writer.bytes(text);
    }
    const older = try proto.decode(Older, writer.written());
    var out: [64]u8 = undefined;
    const encoded = try proto.encode(Older, &older, &out);
    // a (2 octets, the last value 1) and the two b records (3 octets each).
    try testing.expectEqual(@as(usize, 2 + 3 + 3), encoded.len);
}

test "a message with no room for unknown fields drops them" {
    var newer_bytes: [64]u8 = undefined;
    const newer = try proto.encode(Newer, &.{ .a = 1, .b = "dropped" }, &newer_bytes);
    const dropping = try proto.decode(Dropping, newer);
    var out: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), (try proto.encode(Dropping, &dropping, &out)).len);
}
