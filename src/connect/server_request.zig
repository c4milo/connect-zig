//! The messages of a request's body, decompressed and decoded one at a time (Connect protocol,
//! "Unary-Request" and "Streaming-Request"; PROTOCOL-HTTP2.md, "Requests").
//!
//! A Connect unary body is the message itself, and a GET carries it in the query. Every other
//! body is envelopes. A request's envelope may not carry the end-stream or trailers flag.
const std = @import("std");
const assert = std.debug.assert;
const compression = @import("compression.zig");
const envelope = @import("envelope.zig");
const get = @import("get.zig");
const message_codec = @import("message_codec.zig");
const server_head = @import("server_head.zig");
const rpc_error = @import("rpc_error.zig");
const Code = @import("code.zig").Code;
const RpcError = rpc_error.RpcError;

pub const Error = message_codec.DecodeError || compression.Error || envelope.Error || get.Error || error{
    /// A request envelope flagged end-stream or trailers, or compressed with no coding named.
    InvalidEnvelope,
};

pub const Messages = struct {
    accepted: server_head.Accepted,
    body: []const u8,
    scratch: message_codec.Scratch,
    decoders: compression.Decoders,
    reader: envelope.Reader,
    /// Whether the one message of a unary Connect body was read.
    unary_read: bool = false,

    pub fn init(accepted: server_head.Accepted, body: []const u8, scratch: message_codec.Scratch, decoders: compression.Decoders) Messages {
        return .{
            .accepted = accepted,
            .body = body,
            .scratch = scratch,
            .decoders = decoders,
            .reader = .{ .body = body, .payload_len_max = scratch.message.len },
        };
    }

    /// The next message, or null after the last. Its strings point into the body or the scratch
    /// storage, which the next call overwrites.
    pub fn next(messages: *Messages, comptime T: type) Error!?T {
        const octets = try messages.next_octets() orelse return null;
        return try message_codec.decode(T, messages.accepted.speaks.codec, octets, messages.scratch);
    }

    fn next_octets(messages: *Messages) Error!?[]const u8 {
        if (messages.accepted.speaks.enveloped) return messages.next_envelope();
        if (messages.unary_read) return null;
        messages.unary_read = true;
        const coding = messages.accepted.request_coding;
        if (messages.accepted.query) |query| {
            const encoded = try get.message_octets(query, messages.scratch.work);
            return try compression.decompress(coding, messages.decoders, encoded, messages.scratch.message);
        }
        return try compression.decompress(coding, messages.decoders, messages.body, messages.scratch.message);
    }

    fn next_envelope(messages: *Messages) Error!?[]const u8 {
        const next_one = try messages.reader.next() orelse return null;
        // Connect protocol, "Streaming-Request": a client never sends the end-stream flag, and
        // gRPC-Web's trailers flag is the server's alone.
        if (next_one.flags.end_stream or next_one.flags.trailers) return error.InvalidEnvelope;
        if (!next_one.flags.compressed) return next_one.payload;
        // PROTOCOL-HTTP2.md, "Message-Encoding": a compressed message with no grpc-encoding is
        // an error.
        if (messages.accepted.request_coding == .identity) return error.InvalidEnvelope;
        return try compression.decompress(messages.accepted.request_coding, messages.decoders, next_one.payload, messages.scratch.message);
    }
};

/// The error a server answers a request whose body it could not read with.
pub fn failure_of(failure: Error) RpcError {
    return switch (failure) {
        // A message, or one of its JSON tokens, larger than the server's buffers is a limit the
        // server set, not a fault of the message (statuscodes.md, RESOURCE_EXHAUSTED).
        error.MessageTooLarge, error.NoSpaceLeft => .{ .code = .resource_exhausted, .message = "message larger than the server reads" },
        error.UnsupportedCoding => .{ .code = .internal, .message = "unsupported compression" },
        error.InvalidEnvelope, error.InvalidFlags, error.Truncated => .{ .code = .invalid_argument, .message = "malformed envelope" },
        else => .{ .code = .invalid_argument, .message = "malformed message" },
    };
}

const testing = std.testing;
const proto = @import("protobuf");

const Note = struct {
    text: []const u8 = "",
    pub const FieldNumber = enum(u29) { text = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Note", .fields = &.{
        proto.field_of(FieldNumber.text, .string, .{}),
    } };
};

fn accepted_for(protocol: @import("protocol.zig").Protocol, enveloped: bool) server_head.Accepted {
    return .{ .speaks = .{ .protocol = protocol, .codec = .proto, .enveloped = enveloped }, .request_coding = .identity, .response_coding = .identity, .timeout_ns = null };
}

test "a unary body is one message, and envelopes are read in order" {
    var buffers: [3][64]u8 = undefined;
    const scratch: message_codec.Scratch = .{ .message = &buffers[0], .work = &buffers[1], .tokens = &buffers[2] };
    var unary = Messages.init(accepted_for(.connect, false), &.{ 0x0a, 1, 'a' }, scratch, .{});
    try testing.expectEqualStrings("a", (try unary.next(Note)).?.text);
    try testing.expectEqual(@as(?Note, null), try unary.next(Note));
    const body = [_]u8{ 0, 0, 0, 0, 3, 0x0a, 1, 'b', 0, 0, 0, 0, 0 };
    var stream = Messages.init(accepted_for(.grpc, true), &body, scratch, .{});
    try testing.expectEqualStrings("b", (try stream.next(Note)).?.text);
    try testing.expectEqualStrings("", (try stream.next(Note)).?.text);
    try testing.expectEqual(@as(?Note, null), try stream.next(Note));
}

test "a JSON token larger than the server's token buffer is resource_exhausted, not malformed" {
    var buffers: [2][64]u8 = undefined;
    var tokens: [4]u8 = undefined;
    const scratch: message_codec.Scratch = .{ .message = &buffers[0], .work = &buffers[1], .tokens = &tokens };
    const accepted: server_head.Accepted = .{ .speaks = .{ .protocol = .connect, .codec = .json, .enveloped = false }, .request_coding = .identity, .response_coding = .identity, .timeout_ns = null };
    var messages = Messages.init(accepted, "{\"text\":\"a long sentence\"}", scratch, .{});
    if (messages.next(Note)) |_| return error.TestExpectedError else |failure| {
        try testing.expectEqual(Code.resource_exhausted, failure_of(failure).code);
    }
}

test "a request envelope flagged end-stream, or compressed with no coding, is refused" {
    var buffers: [3][64]u8 = undefined;
    const scratch: message_codec.Scratch = .{ .message = &buffers[0], .work = &buffers[1], .tokens = &buffers[2] };
    var ended = Messages.init(accepted_for(.connect, true), &.{ 0x02, 0, 0, 0, 0 }, scratch, .{});
    try testing.expectError(error.InvalidEnvelope, ended.next(Note));
    var compressed = Messages.init(accepted_for(.grpc, true), &.{ 0x01, 0, 0, 0, 0 }, scratch, .{});
    try testing.expectError(error.InvalidEnvelope, compressed.next(Note));
    var large = Messages.init(accepted_for(.grpc, true), &.{ 0, 0, 0, 1, 0 }, scratch, .{});
    if (large.next(Note)) |_| return error.TestExpectedError else |failure| {
        try testing.expectEqual(Code.resource_exhausted, failure_of(failure).code);
    }
}
