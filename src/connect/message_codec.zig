//! A message's octets in either codec, and the compression of a message as a protocol sends it.
const std = @import("std");
const assert = std.debug.assert;
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

/// The octets an envelope's payload holds: as they are, or inflated with `coding`.
pub fn open(compressed: bool, coding: compression.Coding, decoders: compression.Decoders, payload: []const u8, output: []u8) (compression.Error || error{CompressedWithoutCoding})![]const u8 {
    if (!compressed) return payload;
    // PROTOCOL-HTTP2.md, "Message-Encoding", and the Connect protocol, "Streaming-Request": a
    // message flagged compressed with no encoding named is an `internal` error.
    if (coding == .identity) return error.CompressedWithoutCoding;
    return compression.decompress(coding, decoders, payload, output);
}

/// The smallest reply message a server compresses. Below it, gzip's header and trailer outweigh
/// what compression saves. A client compresses from `client.Options.compress_len_min` on.
pub const compress_len_min = 1024;

/// A message encoded, and compressed when that saves octets, ready for an envelope or a body.
pub const Prepared = struct {
    octets: []const u8,
    compressed: bool,

    /// Whether the octets went out compressed, as `Reply.head` takes it.
    pub fn body(prepared: Prepared) Body {
        return if (prepared.compressed) .compressed else .plain;
    }
};

/// Whether a response body is compressed in the reply's coding, or plain.
pub const Body = enum { plain, compressed };

/// Encodes `message` into `scratch.message`, then compresses it into `scratch.work` as `compress`
/// decides.
pub fn prepare(comptime T: type, codec: Codec, coding: compression.Coding, encoders: compression.Encoders, message: *const T, scratch: Scratch) EncodeError!Prepared {
    const octets = try encode(T, codec, message, scratch.message);
    return compress(coding, encoders, octets, scratch.work);
}

/// Compresses a reply's `octets` into `buffer` when `encoders` writes `coding`, the message is
/// long enough, and the coding makes it shorter, and says whether it did.
pub fn compress(coding: compression.Coding, encoders: compression.Encoders, octets: []const u8, buffer: []u8) Prepared {
    if (coding == .identity or octets.len < compress_len_min) return .{ .octets = octets, .compressed = false };
    if (!encoders.writes(coding)) return .{ .octets = octets, .compressed = false };
    const packed_octets = compression.compress(coding, encoders, octets, buffer) catch return .{ .octets = octets, .compressed = false };
    // A message the coding cannot shrink goes out as it is: the peer would pay to inflate it for nothing.
    if (packed_octets.len >= octets.len) return .{ .octets = octets, .compressed = false };
    return .{ .octets = packed_octets, .compressed = true };
}

/// Compresses a request's `octets` into `buffer` in the coding the client asked for, when the
/// message holds `len_min` octets or more, whether or not the coding shrinks it: the request's
/// head names the coding its message is in, as connect-go sends it (decision 22). A shorter
/// message goes as it is. `encoders` must write `coding`.
pub fn compress_request(coding: compression.Coding, encoders: compression.Encoders, octets: []const u8, buffer: []u8, len_min: usize) error{NoSpaceLeft}!Prepared {
    assert(encoders.writes(coding));
    if (coding == .identity or octets.len < len_min) return .{ .octets = octets, .compressed = false };
    return .{ .octets = try compression.compress(coding, encoders, octets, buffer), .compressed = true };
}

const testing = std.testing;

test "gzip is used only when it shrinks the message" {
    var encoder: compression.GzipEncoder = undefined;
    var buffer: [compress_len_min * 2]u8 = undefined;
    const repetitive = [_]u8{'a'} ** (compress_len_min + 1);
    try testing.expect(compress(.gzip, .{ .gzip = &encoder }, &repetitive, &buffer).compressed);
    // Hash output has no redundancy gzip can find, so its stored form is longer than the input.
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var noise: [compress_len_min]u8 = undefined;
    var block: [Sha256.digest_length]u8 = @splat(0);
    for (0..compress_len_min / block.len) |index| {
        Sha256.hash(&block, &block, .{});
        @memcpy(noise[index * block.len ..][0..block.len], &block);
    }
    const kept = compress(.gzip, .{ .gzip = &encoder }, &noise, &buffer);
    try testing.expect(!kept.compressed);
    try testing.expectEqual(@as(usize, compress_len_min), kept.octets.len);
}

test "a request is compressed from its floor on, even when the coding cannot shrink it" {
    var encoder: compression.GzipEncoder = undefined;
    var buffer: [compress_len_min]u8 = undefined;
    const encoders: compression.Encoders = .{ .gzip = &encoder };
    // gzip's header and trailer make a two-octet message longer, and it goes compressed all the same.
    const tiny = try compress_request(.gzip, encoders, "hi", &buffer, 0);
    try testing.expect(tiny.compressed);
    try testing.expect(tiny.octets.len > "hi".len);
    try testing.expect((try compress_request(.gzip, encoders, "hi", &buffer, "hi".len)).compressed);
    const below = try compress_request(.gzip, encoders, "hi", &buffer, "hi".len + 1);
    try testing.expect(!below.compressed);
    try testing.expectEqualStrings("hi", below.octets);
    try testing.expect(!(try compress_request(.identity, encoders, "hi", &buffer, 0)).compressed);
    try testing.expectError(error.NoSpaceLeft, compress_request(.gzip, encoders, "hi", buffer[0..1], 0));
}
