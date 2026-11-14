//! The proto3 JSON tests: exact texts, round trips through JSON, what a parser accepts beyond
//! what a writer writes, and the forms of the well-known types.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");
const json_decode = @import("json_decode.zig");
const any = @import("any.zig");
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
    pub const FieldNumber = enum(u29) { stamp = 1, span = 2, wrapped = 3, mask = 4, empty = 5, label = 6 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Holder", .fields = &.{
        proto.field_of(FieldNumber.stamp, .message, .{}),
        proto.field_of(FieldNumber.span, .message, .{}),
        proto.field_of(FieldNumber.wrapped, .message, .{}),
        proto.field_of(FieldNumber.mask, .message, .{}),
        proto.field_of(FieldNumber.empty, .message, .{}),
        proto.field_of(FieldNumber.label, .message, .{}),
    } };
};

/// A repeated enum: JSON's null names its value 0 in a field, but no element of an array.
const Palette = struct {
    colors: proto.Repeated(binary_test.Color, .@"enum") = .{},
    pub const FieldNumber = enum(u29) { colors = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Palette", .fields = &.{
        proto.field_of(FieldNumber.colors, .@"enum", .{}),
    } };
};

const text_len = 1024;
const tokens_len = 256;
/// The JSON texts the invariant below reads: each kind of field, nested messages, a map, a
/// recursive chain, and the well-known types.
const nested_texts = [_][]const u8{
    "{\"int32Field\":-3,\"stringField\":\"x\",\"inner\":{\"a\":7,\"tags\":[\"x\",\"y\"]}," ++
        "\"inners\":[{\"a\":1},{\"tags\":[\"z\"]}],\"counts\":{\"k\":9,\"j\":8},\"sub\":{\"a\":2}}",
    "{\"node\":{\"value\":\"1\",\"next\":{\"value\":\"2\",\"next\":{}}}}",
    "{\"numbers\":[1,2,3],\"unpacked\":[4],\"color\":\"COLOR_GREEN\",\"name\":\"n\"}",
};

const Buffers = struct {
    text: [text_len]u8 = undefined,
    binary: [text_len]u8 = undefined,
    tokens: [tokens_len]u8 = undefined,
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

test "a message decoded from binary writes the JSON of the message it came from" {
    // A decoded message's repeated fields and maps hold their octets, which an iterator reads.
    var buffers: Buffers = .{};
    const node: Node = .{ .value = -3 };
    const all: All = .{
        .inner = .{ .a = 1, .tags = .of(&.{ "x", "y" }) },
        .numbers = .of(&.{ 1, 2 }),
        .counts = .of(&.{ .{ .key = "k", .value = 9 }, .{ .key = "j", .value = 8 } }),
        .node = .of(&node),
    };
    const want = try proto.encode_json(All, &all, &buffers.text);
    try testing.expect(std.mem.indexOf(u8, want, "\"counts\":{\"k\":9,\"j\":8}") != null);
    const decoded = try proto.decode(All, try proto.encode(All, &all, &buffers.binary));
    var again: [text_len]u8 = undefined;
    try testing.expectEqualStrings(want, try proto.encode_json(All, &decoded, &again));
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

/// Requires what the transcoder writes for `text` to pass `decode` whole, nested payloads
/// checked: `decode_json` decodes it one level (decision 9). A text it refuses writes nothing.
fn check_transcoded(comptime T: type, text: []const u8) !void {
    var buffers: Buffers = .{};
    const bytes = json_decode.transcode(T, text, &buffers.binary, &buffers.tokens, any.types) catch return;
    _ = try proto.decode(T, bytes);
}

test "the transcoder writes binary that decode accepts whole, so decode_json checks it once" {
    for (nested_texts) |text| try check_transcoded(All, text);
    try check_transcoded(Node, "{\"next\":" ** 20 ++ "{\"value\":\"9\"}" ++ "}" ** 20);
    try check_transcoded(Holder, "{\"stamp\":\"1972-01-01T10:00:20.021Z\",\"span\":\"-1.500s\",\"mask\":\"a.bC\",\"empty\":{}}");
}

fn fuzz_transcoded(_: void, smith: *testing.Smith) anyerror!void {
    var input: [text_len]u8 = @splat(0);
    const len = smith.slice(&input);
    try check_transcoded(All, input[0..len]);
    try check_transcoded(Node, input[0..len]);
}

test "fuzz: the transcoder writes binary that decode accepts whole, on any text" {
    try testing.fuzz({}, fuzz_transcoded, .{ .corpus = &nested_texts });
}

test "an array of a packed field transcodes to one packed record, as the encoder writes it" {
    var buffers: Buffers = .{};
    var encoded: [text_len]u8 = undefined;
    // `numbers` is packed and `unpacked` is not; an empty array writes nothing.
    for ([_][]const u8{ "{\"numbers\":[1,2,300],\"unpacked\":[4,5]}", "{\"numbers\":[],\"unpacked\":[]}", "{\"numbers\":[7]}" }) |text| {
        const bytes = try json_decode.transcode(All, text, &buffers.binary, &buffers.tokens, any.types);
        const message = try decode(All, text, &buffers);
        try testing.expectEqualSlices(u8, try proto.encode(All, &message, &encoded), bytes);
    }
    // "JSON Mapping": null is not an element of a repeated field, packed or not.
    try testing.expectError(error.UnexpectedToken, decode(All, "{\"numbers\":[1,null]}", &buffers));
    try testing.expectError(error.UnexpectedToken, decode(All, "{\"unpacked\":[null]}", &buffers));
    try testing.expectError(error.UnexpectedToken, decode(Palette, "{\"colors\":[null]}", &buffers));
    const palette = try decode(Palette, "{\"colors\":[\"COLOR_GREEN\",1]}", &buffers);
    var colors = palette.colors.iterator();
    try testing.expectEqual(binary_test.Color.green, (try colors.next()).?);
}

test "a field mask path that lowerCamelCase cannot carry back is refused" {
    var buffers: Buffers = .{};
    // An uppercase letter, a double underscore, an underscore at the end, and an underscore
    // before a digit or a dot each leave no exact trace in lowerCamelCase.
    for ([_][]const u8{ "fooBar", "foo__bar", "foo_", "foo_3_bar", "foo_.bar" }) |path| {
        const holder: Holder = .{ .mask = .{ .paths = .of(&.{path}) } };
        try testing.expectError(error.InvalidFieldMask, proto.encode_json(Holder, &holder, &buffers.text));
    }
    const holder: Holder = .{ .mask = .{ .paths = .of(&.{"foo3_bar"}) } };
    try testing.expectEqualStrings("{\"mask\":\"foo3Bar\"}", try proto.encode_json(Holder, &holder, &buffers.text));
}
