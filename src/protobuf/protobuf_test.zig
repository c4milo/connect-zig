//! The binary runtime's tests, over hand-written structs shaped as `protoc-gen-connect-zig`
//! writes them: round trips, packed and unpacked input, merge semantics, UTF-8, unknown fields
//! and groups, and the depth bound.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");
const Repeated = proto.Repeated;
const Lazy = proto.Lazy;

pub const Color = enum(i32) {
    unspecified = 0,
    red = 1,
    green = 2,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "test.Color", .values = &.{
        .{ .name = "COLOR_UNSPECIFIED", .number = 0 },
        .{ .name = "COLOR_RED", .number = 1 },
        .{ .name = "COLOR_GREEN", .number = 2 },
    } };
};

pub const Inner = struct {
    a: i32 = 0,
    tags: Repeated([]const u8, .string) = .{},
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Inner", .fields = &.{
        .{ .name = "a", .number = 1, .kind = .int32, .json_name = "a", .proto_name = "a" },
        .{ .name = "tags", .number = 2, .kind = .string, .json_name = "tags", .proto_name = "tags" },
    } };
};

pub const Node = struct {
    value: i64 = 0,
    next: Lazy(Node) = .{},
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Node", .fields = &.{
        .{ .name = "value", .number = 1, .kind = .int64, .json_name = "value", .proto_name = "value" },
        .{ .name = "next", .number = 2, .kind = .message, .json_name = "next", .proto_name = "next" },
    } };
};

pub const Entry = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.All.CountsEntry", .fields = &.{
        .{ .name = "key", .number = 1, .kind = .string, .json_name = "key", .proto_name = "key" },
        .{ .name = "value", .number = 2, .kind = .int32, .json_name = "value", .proto_name = "value" },
    } };
};

pub const All = struct {
    int32_field: i32 = 0,
    uint64_field: u64 = 0,
    sint32_field: i32 = 0,
    fixed64_field: u64 = 0,
    sfixed32_field: i32 = 0,
    float_field: f32 = 0,
    double_field: f64 = 0,
    bool_field: bool = false,
    string_field: []const u8 = "",
    bytes_field: []const u8 = "",
    color: Color = @enumFromInt(0),
    optional_int: ?i32 = null,
    inner: ?Inner = null,
    numbers: Repeated(i32, .int32) = .{},
    unpacked: Repeated(u32, .uint32) = .{},
    inners: Repeated(Inner, .message) = .{},
    counts: Repeated(Entry, .message) = .{},
    choice: ?union(enum) { name: []const u8, number: i32, sub: Inner } = null,
    node: Lazy(Node) = .{},

    pub const protobuf: proto.Descriptor = .{ .full_name = "test.All", .fields = &.{
        .{ .name = "int32_field", .number = 1, .kind = .int32, .json_name = "int32Field", .proto_name = "int32_field" },
        .{ .name = "uint64_field", .number = 2, .kind = .uint64, .json_name = "uint64Field", .proto_name = "uint64_field" },
        .{ .name = "sint32_field", .number = 3, .kind = .sint32, .json_name = "sint32Field", .proto_name = "sint32_field" },
        .{ .name = "fixed64_field", .number = 4, .kind = .fixed64, .json_name = "fixed64Field", .proto_name = "fixed64_field" },
        .{ .name = "sfixed32_field", .number = 5, .kind = .sfixed32, .json_name = "sfixed32Field", .proto_name = "sfixed32_field" },
        .{ .name = "float_field", .number = 6, .kind = .float, .json_name = "floatField", .proto_name = "float_field" },
        .{ .name = "double_field", .number = 7, .kind = .double, .json_name = "doubleField", .proto_name = "double_field" },
        .{ .name = "bool_field", .number = 8, .kind = .bool, .json_name = "boolField", .proto_name = "bool_field" },
        .{ .name = "string_field", .number = 9, .kind = .string, .json_name = "stringField", .proto_name = "string_field" },
        .{ .name = "bytes_field", .number = 10, .kind = .bytes, .json_name = "bytesField", .proto_name = "bytes_field" },
        .{ .name = "color", .number = 11, .kind = .@"enum", .json_name = "color", .proto_name = "color" },
        .{ .name = "optional_int", .number = 12, .kind = .int32, .json_name = "optionalInt", .proto_name = "optional_int" },
        .{ .name = "inner", .number = 13, .kind = .message, .json_name = "inner", .proto_name = "inner" },
        .{ .name = "numbers", .number = 14, .kind = .int32, .json_name = "numbers", .proto_name = "numbers" },
        .{ .name = "unpacked", .number = 15, .kind = .uint32, .json_name = "unpacked", .proto_name = "unpacked", .@"packed" = false },
        .{ .name = "inners", .number = 16, .kind = .message, .json_name = "inners", .proto_name = "inners" },
        .{ .name = "counts", .number = 17, .kind = .message, .json_name = "counts", .proto_name = "counts" },
        .{ .name = "name", .number = 18, .kind = .string, .json_name = "name", .proto_name = "name", .oneof = "choice" },
        .{ .name = "number", .number = 19, .kind = .int32, .json_name = "number", .proto_name = "number", .oneof = "choice" },
        .{ .name = "sub", .number = 20, .kind = .message, .json_name = "sub", .proto_name = "sub", .oneof = "choice" },
        .{ .name = "node", .number = 21, .kind = .message, .json_name = "node", .proto_name = "node" },
    } };
};

pub const Test1 = struct {
    a: i32 = 0,
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Test1", .fields = &.{
        .{ .name = "a", .number = 1, .kind = .int32, .json_name = "a", .proto_name = "a" },
    } };
};

test "the encoding guide's Test1 with a = 150 is 08 96 01" {
    var buffer: [8]u8 = undefined;
    const bytes = try proto.encode(Test1, &.{ .a = 150 }, &buffer);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x96, 0x01 }, bytes);
    try testing.expectEqual(@as(i32, 150), (try proto.decode(Test1, bytes)).a);
    try testing.expectEqual(@as(usize, 0), try proto.encoded_len(Test1, &.{}));
}

fn sample(node: *const Node) All {
    return .{
        .int32_field = -5,
        .uint64_field = std.math.maxInt(u64),
        .sint32_field = -300,
        .fixed64_field = 0x0102030405060708,
        .sfixed32_field = -2,
        .float_field = 1.5,
        .double_field = -0.0,
        .bool_field = true,
        .string_field = "héllo",
        .bytes_field = &.{ 0, 255 },
        .color = .green,
        .optional_int = 0,
        .inner = .{ .a = 7, .tags = .of(&.{ "x", "y" }) },
        .numbers = .of(&.{ 1, -1, 300 }),
        .unpacked = .of(&.{ 4, 5 }),
        .inners = .of(&.{ .{ .a = 1 }, .{ .a = 2 } }),
        .counts = .of(&.{ .{ .key = "k", .value = 1 }, .{ .key = "k", .value = 9 } }),
        .choice = .{ .number = 0 },
        .node = .of(node),
    };
}

test "every kind round-trips, and a decoded message encodes to the same bytes" {
    const node: Node = .{ .value = 3 };
    const all = sample(&node);
    var buffer: [512]u8 = undefined;
    const bytes = try proto.encode(All, &all, &buffer);
    try testing.expectEqual(bytes.len, try proto.encoded_len(All, &all));
    const back = try proto.decode(All, bytes);
    try testing.expectEqual(all.int32_field, back.int32_field);
    try testing.expectEqual(all.uint64_field, back.uint64_field);
    try testing.expectEqual(all.sint32_field, back.sint32_field);
    try testing.expectEqual(all.fixed64_field, back.fixed64_field);
    try testing.expect(std.math.signbit(back.double_field));
    try testing.expectEqualStrings(all.string_field, back.string_field);
    try testing.expectEqual(Color.green, back.color);
    try testing.expectEqual(@as(?i32, 0), back.optional_int);
    try testing.expectEqual(@as(i32, 7), back.inner.?.a);
    try testing.expectEqual(@as(usize, 2), try back.inner.?.tags.count());
    try testing.expectEqual(@as(i32, 0), back.choice.?.number);
    try testing.expectEqual(@as(i64, 3), (try back.node.get()).?.value);
    try testing.expectEqual(@as(?i32, 9), try proto.map_get(@TypeOf(back.counts), &back.counts, "k"));
    var again: [512]u8 = undefined;
    try testing.expectEqualSlices(u8, bytes, try proto.encode(All, &back, &again));
}

test "packed and unpacked input decode alike, and each form is written as its field says" {
    // Field 14 packed {1, 2}, then field 14 unpacked 3; field 15 packed {4}.
    const bytes = [_]u8{ 0x72, 0x02, 0x01, 0x02, 0x70, 0x03, 0x7a, 0x01, 0x04 };
    const all = try proto.decode(All, &bytes);
    var numbers = all.numbers.iterator();
    for ([_]i32{ 1, 2, 3 }) |want| try testing.expectEqual(want, (try numbers.next()).?);
    var buffer: [32]u8 = undefined;
    // numbers is written packed; unpacked writes one tag per element.
    const written = try proto.encode(All, &all, &buffer);
    try testing.expectEqualSlices(u8, &.{ 0x72, 0x03, 0x01, 0x02, 0x03, 0x78, 0x04 }, written);
}

test "a scalar keeps its last value, a message merges, and a oneof keeps its last member" {
    // inner{a:1}, int32 5, inner{tags:"t"}... no: inner{a:2} then int32 6 and choice name then number.
    const bytes = [_]u8{
        0x6a, 0x02, 0x08, 0x01, // inner { a: 1 }
        0x08, 0x05, // int32_field 5
        0x6a, 0x00, // inner {} merges and keeps a
        0x08, 0x06, // int32_field 6
        0x92, 0x01, 0x01, 'n', // name "n"
        0x98, 0x01, 0x04, // number 4
    };
    const all = try proto.decode(All, &bytes);
    try testing.expectEqual(@as(i32, 6), all.int32_field);
    try testing.expectEqual(@as(i32, 1), all.inner.?.a);
    try testing.expectEqual(@as(i32, 4), all.choice.?.number);
}

test "a repeated field inside a message that occurs twice is refused, not silently cut" {
    const bytes = [_]u8{ 0x6a, 0x03, 0x12, 0x01, 'a', 0x6a, 0x03, 0x12, 0x01, 'b' };
    try testing.expectError(error.MergeUnsupported, proto.decode(All, &bytes));
}

test "unknown fields and groups are skipped, and bad strings and wire types are refused" {
    // Field 99 varint, field 98 group with a varint inside, then int32_field 1.
    const bytes = [_]u8{ 0x98, 0x06, 0x01, 0x93, 0x06, 0x08, 0x01, 0x94, 0x06, 0x08, 0x01 };
    try testing.expectEqual(@as(i32, 1), (try proto.decode(All, &bytes)).int32_field);
    try testing.expectError(error.InvalidUtf8, proto.decode(All, &.{ 0x4a, 0x01, 0xc0 }));
    try testing.expectError(error.WireTypeMismatch, proto.decode(All, &.{ 0x0d, 0, 0, 0, 0 }));
    try testing.expectError(error.LengthTooLarge, proto.decode(All, &.{ 0x4a, 0x05, 'a' }));
    try testing.expectError(error.Truncated, proto.decode(All, &.{ 0x08, 0x80 }));
}

/// Writes `depth` nested `next` fields into the end of `buffer` and returns them.
fn nested(buffer: []u8, depth: usize) []const u8 {
    var start = buffer.len;
    for (0..depth) |_| {
        const inner_len = buffer.len - start;
        std.debug.assert(inner_len < 128 * 128);
        if (inner_len < 128) {
            start -= 2;
            buffer[start + 1] = @intCast(inner_len);
        } else {
            start -= 3;
            buffer[start + 1] = @as(u8, @intCast(inner_len & 0x7f)) | 0x80;
            buffer[start + 2] = @intCast(inner_len >> 7);
        }
        buffer[start] = 0x12;
    }
    return buffer[start..];
}

test "messages nested past the depth limit are refused" {
    var buffer: [512]u8 = undefined;
    const deep = nested(&buffer, proto.constants.limits.depth_max);
    try testing.expectError(error.DepthExceeded, proto.decode(Node, deep));
    const shallow = nested(&buffer, proto.constants.limits.depth_max - 2);
    _ = try proto.decode(Node, shallow);
}

test "a oneof message member that repeats merges into the one already set" {
    // sub { a: 3 }, then sub {} merges and keeps a; field 20 is 0xa2 0x01.
    const bytes = [_]u8{ 0xa2, 0x01, 0x02, 0x08, 0x03, 0xa2, 0x01, 0x00 };
    const all = try proto.decode(All, &bytes);
    try testing.expectEqual(@as(i32, 3), all.choice.?.sub.a);
}
