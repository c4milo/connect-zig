//! A message's octets in either codec, and the compression of a message as a protocol sends it.
const std = @import("std");
const proto = @import("protobuf");
const protocol = @import("protocol.zig");
const compression = @import("compression.zig");
const Codec = protocol.Codec;

/// The storage one message takes while it is encoded or decoded. Each area is the caller's.
pub const Scratch = struct {
    /// A message's encoded octets, or a decompressed message.
    message: []u8,
    /// A compressed message, or the binary form of a JSON message.
    work: []u8,
    /// One JSON token's octets.
    tokens: []u8,
};

pub const EncodeError = proto.EncodeError || proto.JsonEncodeError;
pub const DecodeError = proto.Error || proto.JsonDecodeError;

pub fn encode(comptime T: type, codec: Codec, message: *const T, buffer: []u8) EncodeError![]const u8 {
    return switch (codec) {
        .proto => proto.encode(T, message, buffer),
        .json => proto.encode_json(T, message, buffer),
    };
}

/// Decodes `octets`. A JSON message's strings point into `scratch.work`, a binary one's into
/// `octets`.
pub fn decode(comptime T: type, codec: Codec, octets: []const u8, scratch: Scratch) DecodeError!T {
    return switch (codec) {
        .proto => proto.decode(T, octets),
        .json => proto.decode_json(T, octets, scratch.work, scratch.tokens),
    };
}

/// The smallest message a sender compresses. Below it, gzip's header and trailer outweigh what
/// compression saves.
pub const compress_len_min = 1024;

/// Compresses `octets` into `buffer` when `coding` is gzip and the message is long enough, and
/// says whether it did.
pub fn compress(coding: compression.Coding, encoder: ?*compression.GzipEncoder, octets: []const u8, buffer: []u8) struct { octets: []const u8, compressed: bool } {
    if (coding != .gzip or octets.len < compress_len_min) return .{ .octets = octets, .compressed = false };
    const gzip_encoder = encoder orelse return .{ .octets = octets, .compressed = false };
    const packed_octets = compression.compress_gzip(gzip_encoder, octets, buffer) catch return .{ .octets = octets, .compressed = false };
    return .{ .octets = packed_octets, .compressed = true };
}
