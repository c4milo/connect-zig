//! Groups: a message written between a start and an end tag, which proto2 groups and editions'
//! DELIMITED message encoding both use ("Groups", encoding guide).
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");
const Inner = @import("protobuf_test.zig").Inner;

const Grouped = struct {
    item: ?Inner = null,
    items: proto.Repeated(Inner, .group) = .{},
    after: i32 = 0,
    pub const FieldNumber = enum(u29) { item = 1, items = 2, after = 3 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Grouped", .fields = &.{
        proto.field_of(FieldNumber.item, .group, .{}),
        proto.field_of(FieldNumber.items, .group, .{}),
        proto.field_of(FieldNumber.after, .int32, .{}),
    } };
};

test "a group is written between its tags, with no length" {
    // item { a: 5 }, items [{ a: 1 }, { a: 2 }], after 7: each group between its start tag
    // (number << 3 | 3) and its end tag (number << 3 | 4).
    const encoded = [_]u8{ 0x0b, 0x08, 5, 0x0c, 0x13, 0x08, 1, 0x14, 0x13, 0x08, 2, 0x14, 0x18, 7 };
    const message: Grouped = .{ .item = .{ .a = 5 }, .items = .of(&.{ .{ .a = 1 }, .{ .a = 2 } }), .after = 7 };
    var buffer: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &encoded, try proto.encode(Grouped, &message, &buffer));
    try testing.expectEqual(encoded.len, try proto.encoded_len(Grouped, &message));
}

test "a group reads back, its repeated form too, and a field after it" {
    const encoded = [_]u8{ 0x0b, 0x08, 5, 0x0c, 0x13, 0x08, 1, 0x14, 0x13, 0x08, 2, 0x14, 0x18, 7 };
    const message = try proto.decode(Grouped, &encoded);
    try testing.expectEqual(@as(i32, 5), message.item.?.a);
    var items = message.items.iterator();
    try testing.expectEqual(@as(i32, 1), (try items.next()).?.a);
    try testing.expectEqual(@as(i32, 2), (try items.next()).?.a);
    try testing.expectEqual(@as(?Inner, null), try items.next());
    try testing.expectEqual(@as(i32, 7), message.after);
}

test "a group whose end tag names another field, or that never ends, is refused" {
    // "Groups": the end tag carries the group's own field number.
    try testing.expectError(error.GroupMismatch, proto.decode(Grouped, &.{ 0x0b, 0x08, 5, 0x14 }));
    try testing.expectError(error.Truncated, proto.decode(Grouped, &.{ 0x0b, 0x08, 5 }));
    // A group field sent with a length is not the field's wire type.
    try testing.expectError(error.WireTypeMismatch, proto.decode(Grouped, &.{ 0x0a, 2, 0x08, 5 }));
}

test "a group is an object in JSON" {
    const encoded = [_]u8{ 0x0b, 0x08, 5, 0x0c, 0x13, 0x08, 1, 0x14, 0x13, 0x08, 2, 0x14, 0x18, 7 };
    const text = "{\"item\":{\"a\":5},\"items\":[{\"a\":1},{\"a\":2}],\"after\":7}";
    var binary: [128]u8 = undefined;
    var tokens: [64]u8 = undefined;
    const message = try proto.decode_json(Grouped, text, &binary, &tokens);
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(text, try proto.encode_json(Grouped, &message, &out));
    var again: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &encoded, try proto.encode(Grouped, &message, &again));
}
