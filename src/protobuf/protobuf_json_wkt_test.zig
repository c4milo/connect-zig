//! The JSON forms of Struct, Value, ListValue and Any ("JSON Mapping"; decision 21).
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");
const binary_test = @import("protobuf_test.zig");
const Inner = binary_test.Inner;
const wkt = proto.wkt;

const text_len = 1024;
const tokens_len = 256;

const Buffers = struct {
    text: [text_len]u8 = undefined,
    binary: [text_len]u8 = undefined,
    tokens: [tokens_len]u8 = undefined,
};

/// Reads `text` as a `T`, writes it back, and checks the text comes back the same.
fn round_trip(comptime T: type, text: []const u8, comptime any_types: []const type) !void {
    var buffers: Buffers = .{};
    const message = try proto.decode_json_with(T, text, &buffers.binary, &buffers.tokens, any_types);
    try testing.expectEqualStrings(text, try proto.encode_json_with(T, &message, &buffers.text, any_types));
}

const Document = struct {
    body: ?wkt.Struct = null,
    any_value: ?wkt.Value = null,
    items: proto.Repeated(wkt.Value, .message) = .{},
    pub const FieldNumber = enum(u29) { body = 1, any_value = 2, items = 3 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Document", .fields = &.{
        proto.field_of(FieldNumber.body, .message, .{}),
        proto.field_of(FieldNumber.any_value, .message, .{ .json_name = "anyValue" }),
        proto.field_of(FieldNumber.items, .message, .{}),
    } };
};

test "Struct, Value and ListValue read and write any JSON value" {
    try round_trip(wkt.Struct, "{\"a\":[1,\"x\",true,null,{\"b\":{}},[]],\"c\":-2.5}", &.{});
    try round_trip(wkt.Value, "\"text\"", &.{});
    try round_trip(wkt.Value, "null", &.{});
    try round_trip(wkt.ListValue, "[{},[[]],0,false]", &.{});
}

test "a Value field holds null, where any other field reads null as absent" {
    var buffers: Buffers = .{};
    const document = try proto.decode_json(Document, "{\"anyValue\":null,\"items\":[null,1]}", &buffers.binary, &buffers.tokens);
    try testing.expectEqual(wkt.NullValue.null_value, document.any_value.?.kind.?.null_value);
    try testing.expectEqualStrings("{\"anyValue\":null,\"items\":[null,1]}", try proto.encode_json(Document, &document, &buffers.text));
}

test "a Value with no kind, or a number JSON cannot hold, is refused" {
    var buffers: Buffers = .{};
    try testing.expectError(error.InvalidValue, proto.encode_json(wkt.Value, &.{}, &buffers.text));
    const nan: wkt.Value = .{ .kind = .{ .number_value = std.math.nan(f64) } };
    try testing.expectError(error.InvalidValue, proto.encode_json(wkt.Value, &nan, &buffers.text));
}

test "an Any holds a well-known type under value, and another type beside @type" {
    try round_trip(wkt.Any, "{\"@type\":\"type.googleapis.com/google.protobuf.Duration\",\"value\":\"1.500s\"}", &.{});
    try round_trip(wkt.Any, "{\"@type\":\"type.googleapis.com/google.protobuf.Empty\"}", &.{});
    try round_trip(wkt.Any, "{\"@type\":\"type.googleapis.com/test.Inner\",\"a\":7,\"tags\":[\"x\"]}", &.{Inner});
    try round_trip(wkt.Any, "{}", &.{});
    // An Any inside an Any.
    try round_trip(wkt.Any, "{\"@type\":\"type.googleapis.com/google.protobuf.Any\",\"value\":{\"@type\":\"type.googleapis.com/test.Inner\",\"a\":1}}", &.{Inner});
}

test "an Any's @type may follow its members" {
    var buffers: Buffers = .{};
    // Empty is read with "value" or without it.
    const empty = try proto.decode_json(wkt.Any, "{\"value\":{},\"@type\":\"type.googleapis.com/google.protobuf.Empty\"}", &buffers.binary, &buffers.tokens);
    try testing.expectEqualStrings("type.googleapis.com/google.protobuf.Empty", empty.type_url);
    const late = "{\"a\":7,\"tags\":[\"x\"],\"@type\":\"type.googleapis.com/test.Inner\"}";
    const message = try proto.decode_json_with(wkt.Any, late, &buffers.binary, &buffers.tokens, &.{Inner});
    const inner = try proto.decode(Inner, message.value);
    try testing.expectEqual(@as(i32, 7), inner.a);
    try testing.expectEqualStrings("type.googleapis.com/test.Inner", message.type_url);
}

test "an Any of a type the program did not name is refused both ways" {
    var buffers: Buffers = .{};
    const text = "{\"@type\":\"type.googleapis.com/test.Inner\",\"a\":7}";
    try testing.expectError(error.UnknownAnyType, proto.decode_json(wkt.Any, text, &buffers.binary, &buffers.tokens));
    const encoded = try proto.encode(Inner, &.{ .a = 7 }, &buffers.binary);
    const message: wkt.Any = .{ .type_url = "type.googleapis.com/test.Inner", .value = encoded };
    try testing.expectError(error.UnknownAnyType, proto.encode_json(wkt.Any, &message, &buffers.text));
    // A second "value", or a member an Any of a well-known type does not have.
    try testing.expectError(error.UnexpectedToken, proto.decode_json(wkt.Any, "{\"@type\":\"type.googleapis.com/google.protobuf.Empty\",\"value\":{},\"value\":{}}", &buffers.binary, &buffers.tokens));
    try testing.expectError(error.UnknownField, proto.decode_json(wkt.Any, "{\"@type\":\"type.googleapis.com/google.protobuf.Empty\",\"other\":1}", &buffers.binary, &buffers.tokens));
}
