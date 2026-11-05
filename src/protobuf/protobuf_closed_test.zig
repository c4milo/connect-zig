//! Closed enums and unchecked strings (editions, "enum_type" and "utf8_validation"). A number a
//! closed enum does not name stays out of its field and goes to the unknown fields, whole map
//! entries with it, and is written back. `tools/coverage_check.sh` checks the same against upb.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");

const Size = enum(i32) {
    unspecified = 0,
    small = 1,
    large = 2,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "test.Size", .closed = true, .values = &.{
        .{ .name = "SIZE_UNSPECIFIED", .number = @intFromEnum(@This().unspecified) },
        .{ .name = "SMALL", .number = @intFromEnum(@This().small) },
        .{ .name = "LARGE", .number = @intFromEnum(@This().large) },
    } };
};

/// The same numbers, open: it keeps every number in its field.
const OpenSize = enum(i32) {
    unspecified = 0,
    small = 1,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "test.OpenSize", .values = &.{
        .{ .name = "SIZE_UNSPECIFIED", .number = @intFromEnum(@This().unspecified) },
        .{ .name = "SMALL", .number = @intFromEnum(@This().small) },
    } };
};

const Entry = struct {
    key: []const u8 = "",
    value: Size = @enumFromInt(0),
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Shirt.ByNameEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .@"enum", .{}),
    } };
};

const Shirt = struct {
    size: ?Size = null,
    sizes: proto.Repeated(Size, .@"enum") = .{},
    by_name: proto.Repeated(Entry, .message) = .{},
    pick: ?union(enum) { picked: Size, label: []const u8 } = null,
    open: ?OpenSize = null,
    raw: []const u8 = "",
    _unknown: proto.Unknown = .{},
    pub const FieldNumber = enum(u29) { size = 1, sizes = 2, by_name = 3, picked = 4, label = 5, open = 6, raw = 7 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Shirt", .fields = &.{
        proto.field_of(FieldNumber.size, .@"enum", .{}),
        proto.field_of(FieldNumber.sizes, .@"enum", .{}),
        proto.field_of(FieldNumber.by_name, .message, .{}),
        proto.field_of(FieldNumber.picked, .@"enum", .{ .oneof = "pick" }),
        proto.field_of(FieldNumber.label, .string, .{ .oneof = "pick" }),
        proto.field_of(FieldNumber.open, .@"enum", .{}),
        proto.field_of(FieldNumber.raw, .unvalidated_string, .{}),
    } };
};

/// size: LARGE, then 7; sizes packed: SMALL, 9, LARGE; by_name: {a: SMALL}, {b: 8}; picked: 6;
/// open: 5. Every number but 5 is one a closed enum does not name.
const input = @embedFile("testdata/closed_enums.binpb");

test "a number a closed enum does not name leaves the field as it was" {
    const shirt = try proto.decode(Shirt, input);
    try testing.expectEqual(Size.large, shirt.size.?);
    // The oneof's member was never set, so the oneof stays empty.
    try testing.expect(shirt.pick == null);
    // An open enum keeps the number.
    try testing.expectEqual(@as(i32, 5), @intFromEnum(shirt.open.?));
}

test "a repeated closed enum and a map skip what the enum does not name" {
    const shirt = try proto.decode(Shirt, input);
    var sizes = shirt.sizes.iterator();
    try testing.expectEqual(Size.small, (try sizes.next()).?);
    try testing.expectEqual(Size.large, (try sizes.next()).?);
    try testing.expectEqual(@as(?Size, null), try sizes.next());
    try testing.expectEqual(@as(usize, 2), try shirt.sizes.count());
    var entries = shirt.by_name.iterator();
    try testing.expectEqualStrings("a", (try entries.next()).?.key);
    try testing.expectEqual(@as(?Entry, null), try entries.next());
}

test "what a closed enum did not take is written back" {
    const shirt = try proto.decode(Shirt, input);
    var buffer: [128]u8 = undefined;
    const again = try proto.encode(Shirt, &shirt, &buffer);
    try testing.expectEqual(again.len, try proto.encoded_len(Shirt, &shirt));
    // Every input octet's value comes back: 7 and 6 from the unknown fields, 9 as a record of
    // its own after the packed sizes, and the entry b whole.
    const want = [_]u8{
        0x08, 0x02, // size
        0x12, 0x02, 0x01, 0x02, 0x10, 0x09, // sizes, then 9
        0x1a, 0x05, 0x0a, 0x01, 'a', 0x10, 0x01, 0x1a, 0x05, 0x0a, 0x01, 'b', 0x10, 0x08, // by_name
        0x30, 0x05, // open
        0x08, 0x07, 0x20, 0x06, // the unknown fields
    };
    try testing.expectEqualSlices(u8, &want, again);
}

test "JSON takes no number a closed enum does not name" {
    var work: [256]u8 = undefined;
    var tokens: [64]u8 = undefined;
    try testing.expectError(error.InvalidEnum, proto.decode_json(Shirt, "{\"size\":7}", &work, &tokens));
    const shirt = try proto.decode_json(Shirt, "{\"size\":2,\"open\":5}", &work, &tokens);
    try testing.expectEqual(Size.large, shirt.size.?);
}

test "a string whose utf8_validation is NONE is read unchecked, and JSON refuses it" {
    const bytes = [_]u8{ 0x3a, 0x02, 0xff, 0xfe };
    const shirt = try proto.decode(Shirt, &bytes);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xfe }, shirt.raw);
    var text: [64]u8 = undefined;
    try testing.expectError(error.InvalidUtf8, proto.encode_json(Shirt, &shirt, &text));
    // A map key whose utf8_validation is NONE is refused the same way.
    const Labels = struct {
        const LabelEntry = struct {
            key: []const u8 = "",
            value: i32 = 0,
            pub const FieldNumber = enum(u29) { key = 1, value = 2 };
            pub const protobuf: proto.Descriptor = .{ .full_name = "test.Labels.ByNameEntry", .map_entry = true, .fields = &.{
                proto.field_of(@This().FieldNumber.key, .unvalidated_string, .{}), proto.field_of(@This().FieldNumber.value, .int32, .{}),
            } };
        };
        by_name: proto.Repeated(LabelEntry, .message) = .{},
        pub const FieldNumber = enum(u29) { by_name = 1 };
        pub const protobuf: proto.Descriptor = .{ .full_name = "test.Labels", .fields = &.{proto.field_of(FieldNumber.by_name, .message, .{})} };
    };
    const labels: Labels = .{ .by_name = .of(&.{.{ .key = &.{ 0xff, 0xfe }, .value = 1 }}) };
    try testing.expectError(error.InvalidUtf8, proto.encode_json(Labels, &labels, &text));
}
