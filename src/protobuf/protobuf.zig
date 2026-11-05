//! protobuf: the binary encoding and the proto3 JSON mapping of protocol buffers, over structs
//! that `protoc-gen-connect-zig` generates, with no allocator and no I/O (docs/design.md §4).
//!
//! A generated message is a struct whose `pub const protobuf: Descriptor` names its fields. The
//! generic `encode`, `decode` and `encoded_len` read that table at comptime. `decode` copies
//! nothing: strings, bytes and repeated fields point into the input, which must outlive the
//! message. The caller owns every buffer.
const std = @import("std");

pub const constants = @import("constants.zig");

const files = struct {
    pub const wire = @import("wire.zig");
    pub const descriptor = @import("descriptor.zig");
    pub const scalar = @import("scalar.zig");
    pub const repeated = @import("repeated.zig");
    pub const decode = @import("decode.zig");
    pub const encode = @import("encode.zig");
};

/// A field's type in the .proto file.
pub const Kind = files.descriptor.Kind;
pub const Field = files.descriptor.Field;
pub const Descriptor = files.descriptor.Descriptor;
pub const EnumValue = files.descriptor.EnumValue;
pub const EnumDescriptor = files.descriptor.EnumDescriptor;
/// Where a decoded repeated field's elements lie.
pub const View = files.descriptor.View;
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
    return files.decode.decode_depth(T, bytes, constants.limits.depth_max);
}

/// Merges `bytes` into `message`, as a later occurrence of the same message merges ("Last One
/// Wins", encoding guide).
pub fn merge(comptime T: type, message: *T, bytes: []const u8) Error!void {
    if (bytes.len > constants.limits.message_len_max) return error.LengthTooLarge;
    return files.decode.merge_depth(T, message, bytes, constants.limits.depth_max);
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

/// The value of the last entry of a map field whose key is `key` ("Maps": the last key wins).
pub const map_get = files.repeated.map_get;

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "constants", "Kind",        "Field",  "Descriptor", "EnumValue",   "EnumDescriptor",
        "View",      "Repeated",    "Lazy",   "Error",      "EncodeError", "decode",
        "merge",     "encoded_len", "encode", "map_get",
    });
}

test {
    std.testing.refAllDecls(files);
    _ = @import("protobuf_test.zig");
}
