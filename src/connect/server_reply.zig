//! What a server writes back, in the protocol its request spoke: the head, each message, and the
//! end of the response (Connect protocol, "Unary-Response" and "Streaming-Response";
//! PROTOCOL-HTTP2.md, "Responses"; PROTOCOL-WEB.md).
//!
//! - Connect unary: the message is the body, and an error is a JSON body with its HTTP status.
//! - Connect streams: envelopes, then an end-stream message flagged 0x02.
//! - gRPC: envelopes, then the status in HTTP trailers. An error before any message is sent
//!   "Trailers-Only": the status goes in the head and the body is empty.
//! - gRPC-Web: envelopes, then the status in a trailers frame flagged 0x80.
const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");
const compression = @import("compression.zig");
const envelope = @import("envelope.zig");
const error_json = @import("error_json.zig");
const end_stream = @import("end_stream.zig");
const trailers = @import("trailers.zig");
const message_codec = @import("message_codec.zig");
const rpc_error = @import("rpc_error.zig");
const server_head = @import("server_head.zig");
const constants = @import("constants.zig");
const Header = rpc_error.Header;
const RpcError = rpc_error.RpcError;

/// The most headers `head` and `error_head` return.
pub const head_headers_max = 4;

comptime {
    // A Trailers-Only head holds the content type and every status trailer.
    assert(head_headers_max >= 1 + trailers.trailers_max);
}

pub const Head = struct {
    status: u16,
    storage: [head_headers_max]Header = undefined,
    count: usize = 0,

    pub fn headers(head: *const Head) []const Header {
        return head.storage[0..head.count];
    }

    fn add(head: *Head, name: []const u8, value: []const u8) void {
        assert(head.count < head_headers_max);
        head.storage[head.count] = .{ .name = name, .value = value };
        head.count += 1;
    }
};

pub const Error = message_codec.EncodeError || error{ WriteFailed, TooManyDetails, InvalidTrailer };

pub const Prepared = message_codec.Prepared;
pub const Body = message_codec.Body;

pub const Reply = struct {
    accepted: server_head.Accepted,
    scratch: message_codec.Scratch,
    /// The encoders the reply compresses with, in the coding `accept` chose.
    encoders: compression.Encoders = .{},
    /// Whether a message went out, which rules out gRPC's Trailers-Only form.
    sent: bool = false,

    /// Encodes a message into the scratch storage, compressing it when the response coding is
    /// gzip and the message is long enough. An enveloped message leaves the octets of an envelope
    /// prefix free before it, in `scratch.message` and in `scratch.work`, where `envelope_of`
    /// writes the prefix.
    pub fn prepare(reply: *Reply, comptime T: type, message: *const T) Error!Prepared {
        const headroom: usize = if (reply.accepted.speaks.enveloped) constants.protocol.envelope_prefix_len else 0;
        const scratch = reply.scratch;
        if (scratch.message.len < headroom or scratch.work.len < headroom) return error.NoSpaceLeft;
        const room: message_codec.Scratch = .{ .message = scratch.message[headroom..], .work = scratch.work[headroom..], .tokens = scratch.tokens };
        return message_codec.prepare(T, reply.accepted.speaks.codec, reply.accepted.response_coding, reply.encoders, message, room);
    }

    /// The envelope of a message `prepare` encoded: the prefix, written into the octets `prepare`
    /// left free, and the message after it, as one slice of the scratch storage. A writer that
    /// takes one slice whole or not at all then never takes half an envelope. The slice lasts
    /// until the next `prepare`.
    pub fn envelope_of(reply: *const Reply, prepared: Prepared) []const u8 {
        assert(reply.accepted.speaks.enveloped);
        const prefix_len = constants.protocol.envelope_prefix_len;
        const buffer = if (prepared.compressed) reply.scratch.work else reply.scratch.message;
        assert(buffer.len >= prefix_len + prepared.octets.len);
        // `prepare` wrote the message right after the prefix's octets. An empty message points nowhere.
        assert(prepared.octets.len == 0 or prepared.octets.ptr == buffer.ptr + prefix_len);
        envelope.write_prefix(.{ .compressed = prepared.compressed }, prepared.octets.len, buffer[0..prefix_len]);
        return buffer[0 .. prefix_len + prepared.octets.len];
    }

    /// The head of a response that carries messages. `body` says whether a unary Connect body is
    /// compressed; a stream announces its coding whatever each message does.
    pub fn head(reply: *const Reply, body: message_codec.Body) Head {
        const speaks = reply.accepted.speaks;
        var result: Head = .{ .status = constants.protocol.status.ok };
        result.add("content-type", protocol.content_type(speaks));
        const coding = reply.accepted.response_coding;
        switch (speaks.protocol) {
            .connect => if (!speaks.enveloped) {
                if (body == .compressed) result.add("content-encoding", coding.name());
            } else if (coding != .identity) result.add("connect-content-encoding", coding.name()),
            .grpc, .grpc_web => if (coding != .identity) result.add("grpc-encoding", coding.name()),
        }
        return result;
    }

    /// Whether `write_direct` can write a message before the head is known to need no change: a
    /// Connect unary head names the body's coding, so its body is written direct only when the
    /// response is not compressed.
    pub fn writes_direct(reply: *const Reply) bool {
        return reply.accepted.speaks.enveloped or reply.accepted.response_coding == .identity;
    }

    /// Encodes a message straight into the free space of `body`'s buffer, after room for its
    /// envelope prefix, so it is not copied from scratch storage. gzip, when it shrinks the
    /// message, compresses into scratch storage and the shorter result is copied back. Returns
    /// false, with nothing written, when the buffer has no room; the caller then calls `prepare`
    /// and `write_message`, which write through the buffer in pieces.
    pub fn write_direct(reply: *Reply, comptime T: type, message: *const T, body: *std.Io.Writer) Error!bool {
        assert(reply.writes_direct());
        const prefix_len: usize = if (reply.accepted.speaks.enveloped) constants.protocol.envelope_prefix_len else 0;
        const room = body.unusedCapacitySlice();
        if (room.len <= prefix_len) return false;
        const encoded = message_codec.encode(T, reply.accepted.speaks.codec, message, room[prefix_len..]) catch |failure| switch (failure) {
            error.NoSpaceLeft => return false,
            else => |other| return other,
        };
        const result = reply.shrink(encoded);
        if (result.compressed) @memcpy(room[prefix_len..][0..result.octets.len], result.octets);
        if (prefix_len != 0) envelope.write_prefix(.{ .compressed = result.compressed }, result.octets.len, room[0..constants.protocol.envelope_prefix_len]);
        body.advance(prefix_len + result.octets.len);
        reply.sent = true;
        return true;
    }

    /// The octets to send for an encoded message: compressed into scratch storage when the
    /// response coding is gzip and that makes it shorter, else the octets as they are.
    fn shrink(reply: *const Reply, encoded: []const u8) Prepared {
        // An enveloped message is compressed one by one; a unary body only through `prepare`.
        if (!reply.accepted.speaks.enveloped) return .{ .octets = encoded, .compressed = false };
        return message_codec.compress(reply.accepted.response_coding, reply.encoders, encoded, reply.scratch.work);
    }

    /// Writes one message: the whole body of a Connect unary response, or one envelope. Either
    /// goes to `body` as one slice, in one write.
    pub fn write_message(reply: *Reply, prepared: Prepared, body: *std.Io.Writer) Error!void {
        try body.writeAll(if (reply.accepted.speaks.enveloped) reply.envelope_of(prepared) else prepared.octets);
        reply.sent = true;
    }

    /// Whether `failure` is answered with `error_head` and `write_error_body` alone: a Connect
    /// unary error, or a gRPC error before any message (Trailers-Only).
    pub fn error_only(reply: *const Reply) bool {
        const speaks = reply.accepted.speaks;
        if (speaks.protocol == .connect) return !speaks.enveloped;
        return speaks.protocol == .grpc and !reply.sent;
    }

    /// The head of an error answered by `error_only`. For gRPC it holds the status trailers,
    /// whose values are written into `storage`.
    pub fn error_head(reply: *const Reply, failure: *const RpcError, storage: []u8) Error!Head {
        assert(reply.error_only());
        const speaks = reply.accepted.speaks;
        if (speaks.protocol == .connect) {
            var result: Head = .{ .status = failure.code.http_status() };
            result.add("content-type", "application/json");
            return result;
        }
        var result: Head = .{ .status = constants.protocol.status.ok };
        result.add("content-type", protocol.content_type(speaks));
        // The status trailers go in the head's own storage, after the content type.
        const written = try trailers.write(failure.*, storage, result.storage[result.count..]);
        result.count += written.len;
        return result;
    }

    /// Writes a Connect unary error's JSON body. A gRPC Trailers-Only error has no body.
    pub fn write_error_body(reply: *const Reply, failure: RpcError, body: *std.Io.Writer) Error!void {
        if (reply.accepted.speaks.protocol != .connect) return;
        try body.writeAll(error_json.encode(&failure, reply.scratch.work) catch return error.NoSpaceLeft);
    }

    /// How a response that carried messages ends: the octets its body still takes, as one slice,
    /// and the trailers the HTTP library sends after them. Both point into the caller's storage.
    pub const Ending = struct {
        octets: []const u8 = "",
        trailers: []const Header = &.{},
    };

    /// Builds the end of a response that carried messages, and writes nothing. A Connect stream
    /// ends with an end-stream envelope and gRPC-Web with a trailers frame, each in the body;
    /// gRPC ends with trailers, whose values are in `storage`.
    pub fn ending(reply: *const Reply, failure: ?RpcError, metadata: []const Header, storage: []u8, out: []Header) Error!Ending {
        const speaks = reply.accepted.speaks;
        assert(speaks.enveloped);
        switch (speaks.protocol) {
            .connect => {
                const prefix_len = constants.protocol.envelope_prefix_len;
                if (storage.len < prefix_len) return error.NoSpaceLeft;
                const text = end_stream.encode(&.{ .failure = failure, .metadata = metadata }, storage[prefix_len..]) catch return error.NoSpaceLeft;
                assert(text.len == 0 or text.ptr == storage.ptr + prefix_len);
                envelope.write_prefix(.{ .end_stream = true }, text.len, storage[0..prefix_len]);
                return .{ .octets = storage[0 .. prefix_len + text.len] };
            },
            .grpc => return .{ .trailers = try trailers.write(failure, storage, out) },
            .grpc_web => {
                const half = storage.len / constants.storage_halves;
                const status = try trailers.write(failure, storage[0..half], out);
                // gRPC-Web carries the call's own trailers in the same frame as its status
                // (PROTOCOL-WEB.md, "Message framing").
                if (metadata.len > out.len - status.len) return error.NoSpaceLeft;
                @memcpy(out[status.len..][0..metadata.len], metadata);
                return .{ .octets = try trailers.write_web_frame(out[0 .. status.len + metadata.len], storage[half..]) };
            },
        }
    }

    /// Ends a response that carried messages: writes the octets `ending` builds into `body`, in
    /// one write, and returns the trailers the HTTP library sends.
    pub fn finish(reply: *const Reply, failure: ?RpcError, metadata: []const Header, body: *std.Io.Writer, storage: []u8, out: []Header) Error![]const Header {
        const end = try reply.ending(failure, metadata, storage, out);
        if (end.octets.len != 0) try body.writeAll(end.octets);
        return end.trailers;
    }
};

/// The reply that carries the error of a request `server_head.accept` refused, or null when the
/// refusal names no protocol: the server then answers `refusal.http_status` with no body.
pub fn refusal_reply(refusal: *const server_head.Refused, scratch: *const message_codec.Scratch) ?Reply {
    _ = refusal.failure orelse return null;
    const speaks = refusal.speaks.?;
    return .{
        .accepted = .{ .speaks = speaks, .request_coding = .identity, .response_coding = .identity, .timeout_ns = null },
        .scratch = scratch.*,
    };
}

const testing = std.testing;
const proto = @import("protobuf");

const Greeting = struct {
    text: []const u8 = "",
    pub const FieldNumber = enum(u29) { text = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Greeting", .fields = &.{
        proto.field_of(FieldNumber.text, .string, .{}),
    } };
};

const test_buffer_len = 256;
const TestBuffers = struct {
    message: [test_buffer_len]u8 = undefined,
    work: [test_buffer_len]u8 = undefined,
    tokens: [test_buffer_len]u8 = undefined,
};

fn reply_for(speaks: protocol.Speaks, buffers: *TestBuffers) Reply {
    return .{
        .accepted = .{ .speaks = speaks, .request_coding = .identity, .response_coding = .identity, .timeout_ns = null },
        .scratch = .{ .message = &buffers.message, .work = &buffers.work, .tokens = &buffers.tokens },
    };
}

test "a Connect unary reply is the bare message, and its error a JSON body with a status" {
    var buffers: TestBuffers = .{};
    var reply = reply_for(.{ .protocol = .connect, .codec = .json, .enveloped = false }, &buffers);
    var out: [64]u8 = undefined;
    var body: std.Io.Writer = .fixed(&out);
    const prepared = try reply.prepare(Greeting, &.{ .text = "hi" });
    try testing.expectEqualStrings("application/json", reply.head(prepared.body()).headers()[0].value);
    try reply.write_message(prepared, &body);
    try testing.expectEqualStrings("{\"text\":\"hi\"}", body.buffered());
    var storage: [64]u8 = undefined;
    const failure: RpcError = .{ .code = .not_found };
    try testing.expectEqual(@as(u16, 404), (try reply.error_head(&failure, &storage)).status);
}

test "a gRPC reply ends in status trailers, and an early error is Trailers-Only" {
    var buffers: TestBuffers = .{};
    var reply = reply_for(.{ .protocol = .grpc, .codec = .proto, .enveloped = true }, &buffers);
    try testing.expect(reply.error_only());
    var storage: [64]u8 = undefined;
    const early = try reply.error_head(&.{ .code = .unavailable, .message = "x" }, &storage);
    try testing.expectEqualStrings("grpc-status", early.headers()[1].name);
    try testing.expectEqualStrings("14", early.headers()[1].value);
    var out: [64]u8 = undefined;
    var body: std.Io.Writer = .fixed(&out);
    try reply.write_message(try reply.prepare(Greeting, &.{ .text = "a" }), &body);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 3, 0x0a, 1, 'a' }, body.buffered());
    try testing.expect(!reply.error_only());
    var trailer_out: [trailers.trailers_max]Header = undefined;
    const ending = try reply.finish(null, &.{}, &body, &storage, &trailer_out);
    try testing.expectEqualStrings("0", ending[0].value);
}

test "a Connect stream ends with an end-stream envelope, and gRPC-Web with a trailers frame" {
    var buffers: TestBuffers = .{};
    var storage: [128]u8 = undefined;
    var trailer_out: [trailers.trailers_max]Header = undefined;
    const connect_reply = reply_for(.{ .protocol = .connect, .codec = .proto, .enveloped = true }, &buffers);
    var out: [128]u8 = undefined;
    var body: std.Io.Writer = .fixed(&out);
    _ = try connect_reply.finish(.{ .code = .internal }, &.{}, &body, &storage, &trailer_out);
    try testing.expectEqual(@as(u8, 0x02), body.buffered()[0]);
    try testing.expectEqualStrings("{\"error\":{\"code\":\"internal\"}}", body.buffered()[5..]);
    const web_reply = reply_for(.{ .protocol = .grpc_web, .codec = .proto, .enveloped = true }, &buffers);
    var web_out: [128]u8 = undefined;
    var web_body: std.Io.Writer = .fixed(&web_out);
    const metadata = [_]Header{.{ .name = "x-turns", .value = "2" }};
    _ = try web_reply.finish(null, &metadata, &web_body, &storage, &trailer_out);
    try testing.expectEqual(@as(u8, 0x80), web_body.buffered()[0]);
    // The call's own trailers ride in the same frame as the status (PROTOCOL-WEB.md).
    try testing.expectEqualStrings("grpc-status: 0\r\nx-turns: 2\r\n", web_body.buffered()[5..]);
}

test "a refusal with a protocol becomes a reply, and one without has none" {
    var buffers: TestBuffers = .{};
    const scratch: message_codec.Scratch = .{ .message = &buffers.message, .work = &buffers.work, .tokens = &buffers.tokens };
    try testing.expectEqual(@as(?Reply, null), refusal_reply(&.{ .http_status = 415 }, &scratch));
    const refused: server_head.Refused = .{
        .http_status = 200,
        .failure = .{ .code = .unimplemented },
        .speaks = .{ .protocol = .grpc_web, .codec = .proto, .enveloped = true },
    };
    const reply = refusal_reply(&refused, &scratch).?;
    try testing.expect(!reply.error_only());
}

test "a message is encoded straight into the body, and scratch storage stays untouched" {
    var buffers: TestBuffers = .{};
    @memset(&buffers.message, 0xaa);
    var reply = reply_for(.{ .protocol = .grpc, .codec = .proto, .enveloped = true }, &buffers);
    var out: [64]u8 = undefined;
    var body: std.Io.Writer = .fixed(&out);
    try testing.expect(try reply.write_direct(Greeting, &.{ .text = "hi" }, &body));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 4, 0x0a, 2, 'h', 'i' }, body.buffered());
    try testing.expect(std.mem.allEqual(u8, &buffers.message, 0xaa));
    // A unary Connect body is the bare message.
    var unary = reply_for(.{ .protocol = .connect, .codec = .json, .enveloped = false }, &buffers);
    var unary_body: std.Io.Writer = .fixed(&out);
    try testing.expect(try unary.write_direct(Greeting, &.{ .text = "hi" }, &unary_body));
    try testing.expectEqualStrings("{\"text\":\"hi\"}", unary_body.buffered());
}

test "a body with no room for the message takes nothing, and the scratch path writes it" {
    var buffers: TestBuffers = .{};
    var reply = reply_for(.{ .protocol = .grpc, .codec = .proto, .enveloped = true }, &buffers);
    var out: [6]u8 = undefined;
    var body: std.Io.Writer = .fixed(&out);
    try testing.expect(!try reply.write_direct(Greeting, &.{ .text = "hi" }, &body));
    try testing.expectEqual(@as(usize, 0), body.buffered().len);
    try testing.expect(!reply.sent);
    // Less room than an envelope's prefix takes.
    var tiny: [3]u8 = undefined;
    var tiny_body: std.Io.Writer = .fixed(&tiny);
    try testing.expect(!try reply.write_direct(Greeting, &.{ .text = "hi" }, &tiny_body));
}

test "a long message is gzipped in its envelope, and a unary gzip reply is not written direct" {
    var buffers: [3][message_codec.compress_len_min * 2]u8 = undefined;
    var encoder: compression.GzipEncoder = undefined;
    var reply: Reply = .{
        .accepted = .{ .speaks = .{ .protocol = .grpc, .codec = .proto, .enveloped = true }, .request_coding = .identity, .response_coding = .gzip, .timeout_ns = null },
        .scratch = .{ .message = &buffers[0], .work = &buffers[1], .tokens = &buffers[2] },
        .encoders = .{ .gzip = &encoder },
    };
    const text = [_]u8{'a'} ** message_codec.compress_len_min;
    var out: [message_codec.compress_len_min * 2]u8 = undefined;
    var body: std.Io.Writer = .fixed(&out);
    try testing.expect(try reply.write_direct(Greeting, &.{ .text = &text }, &body));
    const written = body.buffered();
    try testing.expectEqual(@as(u8, 0x01), written[0]);
    try testing.expect(written.len < text.len);
    // The envelope holds the gzip of the message, which inflates back to it.
    var decoder: compression.GzipDecoder = undefined;
    var inflated: [message_codec.compress_len_min * 2]u8 = undefined;
    const octets = try compression.decompress(.gzip, .{ .gzip = &decoder }, written[constants.protocol.envelope_prefix_len..], &inflated);
    try testing.expectEqualStrings(&text, (try proto.decode(Greeting, octets)).text);
    reply.accepted.speaks = .{ .protocol = .connect, .codec = .proto, .enveloped = false };
    try testing.expect(!reply.writes_direct());
}

/// A writer with no buffer, which counts the slices it takes and takes at most `slices_max` of
/// them: a writer that takes one slice whole or not at all. Test-only.
const SliceWriter = struct {
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    octets: [test_buffer_len]u8 = undefined,
    len: usize = 0,
    slices: usize = 0,
    slices_max: usize,

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const sink: *SliceWriter = @alignCast(@fieldParentPtr("writer", writer));
        assert(data.len == 1 and splat == 1);
        if (sink.slices == sink.slices_max) return error.WriteFailed;
        @memcpy(sink.octets[sink.len..][0..data[0].len], data[0]);
        sink.len += data[0].len;
        sink.slices += 1;
        return data[0].len;
    }
};

test "an envelope from scratch storage goes out as one slice, whole or not at all" {
    var buffers: TestBuffers = .{};
    var reply = reply_for(.{ .protocol = .grpc, .codec = .proto, .enveloped = true }, &buffers);
    const prepared = try reply.prepare(Greeting, &.{ .text = "hi" });
    // A writer with no room takes nothing, and the reply has then sent no message.
    var full: SliceWriter = .{ .slices_max = 0 };
    try testing.expectError(error.WriteFailed, reply.write_message(prepared, &full.writer));
    try testing.expectEqual(@as(usize, 0), full.len);
    try testing.expect(!reply.sent);
    // The same envelope goes whole in a later write: its prefix and its message in one slice.
    var sink: SliceWriter = .{ .slices_max = 1 };
    try reply.write_message(prepared, &sink.writer);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 4, 0x0a, 2, 'h', 'i' }, sink.octets[0..sink.len]);
    try testing.expect(reply.sent);
}

test "an enveloped message leaves room for its prefix, and a unary one takes the whole storage" {
    var message: [16]u8 = undefined;
    var work: [16]u8 = undefined;
    var tokens: [16]u8 = undefined;
    var reply: Reply = .{
        .accepted = .{ .speaks = .{ .protocol = .grpc, .codec = .proto, .enveloped = true }, .request_coding = .identity, .response_coding = .identity, .timeout_ns = null },
        .scratch = .{ .message = &message, .work = &work, .tokens = &tokens },
    };
    // A tag, a length and nine octets fill the storage after the prefix.
    const fits = try reply.prepare(Greeting, &.{ .text = "123456789" });
    try testing.expectEqual(message.len, reply.envelope_of(fits).len);
    try testing.expectEqual(@as([*]const u8, &message), reply.envelope_of(fits).ptr);
    try testing.expectError(error.NoSpaceLeft, reply.prepare(Greeting, &.{ .text = "1234567890" }));
    reply.accepted.speaks = .{ .protocol = .connect, .codec = .proto, .enveloped = false };
    try testing.expectEqual(@as(usize, 12), (try reply.prepare(Greeting, &.{ .text = "1234567890" })).octets.len);
}

test "the end of a stream is built before it is written, and goes out as one slice" {
    var buffers: TestBuffers = .{};
    var storage: [128]u8 = undefined;
    var trailer_out: [trailers.trailers_max]Header = undefined;
    const connect_reply = reply_for(.{ .protocol = .connect, .codec = .proto, .enveloped = true }, &buffers);
    const end = try connect_reply.ending(.{ .code = .internal }, &.{}, &storage, &trailer_out);
    try testing.expectEqual(@as(usize, 0), end.trailers.len);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0, 0, 0, 29 }, end.octets[0..constants.protocol.envelope_prefix_len]);
    try testing.expectEqualStrings("{\"error\":{\"code\":\"internal\"}}", end.octets[constants.protocol.envelope_prefix_len..]);
    var sink: SliceWriter = .{ .slices_max = 1 };
    _ = try connect_reply.finish(.{ .code = .internal }, &.{}, &sink.writer, &storage, &trailer_out);
    try testing.expectEqualSlices(u8, end.octets, sink.octets[0..sink.len]);
    // gRPC ends in trailers alone, so its body takes no octets.
    const grpc_reply = reply_for(.{ .protocol = .grpc, .codec = .proto, .enveloped = true }, &buffers);
    const grpc_end = try grpc_reply.ending(null, &.{}, &storage, &trailer_out);
    try testing.expectEqual(@as(usize, 0), grpc_end.octets.len);
    try testing.expectEqualStrings("0", grpc_end.trailers[0].value);
    var none: SliceWriter = .{ .slices_max = 0 };
    _ = try grpc_reply.finish(null, &.{}, &none.writer, &storage, &trailer_out);
}
