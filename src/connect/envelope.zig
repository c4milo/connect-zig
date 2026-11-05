//! The 5-octet prefix of a streamed message, and a reader over the envelopes of a whole body.
//! Connect's streaming protocols, gRPC and gRPC-Web share it (Connect protocol,
//! "Streaming-Request"; gRPC PROTOCOL-HTTP2.md, "Length-Prefixed-Message"; PROTOCOL-WEB.md).
//! The length is a 4-octet unsigned integer, most significant octet first.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const flag = constants.protocol;

pub const Flags = packed struct(u8) {
    compressed: bool = false,
    end_stream: bool = false,
    reserved: u5 = 0,
    trailers: bool = false,

    comptime {
        assert(@as(u8, @bitCast(Flags{ .compressed = true })) == flag.flag_compressed);
        assert(@as(u8, @bitCast(Flags{ .end_stream = true })) == flag.flag_end_stream);
        assert(@as(u8, @bitCast(Flags{ .trailers = true })) == flag.flag_trailers);
    }
};

pub const Envelope = struct {
    flags: Flags,
    payload: []const u8,
};

pub const Error = error{
    /// The body ended inside a prefix or a payload.
    Truncated,
    /// A payload longer than the reader's limit (Connect's resource_exhausted, gRPC's
    /// RESOURCE_EXHAUSTED).
    MessageTooLarge,
    /// Flags this protocol does not define.
    InvalidFlags,
};

/// Writes the prefix of a payload of `payload_len` octets into `prefix`.
pub fn write_prefix(flags: Flags, payload_len: usize, prefix: *[flag.envelope_prefix_len]u8) void {
    assert(payload_len <= std.math.maxInt(u32));
    prefix[0] = @bitCast(flags);
    std.mem.writeInt(u32, prefix[1..flag.envelope_prefix_len], @intCast(payload_len), .big);
}

/// Writes one envelope, prefix and payload, into `buffer`, and returns its octets.
pub fn write(flags: Flags, payload: []const u8, buffer: []u8) error{NoSpaceLeft}![]u8 {
    const len = flag.envelope_prefix_len + payload.len;
    if (len > buffer.len) return error.NoSpaceLeft;
    write_prefix(flags, payload.len, buffer[0..flag.envelope_prefix_len]);
    @memcpy(buffer[flag.envelope_prefix_len..len], payload);
    return buffer[0..len];
}

/// Reads the envelopes of a whole body, one a call.
pub const Reader = struct {
    body: []const u8,
    position: usize = 0,
    /// The longest payload the reader accepts.
    payload_len_max: usize,

    pub fn at_end(reader: *const Reader) bool {
        return reader.position == reader.body.len;
    }

    pub fn next(reader: *Reader) Error!?Envelope {
        assert(reader.position <= reader.body.len);
        if (reader.at_end()) return null;
        const rest = reader.body[reader.position..];
        if (rest.len < flag.envelope_prefix_len) return error.Truncated;
        const flags: Flags = @bitCast(rest[0]);
        // Connect protocol, "Streaming-Request": bits other than those defined must be zero.
        if (flags.reserved != 0) return error.InvalidFlags;
        const payload_len = std.mem.readInt(u32, rest[1..flag.envelope_prefix_len], .big);
        if (payload_len > reader.payload_len_max) return error.MessageTooLarge;
        if (payload_len > rest.len - flag.envelope_prefix_len) return error.Truncated;
        reader.position += flag.envelope_prefix_len + payload_len;
        return .{ .flags = flags, .payload = rest[flag.envelope_prefix_len..][0..payload_len] };
    }
};

const testing = std.testing;

test "an envelope is a flags octet and a big-endian length before its payload" {
    var buffer: [16]u8 = undefined;
    const written = try write(.{ .end_stream = true }, "hi", &buffer);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0, 0, 0, 2, 'h', 'i' }, written);
    var reader: Reader = .{ .body = written, .payload_len_max = 16 };
    const envelope = (try reader.next()).?;
    try testing.expect(envelope.flags.end_stream and !envelope.flags.compressed);
    try testing.expectEqualStrings("hi", envelope.payload);
    try testing.expectEqual(@as(?Envelope, null), try reader.next());
}

test "a reader refuses a short body, a payload past its limit, and undefined flags" {
    var short: Reader = .{ .body = &.{ 0, 0, 0, 0, 3, 'a' }, .payload_len_max = 16 };
    try testing.expectError(error.Truncated, short.next());
    var large: Reader = .{ .body = &.{ 0, 0, 0, 1, 0 }, .payload_len_max = 255 };
    try testing.expectError(error.MessageTooLarge, large.next());
    var flagged: Reader = .{ .body = &.{ 0x04, 0, 0, 0, 0 }, .payload_len_max = 16 };
    try testing.expectError(error.InvalidFlags, flagged.next());
    var trailers: Reader = .{ .body = &.{ 0x80, 0, 0, 0, 0 }, .payload_len_max = 16 };
    try testing.expect((try trailers.next()).?.flags.trailers);
}
