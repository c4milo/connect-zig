//! The proto3 JSON tests: exact texts, round trips through JSON, what a parser accepts beyond
//! what a writer writes, and the forms of the well-known types.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");
const binary_test = @import("protobuf_test.zig");
const All = binary_test.All;
const Inner = binary_test.Inner;
const Node = binary_test.Node;
const wkt = proto.wkt;

const Holder = struct {
    stamp: ?wkt.Timestamp = null,
    span: ?wkt.Duration = null,
    wrapped: ?wkt.Int32Value = null,
    mask: ?wkt.FieldMask = null,
    empty: ?wkt.Empty = null,
    label: ?wkt.StringValue = null,
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Holder", .fields = &.{
        .{ .name = "stamp", .number = 1, .kind = .message, .json_name = "stamp", .proto_name = "stamp" },
        .{ .name = "span", .number = 2, .kind = .message, .json_name = "span", .proto_name = "span" },
        .{ .name = "wrapped", .number = 3, .kind = .message, .json_name = "wrapped", .proto_name = "wrapped" },
        .{ .name = "mask", .number = 4, .kind = .message, .json_name = "mask", .proto_name = "mask" },
        .{ .name = "empty", .number = 5, .kind = .message, .json_name = "empty", .proto_name = "empty" },
        .{ .name = "label", .number = 6, .kind = .message, .json_name = "label", .proto_name = "label" },
    } };
};

const Buffers = struct {
    text: [1024]u8 = undefined,
    binary: [1024]u8 = undefined,
    tokens: [256]u8 = undefined,
};

fn decode(comptime T: type, text: []const u8, buffers: *Buffers) proto.JsonDecodeError!T {
    return proto.decode_json(T, text, &buffers.binary, &buffers.tokens);
}

test "a message is written with JSON names, defaults left off" {
    var buffers: Buffers = .{};
    const inner: Inner = .{ .a = 7, .tags = .of(&.{ "x", "y" }) };
    try testing.expectEqualStrings("{\"a\":7,\"tags\":[\"x\",\"y\"]}", try proto.encode_json(Inner, &inner, &buffers.text));
    try testing.expectEqualStrings("{}", try proto.encode_json(Inner, &.{}, &buffers.text));
}

test "every kind round-trips through JSON" {
    var buffers: Buffers = .{};
    const node: Node = .{ .value = -3 };
    const all: All = .{
        .int32_field = -5,
        .uint64_field = std.math.maxInt(u64),
        .double_field = std.math.inf(f64),
        .bytes_field = &.{ 0, 255 },
        .color = .green,
        .optional_int = 0,
        .inner = .{ .a = 1 },
        .numbers = .of(&.{ 1, 2 }),
        .counts = .of(&.{.{ .key = "k", .value = 9 }}),
        .choice = .{ .name = "" },
        .node = .of(&node),
    };
    const text = try proto.encode_json(All, &all, &buffers.text);
    try testing.expect(std.mem.indexOf(u8, text, "\"uint64Field\":\"18446744073709551615\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"counts\":{\"k\":9}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"color\":\"COLOR_GREEN\"") != null);
    const back = try decode(All, text, &buffers);
    try testing.expectEqual(all.uint64_field, back.uint64_field);
    try testing.expect(std.math.isInf(back.double_field));
    try testing.expectEqualSlices(u8, all.bytes_field, back.bytes_field);
    try testing.expectEqual(@as(?i32, 0), back.optional_int);
    try testing.expectEqualStrings("", back.choice.?.name);
    try testing.expectEqual(@as(i64, -3), (try back.node.get()).?.value);
    try testing.expectEqual(@as(?i32, 9), try proto.map_get(@TypeOf(back.counts), &back.counts, "k"));
}

test "a parser takes .proto names, quoted numbers, enum numbers and null" {
    var buffers: Buffers = .{};
    const text = "{\"int32_field\":\"12\",\"color\":1,\"stringField\":null,\"sint32Field\":1e1}";
    const all = try decode(All, text, &buffers);
    try testing.expectEqual(@as(i32, 12), all.int32_field);
    try testing.expectEqual(binary_test.Color.red, all.color);
    try testing.expectEqual(@as(i32, 10), all.sint32_field);
}

test "a parser refuses unknown members, bad enums, fractions and nesting past the bound" {
    var buffers: Buffers = .{};
    try testing.expectError(error.UnknownField, decode(All, "{\"nope\":1}", &buffers));
    try testing.expectError(error.InvalidEnum, decode(All, "{\"color\":\"BLUE\"}", &buffers));
    try testing.expectError(error.InvalidNumber, decode(All, "{\"int32Field\":1.5}", &buffers));
    try testing.expectError(error.UnexpectedToken, decode(All, "[]", &buffers));
    const deep = "{\"next\":" ** 100 ++ "{}" ++ "}" ** 100;
    var big: [4096]u8 = undefined;
    try testing.expectError(error.DepthExceeded, proto.decode_json(Node, deep, &big, &buffers.tokens));
}

test "the well-known types take their own forms both ways" {
    var buffers: Buffers = .{};
    const holder: Holder = .{
        .stamp = .{ .seconds = 63_108_020, .nanos = 21_000_000 },
        .span = .{ .seconds = -1, .nanos = -500_000_000 },
        .wrapped = .{ .value = 0 },
        .mask = .{ .paths = .of(&.{ "user.display_name", "photo" }) },
        .empty = .{},
        .label = .{ .value = "hi" },
    };
    const text = try proto.encode_json(Holder, &holder, &buffers.text);
    try testing.expectEqualStrings(
        "{\"stamp\":\"1972-01-01T10:00:20.021Z\",\"span\":\"-1.500s\",\"wrapped\":0," ++
            "\"mask\":\"user.displayName,photo\",\"empty\":{},\"label\":\"hi\"}",
        text,
    );
    const back = try decode(Holder, text, &buffers);
    try testing.expectEqual(@as(i32, 21_000_000), back.stamp.?.nanos);
    try testing.expectEqual(@as(i64, -1), back.span.?.seconds);
    try testing.expectEqual(@as(i32, 0), back.wrapped.?.value);
    var paths = back.mask.?.paths.iterator();
    try testing.expectEqualStrings("user.display_name", (try paths.next()).?);
    try testing.expectEqualStrings("hi", back.label.?.value);
}

test "Any has no JSON form in this version" {
    var buffers: Buffers = .{};
    try testing.expectError(error.Unsupported, proto.encode_json(wkt.Any, &.{}, &buffers.text));
}
