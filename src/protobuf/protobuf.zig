//! protobuf: the binary encoding and the proto3 JSON mapping of protocol buffers, over structs
//! that `protoc-gen-connect-zig` generates, with no allocator and no I/O (docs/design.md §4).
//!
//! A generated message is a struct whose `pub const protobuf: Descriptor` names its fields. The
//! generic `encode`, `encoded_len` and `Decoder.decode` read that table at comptime. A program
//! makes one `Decoder` and one `Encoder` as it starts, with the CPU features it detected once.
//! `Decoder.decode` copies nothing: strings, bytes and repeated fields point into the input,
//! which must outlive the message. `Decoder.decode_into` reads each repeated field into storage
//! the caller passes, for a program that reads every field (decision 37). The caller owns every
//! buffer.
const std = @import("std");
const json = @import("stdx").encoding.json;
const platform = @import("stdx").platform;

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
    pub const json_base64 = @import("json_base64.zig");
    pub const json_float = @import("json_float.zig");
    pub const json_encode = @import("json_encode.zig");
    pub const json_decode = @import("json_decode.zig");
    pub const json_decode_wkt = @import("json_decode_wkt.zig");
    pub const any = @import("any.zig");
    pub const time_text = @import("time_text.zig");
    pub const wkt = @import("wkt.zig");
    pub const decoder = @import("decoder.zig");
    pub const encoder = @import("encoder.zig");
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

/// Decodes binary and JSON with the program's CPU features, which it takes once, at `init`.
pub const Decoder = files.decoder.Decoder;
/// Writes JSON with the program's CPU features, which it takes once, at `init`.
pub const Encoder = files.encoder.Encoder;
/// What a `Decoder.decode_into_use` took of its storage (decision 37).
pub const StorageUse = files.decoder.StorageUse;

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
        "constants",       "Kind",            "Field",      "Descriptor",   "EnumValue", "EnumDescriptor",
        "View",            "Unknown",         "Repeated",   "Lazy",         "Error",     "EncodeError",
        "Decoder",         "Encoder",         "StorageUse", "encoded_len",  "encode",    "map_get",
        "JsonEncodeError", "JsonDecodeError", "wkt",        "FieldOptions", "field_of",  "WireType",
    });
}

test {
    std.testing.refAllDecls(files);
    _ = @import("protobuf_test.zig");
    _ = @import("protobuf_json_test.zig");
    _ = @import("protobuf_json_map_test.zig");
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
