//! protobuf: the binary encoding and the proto3 JSON mapping of protocol buffers, over structs
//! that `protoc-gen-connect-zig` generates, with no allocator and no I/O (docs/design.md §4).
//!
//! A generated message is a struct whose `pub const protobuf: Descriptor` names its fields. The
//! generic `encode`, `decode` and `encoded_len` read that table at comptime. `decode` copies
//! nothing: strings, bytes and repeated fields point into the input, which must outlive the
//! message. `decode_into` reads each repeated field into storage the caller passes, for a
//! program that reads every field (decision 37). The caller owns every buffer.
const std = @import("std");
const json = @import("json");
const codec = @import("codec");

pub const constants = @import("constants.zig");

const files = struct {
    pub const wire = @import("wire.zig");
    pub const descriptor = @import("descriptor.zig");
    pub const scalar = @import("scalar.zig");
    pub const repeated = @import("repeated.zig");
    pub const decode = @import("decode.zig");
    pub const decode_run = @import("decode_run.zig");
    pub const encode = @import("encode.zig");
    pub const json_scalar = @import("json_scalar.zig");
    pub const json_float = @import("json_float.zig");
    pub const json_encode = @import("json_encode.zig");
    pub const json_decode = @import("json_decode.zig");
    pub const json_decode_wkt = @import("json_decode_wkt.zig");
    pub const any = @import("any.zig");
    pub const time_text = @import("time_text.zig");
    pub const wkt = @import("wkt.zig");
};

/// A field's type in the .proto file.
pub const Kind = files.descriptor.Kind;
/// The wire type a field's tag carries (protobuf encoding guide, "Message Structure").
pub const WireType = files.wire.WireType;
pub const Field = files.descriptor.Field;
pub const FieldOptions = files.descriptor.FieldOptions;
/// A hand-written message's field, numbered by a member of its `FieldNumber` enum.
pub const field_of = files.descriptor.field_of;
pub const Descriptor = files.descriptor.Descriptor;
pub const EnumValue = files.descriptor.EnumValue;
pub const EnumDescriptor = files.descriptor.EnumDescriptor;
/// Where a decoded repeated field's elements lie.
pub const View = files.descriptor.View;
/// The fields a message does not know, which a generated message keeps (decision 24).
pub const Unknown = files.descriptor.Unknown;
pub const Repeated = files.repeated.Repeated;
pub const Lazy = files.repeated.Lazy;
/// What `decode` and `merge` refuse an input with.
pub const Error = files.decode.Error;
/// What `encode` and `encoded_len` fail with.
pub const EncodeError = files.encode.Error;

/// Decodes `bytes` as a `T`. Strings, bytes and repeated fields point into `bytes`.
pub fn decode(comptime T: type, bytes: []const u8) Error!T {
    // "Size Limitations": a message holds less than 2 GiB.
    if (bytes.len > constants.limits.message_len_max) return error.LengthTooLarge;
    return files.decode.decode_depth(T, bytes, constants.limits.depth_max, .checked, {});
}

/// Decodes `bytes` as `decode` does, and reads each repeated field's elements, and each `Lazy`
/// field's message, into `storage` while it has room. A later read of them parses nothing again,
/// so a program that reads every field takes this call. A field that finds no room points into
/// `bytes`, as `decode` leaves it. The message points into both, which must outlive it (decision
/// 37).
pub fn decode_into(comptime T: type, bytes: []const u8, storage: []u8) Error!T {
    if (bytes.len > constants.limits.message_len_max) return error.LengthTooLarge;
    var store: files.decode.Store = .{ .buffer = storage };
    return files.decode.decode_depth(T, bytes, constants.limits.depth_max, .stored, &store);
}

/// Merges `bytes` into `message`, as a later occurrence of the same message merges ("Last One
/// Wins", encoding guide).
pub fn merge(comptime T: type, message: *T, bytes: []const u8) Error!void {
    if (bytes.len > constants.limits.message_len_max) return error.LengthTooLarge;
    return files.decode.merge_depth(T, message, bytes, constants.limits.depth_max, .checked, {});
}

/// The bytes `encode` writes for `message`.
pub fn encoded_len(comptime T: type, message: *const T) EncodeError!usize {
    return files.encode.encoded_len(T, message);
}

/// Encodes `message` into `buffer` and returns the bytes written, from the buffer's start.
pub fn encode(comptime T: type, message: *const T, buffer: []u8) EncodeError![]u8 {
    var writer: files.wire.Writer = .{ .buffer = buffer };
    try files.encode.encode_into(T, message, &writer);
    return writer.written();
}

/// What `encode_json` fails with.
pub const JsonEncodeError = files.json_scalar.EncodeError;
/// What `decode_json` refuses a text with, or fails with for want of room.
pub const JsonDecodeError = files.json_scalar.DecodeError;

/// Writes `message` as one proto3 JSON text into `buffer`, and returns the text. An Any names
/// its type from the well-known types and the root file's `protobuf_any_types` (decision 21).
pub fn encode_json(comptime T: type, message: *const T, buffer: []u8) JsonEncodeError![]const u8 {
    return encode_json_registry(T, message, buffer, files.any.types);
}

/// `encode_json`, with an Any naming its type from the well-known types and `any_types`.
pub fn encode_json_with(comptime T: type, message: *const T, buffer: []u8, comptime any_types: []const type) JsonEncodeError![]const u8 {
    return encode_json_registry(T, message, buffer, files.any.with(any_types));
}

fn encode_json_registry(comptime T: type, message: *const T, buffer: []u8, comptime registry: []const type) JsonEncodeError![]const u8 {
    var text = json.TextWriter.init(buffer, .text, codec.Features.target());
    try files.json_encode.write_message(T, message, &text, registry);
    return text.written();
}

/// Reads the proto3 JSON text `text` as a `T` (decision 9). It writes the binary encoding into
/// `binary`, and the message's strings and bytes point into it. `tokens` holds one token's octets
/// at a time, so a string as long as the longest one in the text fits.
pub fn decode_json(comptime T: type, text: []const u8, binary: []u8, tokens: []u8) JsonDecodeError!T {
    return decode(T, try files.json_decode.transcode(T, text, binary, tokens, files.any.types));
}

/// `decode_json`, with an Any naming its type from the well-known types and `any_types`.
pub fn decode_json_with(comptime T: type, text: []const u8, binary: []u8, tokens: []u8, comptime any_types: []const type) JsonDecodeError!T {
    return decode(T, try files.json_decode.transcode(T, text, binary, tokens, files.any.with(any_types)));
}

/// The well-known types with their own JSON form (design §5).
pub const wkt = struct {
    pub const Timestamp = files.wkt.Timestamp;
    pub const Duration = files.wkt.Duration;
    pub const Empty = files.wkt.Empty;
    pub const FieldMask = files.wkt.FieldMask;
    pub const Any = files.wkt.Any;
    pub const DoubleValue = files.wkt.DoubleValue;
    pub const FloatValue = files.wkt.FloatValue;
    pub const Int64Value = files.wkt.Int64Value;
    pub const UInt64Value = files.wkt.UInt64Value;
    pub const Int32Value = files.wkt.Int32Value;
    pub const UInt32Value = files.wkt.UInt32Value;
    pub const BoolValue = files.wkt.BoolValue;
    pub const StringValue = files.wkt.StringValue;
    pub const BytesValue = files.wkt.BytesValue;
    pub const NullValue = files.wkt.NullValue;
    pub const Struct = files.wkt.Struct;
    pub const Value = files.wkt.Value;
    pub const ListValue = files.wkt.ListValue;
};

/// The value of the last entry of a map field whose key is `key` ("Maps": the last key wins).
pub const map_get = files.repeated.map_get;

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "constants",       "Kind",            "Field",       "Descriptor",       "EnumValue",   "EnumDescriptor",
        "View",            "Unknown",         "Repeated",    "Lazy",             "Error",       "EncodeError",
        "decode",          "decode_into",     "merge",       "encoded_len",      "encode",      "map_get",
        "JsonEncodeError", "JsonDecodeError", "encode_json", "encode_json_with", "decode_json", "decode_json_with",
        "wkt",             "FieldOptions",    "field_of",    "WireType",
    });
}

test {
    std.testing.refAllDecls(files);
    _ = @import("protobuf_test.zig");
    _ = @import("protobuf_json_test.zig");
    _ = @import("protobuf_json_wkt_test.zig");
    _ = @import("protobuf_group_test.zig");
    _ = @import("protobuf_unknown_test.zig");
    _ = @import("protobuf_closed_test.zig");
    _ = @import("protobuf_fast_path_test.zig");
    _ = @import("protobuf_fast_path_message_test.zig");
    _ = @import("protobuf_fast_path_flat_test.zig");
    _ = @import("protobuf_storage_test.zig");
    _ = @import("protobuf_fast_path_number_test.zig");
}
