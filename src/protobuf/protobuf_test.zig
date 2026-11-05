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
        .{ .name = "COLOR_GREEN", .number = @intFromEnum(@This().green) },
    } };
};

pub const Inner = struct {
    a: i32 = 0,
    tags: Repeated([]const u8, .string) = .{},
    pub const FieldNumber = enum(u29) { a = 1, tags = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Inner", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}),
        proto.field_of(FieldNumber.tags, .string, .{}),
    } };
};

pub const Node = struct {
    value: i64 = 0,
    next: Lazy(Node) = .{},
    pub const FieldNumber = enum(u29) { value = 1, next = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Node", .fields = &.{
        proto.field_of(FieldNumber.value, .int64, .{}),
        proto.field_of(FieldNumber.next, .message, .{}),
    } };
};

pub const Entry = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.All.CountsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}),
        proto.field_of(FieldNumber.value, .int32, .{}),
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

    pub const FieldNumber = enum(u29) { int32_field = 1, uint64_field = 2, sint32_field = 3, fixed64_field = 4, sfixed32_field = 5, float_field = 6, double_field = 7, bool_field = 8, string_field = 9, bytes_field = 10, color = 11, optional_int = 12, inner = 13, numbers = 14, unpacked = 15, inners = 16, counts = 17, name = 18, number = 19, sub = 20, node = 21 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.All", .fields = &.{
        proto.field_of(FieldNumber.int32_field, .int32, .{ .json_name = "int32Field" }),
        proto.field_of(FieldNumber.uint64_field, .uint64, .{ .json_name = "uint64Field" }),
        proto.field_of(FieldNumber.sint32_field, .sint32, .{ .json_name = "sint32Field" }),
        proto.field_of(FieldNumber.fixed64_field, .fixed64, .{ .json_name = "fixed64Field" }),
        proto.field_of(FieldNumber.sfixed32_field, .sfixed32, .{ .json_name = "sfixed32Field" }),
        proto.field_of(FieldNumber.float_field, .float, .{ .json_name = "floatField" }),
        proto.field_of(FieldNumber.double_field, .double, .{ .json_name = "doubleField" }),
        proto.field_of(FieldNumber.bool_field, .bool, .{ .json_name = "boolField" }),
        proto.field_of(FieldNumber.string_field, .string, .{ .json_name = "stringField" }),
        proto.field_of(FieldNumber.bytes_field, .bytes, .{ .json_name = "bytesField" }),
        proto.field_of(FieldNumber.color, .@"enum", .{}),
        proto.field_of(FieldNumber.optional_int, .int32, .{ .json_name = "optionalInt" }),
        proto.field_of(FieldNumber.inner, .message, .{}),
        proto.field_of(FieldNumber.numbers, .int32, .{}),
        proto.field_of(FieldNumber.unpacked, .uint32, .{ .@"packed" = false }),
        proto.field_of(FieldNumber.inners, .message, .{}),
        proto.field_of(FieldNumber.counts, .message, .{}),
        proto.field_of(FieldNumber.name, .string, .{ .oneof = "choice" }),
        proto.field_of(FieldNumber.number, .int32, .{ .oneof = "choice" }),
        proto.field_of(FieldNumber.sub, .message, .{ .oneof = "choice" }),
        proto.field_of(FieldNumber.node, .message, .{}),
    } };
};

pub const Test1 = struct {
    a: i32 = 0,
    pub const FieldNumber = enum(u29) { a = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Test1", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}),
    } };
};

test "the encoding guide's Test1 with a = 150 is 08 96 01" {
    var buffer: [8]u8 = undefined;
    const bytes = try proto.encode(Test1, &.{ .a = 150 }, &buffer);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x96, 0x01 }, bytes);
    try testing.expectEqual(@as(i32, 150), (try proto.decode(Test1, bytes)).a);
    try testing.expectEqual(@as(usize, 0), try proto.encoded_len(Test1, &.{}));
}

test "every kind round-trips, and a decoded message encodes to the same bytes" {
    const node: Node = .{ .value = 3 };
    const all: All = .{
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
        .node = .of(&node),
    };
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

test "messages nested past the depth limit are refused" {
    const helpers = struct {
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
    };
    const nested = helpers.nested;
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

test "a nested message encodes alike into a roomy buffer and into one of its exact length" {
    const leaf: Node = .{ .value = 3 };
    const middle: Node = .{ .value = 2, .next = .of(&leaf) };
    const root: Node = .{ .value = 1, .next = .of(&middle) };
    var roomy: [64]u8 = undefined;
    const written = try proto.encode(Node, &root, &roomy);
    try testing.expectEqual(try proto.encoded_len(Node, &root), written.len);
    // In a buffer of the message's exact length, a child's length placeholder does not fit, so
    // the child is measured first; the bytes come out the same.
    var exact: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, written, try proto.encode(Node, &root, exact[0..written.len]));
    try testing.expectError(error.NoSpaceLeft, proto.encode(Node, &root, exact[0 .. written.len - 1]));
}

test "decode checks every level, and get reads one level and leaves the next to its own get" {
    // next { next { <a tag with no value> } }
    const malformed = [_]u8{ 0x12, 3, 0x12, 1, 0x08 };
    try testing.expectError(error.Truncated, proto.decode(Node, &malformed));
    // Bytes a program set itself fail at the level that holds the fault, when it is read.
    const lazy: Lazy(Node) = .{ .bytes = malformed[2..] };
    const level = (try lazy.get()).?;
    try testing.expectError(error.Truncated, level.next.get());
}

test "a deep chain encodes into a buffer of its exact length in time linear in its depth" {
    const depth = 64;
    var nodes: [depth]Node = undefined;
    nodes[0] = .{ .value = 1 };
    for (1..depth) |index| nodes[index] = .{ .value = 1, .next = .of(&nodes[index - 1]) };
    const root = &nodes[depth - 1];
    var roomy: [1024]u8 = undefined;
    const written = try proto.encode(Node, root, &roomy);
    // Once a placeholder does not fit, the rest of the subtree is measured before it is written.
    // Retrying the placeholder at each level would double the work at each one: 2^64 walks here.
    var exact: [1024]u8 = undefined;
    try testing.expectEqualSlices(u8, written, try proto.encode(Node, root, exact[0..written.len]));
}

test "a map entry writes its key and value even at their defaults, as Go and C++ do" {
    const entries = [_]Entry{.{ .key = "", .value = 0 }};
    const holder: All = .{ .counts = .of(&entries) };
    var buffer: [16]u8 = undefined;
    // Field 17 (8a 01), length 4: key "" (0a 00) and value 0 (10 00).
    try testing.expectEqualSlices(u8, &.{ 0x8a, 0x01, 4, 0x0a, 0, 0x10, 0 }, try proto.encode(All, &holder, &buffer));
}
