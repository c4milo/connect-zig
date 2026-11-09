//! A client's reading of a response: its messages, then its outcome, in the protocol the call
//! spoke (Connect protocol, "Unary-Response", "Streaming-Response" and "HTTP to Error Code";
//! PROTOCOL-HTTP2.md, "Responses"; PROTOCOL-WEB.md).
//!
//! gRPC carries its status in HTTP trailers, which the caller passes in `Incoming.trailers`. With
//! none, a gRPC response is readable only when the server answered Trailers-Only (decision 11).
const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");
const compression = @import("compression.zig");
const envelope = @import("envelope.zig");
const error_json = @import("error_json.zig");
const end_stream = @import("end_stream.zig");
const trailers = @import("trailers.zig");
const message_codec = @import("message_codec.zig");
const server_head = @import("server_head.zig");
const rpc_error = @import("rpc_error.zig");
const Code = @import("code.zig").Code;
const constants = @import("constants.zig");
const Header = rpc_error.Header;
const RpcError = rpc_error.RpcError;
const Lookup = server_head.Lookup;

pub const Incoming = struct {
    status: u16,
    headers: Lookup,
    body: []const u8,
    /// The HTTP trailers, when the HTTP library exposes them.
    trailers: ?Lookup = null,
    /// The body arrives in pieces, which `Response.feed` passes on, and `body` is empty.
    streamed: bool = false,
};

pub const Storage = struct {
    scratch: message_codec.Scratch,
    /// The error's message and details, and the end-stream metadata.
    octets: []u8,
    details: []rpc_error.Detail,
    metadata: []Header,
};

pub const Error = message_codec.DecodeError || compression.Error || envelope.Error || error{
    /// An envelope the protocol does not allow where it stands, or a message after the end.
    InvalidEnvelope,
    /// An envelope flagged compressed while the response names no coding.
    CompressedWithoutCoding,
};

pub const Response = struct {
    /// Starts reading the response of a call that spoke `speaks`.
    pub fn init(speaks: protocol.Speaks, incoming: *const Incoming, storage: *const Storage, decoders: *const compression.Decoders) Response {
        var response: Response = .{
            .speaks = speaks,
            .incoming = incoming.*,
            .storage = storage.*,
            .decoders = decoders.*,
            .coding = .identity,
            .reader = .{ .body = incoming.body, .payload_len_max = storage.scratch.message.len },
            .streaming = incoming.streamed,
        };
        // Only an enveloped stream arrives in pieces: a bare message is the whole body.
        assert(!incoming.streamed or (speaks.enveloped and incoming.body.len == 0));
        if (incoming.status != constants.protocol.status.ok) {
            response.done = true;
            response.failure = http_failure(speaks, incoming.*, storage.*, decoders.*);
            return response;
        }
        response.body_seen = incoming.body.len > 0;
        if (head_failure(speaks, incoming)) |failure| {
            response.done = true;
            response.failure = failure;
            return response;
        }
        const coding_name = coding_header(speaks);
        if (incoming.headers.find(coding_name)) |name| {
            response.coding = compression.Coding.from_name(name) orelse {
                response.done = true;
                response.failure = .{ .code = .internal, .message = "unknown response compression" };
                return response;
            };
        }
        // PROTOCOL-HTTP2.md, "Responses": Trailers-Only puts the status in the head, and holds
        // no body and no trailers. The head's status of a response with either is ignored. A
        // streamed body may still come, so its head's status waits for the body's end.
        if (speaks.protocol != .connect and incoming.headers.find("grpc-status") != null) {
            response.head_status = true;
            if (!incoming.streamed and response.trailers_only()) response.read_head_status();
        }
        return response;
    }

    /// Whether the response is Trailers-Only, once its body ended: its head named a status, and
    /// neither a body nor trailers with a status followed (PROTOCOL-HTTP2.md, "Responses").
    fn trailers_only(response: *const Response) bool {
        if (!response.head_status or response.body_seen) return false;
        const lookup = response.incoming.trailers orelse return true;
        return lookup.find("grpc-status") == null;
    }

    fn read_head_status(response: *Response) void {
        response.done = true;
        response.failure = trailers.read(response.incoming.headers, find_lookup, status_storage(response.storage));
    }

    speaks: protocol.Speaks,
    incoming: Incoming,
    storage: Storage,
    decoders: compression.Decoders,
    coding: compression.Coding,
    reader: envelope.Reader,
    /// The outcome, once it is known: null while messages may follow, and after a success.
    failure: ?RpcError = null,
    metadata: []const Header = &.{},
    done: bool = false,
    /// More of a streamed body may follow what `feed` gave, so `next` returns null between pieces
    /// with `done` still false.
    streaming: bool = false,
    /// The head named a gRPC status, which counts only for a Trailers-Only response, and some of
    /// the body arrived.
    head_status: bool = false,
    body_seen: bool = false,
    /// The messages `next` returned.
    messages_read: u64 = 0,

    /// Gives a streamed response the octets of its body that `next` has not read, from the first
    /// one it has not read: the envelopes left, and the start of one that a later piece ends.
    /// Returns the octets of whole envelopes, which `next` reads. The caller keeps the rest and
    /// passes it again, with the next piece after it.
    pub fn feed(response: *Response, body: []const u8) Error!usize {
        assert(response.streaming or response.done);
        if (response.done) return body.len;
        if (body.len > 0) response.body_seen = true;
        const payload_len_max = response.reader.payload_len_max;
        var reader: envelope.Reader = .{ .body = body, .payload_len_max = payload_len_max };
        // Each envelope takes at least its prefix, so the loop ends.
        const whole_len = for (0..body.len / flag_prefix_len + 1) |_| {
            const next_one = reader.next() catch |failure| switch (failure) {
                // Connect protocol, "Streaming-Response", and PROTOCOL-HTTP2.md,
                // "Length-Prefixed-Message": an envelope may end in a later piece.
                error.Truncated => break reader.position,
                else => |other| return other,
            };
            if (next_one == null) break reader.position;
        } else unreachable;
        response.reader = .{ .body = body[0..whole_len], .payload_len_max = payload_len_max };
        return whole_len;
    }

    /// A streamed body ended. `rest` is what `feed` left of it, the start of an envelope or
    /// nothing; `next` then reads the outcome.
    pub fn end_body(response: *Response, rest: []const u8) void {
        assert(response.streaming or response.done);
        response.streaming = false;
        if (response.done or rest.len == 0) return;
        // Connect protocol, "Streaming-Response", and PROTOCOL-HTTP2.md,
        // "Length-Prefixed-Message": a body ends between envelopes.
        response.done = true;
        response.failure = .{ .code = .internal, .message = "truncated message" };
    }

    /// The next message, or null once the response holds no more. `failure` is then set when
    /// the call failed.
    pub fn next(response: *Response, comptime T: type) Error!?T {
        const octets = (if (response.done) null else try response.next_octets()) orelse {
            response.check_none();
            return null;
        };
        if (response.single() and response.messages_read == 1) {
            // statuscodes.md: "Response cardinality violation (method requires exactly one
            // response but server sent some other number of responses)" is UNIMPLEMENTED, at
            // the client. connect-go reads a unary or client-stream response the same way.
            response.done = true;
            response.failure = .{ .code = .unimplemented, .message = "unary response has multiple messages" };
            return null;
        }
        response.messages_read += 1;
        return try message_codec.decode(T, response.speaks.codec, octets, response.storage.scratch);
    }

    /// Whether the method answers with exactly one message: a unary call or a client stream.
    fn single(response: *const Response) bool {
        const stream_type = response.speaks.stream_type orelse return false;
        return stream_type == .unary or stream_type == .client_stream;
    }

    /// Fails a response that ended in success with no message, where its method answers with
    /// one (statuscodes.md, UNIMPLEMENTED: a response cardinality violation). A response that
    /// ended in an error keeps it, as connect-go reads it.
    fn check_none(response: *Response) void {
        if (!response.done or response.failure != null) return;
        if (!response.single() or response.messages_read != 0) return;
        response.failure = .{ .code = .unimplemented, .message = "unary response has zero messages" };
    }

    fn next_octets(response: *Response) Error!?[]const u8 {
        if (!response.speaks.enveloped) {
            response.done = true;
            // The bare message of a Connect unary response is bounded as an envelope's payload
            // is, whether it arrived compressed or not.
            if (response.coding == .identity and response.incoming.body.len > response.storage.scratch.message.len) return error.MessageTooLarge;
            return try compression.decompress(response.coding, response.decoders, response.incoming.body, response.storage.scratch.message);
        }
        const next_one = try response.reader.next() orelse {
            // A streamed body waits for its next piece.
            if (response.streaming) return null;
            return response.end_without_status();
        };
        if (next_one.flags.end_stream or next_one.flags.trailers) {
            try response.read_end(next_one);
            return null;
        }
        return try message_codec.open(next_one.flags.compressed, response.coding, response.decoders, next_one.payload, response.storage.scratch.message);
    }

    fn read_end(response: *Response, last: envelope.Envelope) Error!void {
        response.done = true;
        if (!response.reader.at_end()) return error.InvalidEnvelope;
        const payload = try response.inflated(last);
        switch (response.speaks.protocol) {
            .connect => {
                if (!last.flags.end_stream) return error.InvalidEnvelope;
                const end = end_stream.decode(payload, &.{
                    .tokens = response.storage.scratch.tokens,
                    .octets = response.storage.octets,
                    .details = response.storage.details,
                    .metadata = response.storage.metadata,
                }) catch {
                    response.failure = .{ .code = .internal, .message = "malformed end-stream message" };
                    return;
                };
                response.failure = end.failure;
                response.metadata = end.metadata;
            },
            .grpc_web => {
                if (!last.flags.trailers) return error.InvalidEnvelope;
                const lines = trailers.read_web_frame(payload, response.storage.metadata) catch {
                    response.failure = .{ .code = .internal, .message = "malformed trailers frame" };
                    return;
                };
                response.metadata = lines;
                response.failure = trailers.read(lines, rpc_error.find_header, status_storage(response.storage));
            },
            .grpc => return error.InvalidEnvelope,
        }
    }

    /// The payload of the last envelope, inflated when its flags say it is compressed. Connect
    /// protocol, "Streaming-Response": the end-stream message is compressed like any message.
    /// PROTOCOL-WEB.md, "Protocol differences vs gRPC over HTTP/2": the trailers frame is a
    /// message, so its compressed flag means the same.
    fn inflated(response: *const Response, last: envelope.Envelope) Error![]const u8 {
        return message_codec.open(last.flags.compressed, response.coding, response.decoders, last.payload, response.storage.scratch.message);
    }

    fn end_without_status(response: *Response) ?[]const u8 {
        if (response.trailers_only()) {
            response.read_head_status();
            return null;
        }
        response.done = true;
        response.failure = switch (response.speaks.protocol) {
            // Connect protocol, "Streaming-Response": the end-stream message is mandatory.
            .connect => .{ .code = .internal, .message = "missing end-stream message" },
            .grpc_web => .{ .code = .internal, .message = "missing trailers frame" },
            .grpc => if (response.incoming.trailers) |lookup|
                trailers.read(lookup, find_lookup, status_storage(response.storage))
            else
                .{ .code = .unimplemented, .message = "the HTTP client exposes no gRPC trailers" },
        };
        return null;
    }
};

/// The error of a 200 response whose Content-Type is not the protocol and codec the request
/// spoke, or null. Connect protocol, "Unary-Response" and "Streaming-Response", PROTOCOL-HTTP2.md,
/// "Responses", and PROTOCOL-WEB.md name the Content-Type of each. Another media type is no
/// response of the protocol, so the code comes from the HTTP status, which for 200 is `unknown`
/// (gRPC's http-grpc-status-mapping.md; Connect protocol, "HTTP to Error Code"). The right
/// protocol in another codec is a response the client cannot read: `internal`.
fn head_failure(speaks: protocol.Speaks, incoming: *const Incoming) ?RpcError {
    const content_type = incoming.headers.find("content-type") orelse return null;
    // The status is 200 here, which maps to no code of its own: `unknown`.
    assert(incoming.status == constants.protocol.status.ok);
    const unexpected: RpcError = .{ .code = .unknown, .message = "unexpected content type" };
    const answered = protocol.of_content_type(content_type) catch return unexpected;
    if (answered.protocol != speaks.protocol or answered.enveloped != speaks.enveloped) return unexpected;
    if (answered.codec != speaks.codec) return .{ .code = .internal, .message = "unexpected codec" };
    return null;
}

/// The octets of an envelope's prefix: its flags and its length.
const flag_prefix_len = constants.protocol.envelope_prefix_len;

fn status_storage(storage: Storage) trailers.Storage {
    const half = storage.octets.len / constants.storage_halves;
    return .{ .message = storage.octets[0..half], .status = storage.octets[half..], .details = storage.details };
}

fn find_lookup(lookup: Lookup, name: []const u8) ?[]const u8 {
    return lookup.find(name);
}

fn coding_header(speaks: protocol.Speaks) []const u8 {
    return switch (speaks.protocol) {
        .connect => if (speaks.enveloped) "connect-content-encoding" else "content-encoding",
        .grpc, .grpc_web => "grpc-encoding",
    };
}

/// The error of a response whose HTTP status is not 200: a Connect error body when there is one,
/// else the code the status maps to (Connect protocol, "HTTP to Error Code").
fn http_failure(speaks: protocol.Speaks, incoming: Incoming, storage: Storage, decoders: compression.Decoders) RpcError {
    const fallback: RpcError = .{ .code = Code.from_http_status(incoming.status) };
    if (speaks.protocol != .connect) return fallback;
    const content_type = incoming.headers.find("content-type") orelse return fallback;
    if (!std.mem.startsWith(u8, content_type, "application/json")) return fallback;
    // Connect protocol, "Unary-Response": Content-Encoding names the coding of the body, an
    // error's JSON included.
    const coding_name = incoming.headers.find("content-encoding") orelse "identity";
    const coding = compression.Coding.from_name(coding_name) orelse return fallback;
    const body = compression.decompress(coding, decoders, incoming.body, storage.scratch.message) catch return fallback;
    // Connect protocol, "HTTP to Error Code": an error body whose code is missing or unknown
    // takes the code of the HTTP status.
    const failure = error_json.decode_or(body, &.{ .tokens = storage.scratch.tokens, .octets = storage.octets, .details = storage.details }, fallback.code) catch return fallback;
    return failure;
}

/// The error a client gives a response it could not read.
pub fn failure_of(failure: Error) RpcError {
    return switch (failure) {
        // A message larger than the client's buffers is a limit the client set, not a fault of
        // the message (statuscodes.md, RESOURCE_EXHAUSTED), as `server.failure_of` reads it.
        error.MessageTooLarge => .{ .code = .resource_exhausted, .message = "message larger than the client reads" },
        else => .{ .code = .internal, .message = "malformed response" },
    };
}

test "a non-200 Connect response without a JSON body maps its status to a code" {
    const Empty = struct {
        fn find(_: *const anyopaque, _: []const u8) ?[]const u8 {
            return null;
        }
    };
    var buffers: [4][64]u8 = undefined;
    var details: [1]rpc_error.Detail = undefined;
    var metadata: [1]Header = undefined;
    const storage: Storage = .{
        .scratch = .{ .message = &buffers[0], .work = &buffers[1], .tokens = &buffers[2] },
        .octets = &buffers[3],
        .details = &details,
        .metadata = &metadata,
    };
    const lookup: Lookup = .{ .context = &buffers, .find_fn = Empty.find };
    const response = Response.init(.{ .protocol = .connect, .codec = .proto, .enveloped = false }, &.{ .status = 503, .headers = lookup, .body = "busy" }, &storage, &.{});
    try std.testing.expectEqual(Code.unavailable, response.failure.?.code);
    try std.testing.expect(response.done);
}

const proto = @import("protobuf");

const Note = struct {
    text: []const u8 = "",
    pub const FieldNumber = enum(u29) { text = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Note", .fields = &.{
        proto.field_of(FieldNumber.text, .string, .{}),
    } };
};

const TestEmpty = struct {
    fn find(_: *const anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }
};

/// The octets of each buffer a test's reading takes.
const test_buffer_len = 64;

/// The storage of a test's reading.
const TestRoom = struct {
    message: [test_buffer_len]u8 = undefined,
    work: [test_buffer_len]u8 = undefined,
    tokens: [test_buffer_len]u8 = undefined,
    octets: [test_buffer_len]u8 = undefined,
};

/// A streamed Connect response's storage and its start, for the tests below.
fn streamed_response(room: *TestRoom, details: []rpc_error.Detail, metadata: []Header) Response {
    const storage: Storage = .{
        .scratch = .{ .message = &room.message, .work = &room.work, .tokens = &room.tokens },
        .octets = &room.octets,
        .details = details,
        .metadata = metadata,
    };
    const lookup: Lookup = .{ .context = room, .find_fn = TestEmpty.find };
    const speaks: protocol.Speaks = .{ .protocol = .connect, .codec = .proto, .enveloped = true };
    return Response.init(speaks, &.{ .status = constants.protocol.status.ok, .headers = lookup, .body = "", .streamed = true }, &storage, &.{});
}

test "a streamed response reads each whole envelope as it arrives, and keeps a partial one" {
    var buffers: TestRoom = .{};
    var details: [1]rpc_error.Detail = undefined;
    var metadata: [1]Header = undefined;
    var response = streamed_response(&buffers, &details, &metadata);
    // "a", then "bc", whose envelope the first piece cuts, then the end-stream message "{}".
    const body = [_]u8{ 0, 0, 0, 0, 3, 0x0a, 1, 'a', 0, 0, 0, 0, 4, 0x0a, 2, 'b', 'c', 2, 0, 0, 0, 2, '{', '}' };
    const cut = 11;
    try std.testing.expectEqual(@as(?Note, null), try response.next(Note));
    try std.testing.expect(!response.done);
    try std.testing.expectEqual(@as(usize, 8), try response.feed(body[0..cut]));
    try std.testing.expectEqualStrings("a", (try response.next(Note)).?.text);
    // The rest of the second envelope has not arrived: no message, and the stream goes on.
    try std.testing.expectEqual(@as(?Note, null), try response.next(Note));
    try std.testing.expect(!response.done);
    try std.testing.expectEqual(body.len - 8, try response.feed(body[8..]));
    try std.testing.expectEqualStrings("bc", (try response.next(Note)).?.text);
    try std.testing.expectEqual(@as(?Note, null), try response.next(Note));
    try std.testing.expect(response.done);
    try std.testing.expectEqual(@as(?RpcError, null), response.failure);
}

test "a streamed body that ends inside an envelope, or with no end-stream message, fails" {
    var buffers: TestRoom = .{};
    var details: [1]rpc_error.Detail = undefined;
    var metadata: [1]Header = undefined;
    var cut = streamed_response(&buffers, &details, &metadata);
    const partial = [_]u8{ 0, 0, 0, 0, 3, 0x0a };
    try std.testing.expectEqual(@as(usize, 0), try cut.feed(&partial));
    cut.end_body(&partial);
    try std.testing.expectEqual(@as(?Note, null), try cut.next(Note));
    try std.testing.expectEqualStrings("truncated message", cut.failure.?.message);
    var bare = streamed_response(&buffers, &details, &metadata);
    bare.end_body("");
    try std.testing.expectEqual(@as(?Note, null), try bare.next(Note));
    try std.testing.expectEqualStrings("missing end-stream message", bare.failure.?.message);
    // A prefix that announces more than the reader holds fails before the payload arrives.
    var long = streamed_response(&buffers, &details, &metadata);
    try std.testing.expectError(error.MessageTooLarge, long.feed(&.{ 0, 0, 0, 1, 0 }));
}
