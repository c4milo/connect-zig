//! A client's reading of responses the connectrpc conformance suite sends a client (design §8
//! step 7, the client half): compressed end-stream messages, trailers frames and error bodies,
//! error codes a body leaves out, messages past the client's limit, media types the request did
//! not speak, and heads that name a gRPC status beside a body.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const client_response = @import("client_response.zig");
const compression = @import("compression.zig");
const protocol = @import("protocol.zig");
const rpc_error = @import("rpc_error.zig");
const end_stream = @import("end_stream.zig");
const constants = @import("constants.zig");
const Code = @import("code.zig").Code;
const Header = rpc_error.Header;
const Response = client_response.Response;
const Incoming = client_response.Incoming;

const Note = struct {
    text: []const u8 = "",
    pub const FieldNumber = enum(u29) { text = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Note", .fields = &.{
        proto.field_of(FieldNumber.text, .string, .{}),
    } };
};

/// The octets of each buffer a test's reading takes, and the details and metadata lines it holds.
const buffer_len = 256;
const details_max = 2;
const metadata_max = 4;
/// Envelope flags (Connect protocol, "Streaming-Response"; PROTOCOL-WEB.md): compressed, end of
/// stream, and gRPC-Web's trailers frame.
const flag_compressed = constants.protocol.flag_compressed;
const flag_end_stream = constants.protocol.flag_end_stream;
const flag_trailers = constants.protocol.flag_trailers;
const prefix_len = constants.protocol.envelope_prefix_len;

threadlocal var test_encoder: compression.GzipEncoder align(@alignOf(compression.GzipEncoder)) = undefined;
threadlocal var test_decoder: compression.GzipDecoder align(@alignOf(compression.GzipDecoder)) = undefined;

/// A head's or a trailer section's lines, which a `Lookup` finds by name.
const Lines = struct {
    lines: []const Header,

    fn find(context: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const Lines = @ptrCast(@alignCast(context));
        return rpc_error.find_header(self.lines, name);
    }

    fn lookup(self: *const Lines) @import("server_head.zig").Lookup {
        return .{ .context = self, .find_fn = find };
    }
};

/// The storage of a test's reading.
const Room = struct {
    message: [buffer_len]u8 = undefined,
    work: [buffer_len]u8 = undefined,
    tokens: [buffer_len]u8 = undefined,
    octets: [buffer_len]u8 = undefined,
    details: [details_max]rpc_error.Detail = undefined,
    metadata: [metadata_max]Header = undefined,

    fn storage(room: *Room) client_response.Storage {
        return .{
            .scratch = .{ .message = &room.message, .work = &room.work, .tokens = &room.tokens },
            .octets = &room.octets,
            .details = &room.details,
            .metadata = &room.metadata,
        };
    }
};

fn decoders() compression.Decoders {
    return .{ .gzip = &test_decoder };
}

/// `text` in gzip, written into `out`.
fn gzipped(text: []const u8, out: []u8) ![]const u8 {
    return compression.compress(.gzip, .{ .gzip = &test_encoder }, text, out);
}

/// One envelope of `payload` with `flags`, written into `out`.
fn enveloped(flags: u8, payload: []const u8, out: []u8) []const u8 {
    out[0] = flags;
    std.mem.writeInt(u32, out[1..prefix_len], @intCast(payload.len), .big);
    @memcpy(out[prefix_len..][0..payload.len], payload);
    return out[0 .. prefix_len + payload.len];
}

fn read(speaks: protocol.Speaks, status: u16, head: *const Lines, body: []const u8, room: *Room) Response {
    const incoming: Incoming = .{ .status = status, .headers = head.lookup(), .body = body };
    return Response.init(speaks, &incoming, &room.storage(), &decoders());
}

const connect_stream: protocol.Speaks = .{ .protocol = .connect, .codec = .proto, .enveloped = true };
const connect_unary: protocol.Speaks = .{ .protocol = .connect, .codec = .proto, .enveloped = false };
const grpc_web: protocol.Speaks = .{ .protocol = .grpc_web, .codec = .proto, .enveloped = true };
const grpc: protocol.Speaks = .{ .protocol = .grpc, .codec = .proto, .enveloped = true };
const ok = constants.protocol.status.ok;

test "a compressed end-stream message and a compressed trailers frame are read inflated" {
    var room: Room = .{};
    var packed_room: [buffer_len]u8 = undefined;
    var body_room: [buffer_len]u8 = undefined;
    // Connect protocol, "Streaming-Response": flags 0x02 with 0x01 is a compressed end-stream.
    const end = try gzipped("{\"error\":{\"code\":\"out_of_range\",\"message\":\"oops\"}}", &packed_room);
    const connect_head: Lines = .{ .lines = &.{ .{ .name = "content-type", .value = "application/connect+proto" }, .{ .name = "connect-content-encoding", .value = "gzip" } } };
    var stream = read(connect_stream, ok, &connect_head, enveloped(flag_end_stream | flag_compressed, end, &body_room), &room);
    try testing.expectEqual(@as(?Note, null), try stream.next(Note));
    try testing.expectEqual(Code.out_of_range, stream.failure.?.code);
    try testing.expectEqualStrings("oops", stream.failure.?.message);
    // PROTOCOL-WEB.md: a trailers frame, 0x80, compressed like any message with 0x01.
    const lines = try gzipped("grpc-status: 9\r\ngrpc-message: error\r\nx-custom-trailer: bing\r\n", &packed_room);
    const web_head: Lines = .{ .lines = &.{ .{ .name = "content-type", .value = "application/grpc-web" }, .{ .name = "grpc-encoding", .value = "gzip" } } };
    var web = read(grpc_web, ok, &web_head, enveloped(flag_trailers | flag_compressed, lines, &body_room), &room);
    try testing.expectEqual(@as(?Note, null), try web.next(Note));
    try testing.expectEqual(Code.failed_precondition, web.failure.?.code);
    try testing.expectEqualStrings("bing", rpc_error.find_header(web.metadata, "x-custom-trailer").?);
}

test "a Connect error body is read in the coding its head names" {
    var room: Room = .{};
    var packed_room: [buffer_len]u8 = undefined;
    const body = try gzipped("{\"code\":\"out_of_range\",\"message\":\"oops\"}", &packed_room);
    const head: Lines = .{ .lines = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "content-encoding", .value = "gzip" } } };
    const unprocessable = 422;
    const response = read(connect_unary, unprocessable, &head, body, &room);
    try testing.expectEqual(Code.out_of_range, response.failure.?.code);
    try testing.expectEqualStrings("oops", response.failure.?.message);
}

test "an error body's missing, null or unknown code is the HTTP status's" {
    var room: Room = .{};
    const head: Lines = .{ .lines = &.{.{ .name = "content-type", .value = "application/json" }} };
    const unauthorized = constants.protocol.status.unauthorized;
    const null_code = read(connect_unary, unauthorized, &head, "{\"code\":null,\"message\":\"oops\"}", &room);
    try testing.expectEqual(Code.unauthenticated, null_code.failure.?.code);
    try testing.expectEqualStrings("oops", null_code.failure.?.message);
    const missing = read(connect_unary, unauthorized, &head, "{\"message\":\"oops\"}", &room);
    try testing.expectEqual(Code.unauthenticated, missing.failure.?.code);
    const unknown = read(connect_unary, constants.protocol.status.too_many_requests, &head, "{\"code\":\"foobar\"}", &room);
    try testing.expectEqual(Code.unavailable, unknown.failure.?.code);
    // An end-stream message's null error is none, and its null code is `unknown`.
    const storage: end_stream.Storage = .{ .tokens = &room.tokens, .octets = &room.octets, .details = &room.details, .metadata = &room.metadata };
    try testing.expectEqual(@as(?rpc_error.RpcError, null), (try end_stream.decode("{\"error\":null}", &storage)).failure);
    const null_end = try end_stream.decode("{\"error\":{\"code\":null,\"message\":\"oops\"}}", &storage);
    try testing.expectEqual(Code.unknown, null_end.failure.?.code);
}

test "a response message past the client's limit fails resource_exhausted" {
    try testing.expectEqual(Code.resource_exhausted, client_response.failure_of(error.MessageTooLarge).code);
    var room: Room = .{};
    const head: Lines = .{ .lines = &.{.{ .name = "content-type", .value = "application/proto" }} };
    const long: [buffer_len + 1]u8 = @splat(0);
    var response = read(connect_unary, ok, &head, &long, &room);
    try testing.expectError(error.MessageTooLarge, response.next(Note));
}

test "a 200 response of another media type fails unknown, and of another codec internal" {
    var room: Room = .{};
    const image: Lines = .{ .lines = &.{.{ .name = "content-type", .value = "image/jpeg" }} };
    try testing.expectEqual(Code.unknown, read(connect_unary, ok, &image, "", &room).failure.?.code);
    const web: Lines = .{ .lines = &.{.{ .name = "content-type", .value = "application/grpc-web+proto" }} };
    try testing.expectEqual(Code.unknown, read(grpc, ok, &web, "", &room).failure.?.code);
    // A stream's framing answers a unary request: no response of the request's protocol.
    const framed: Lines = .{ .lines = &.{.{ .name = "content-type", .value = "application/connect+proto" }} };
    try testing.expectEqual(Code.unknown, read(connect_unary, ok, &framed, "", &room).failure.?.code);
    const json: Lines = .{ .lines = &.{.{ .name = "content-type", .value = "application/json" }} };
    try testing.expectEqual(Code.internal, read(connect_unary, ok, &json, "", &room).failure.?.code);
    const right: Lines = .{ .lines = &.{.{ .name = "content-type", .value = "application/proto; charset=utf-8" }} };
    try testing.expectEqual(@as(?rpc_error.RpcError, null), read(connect_unary, ok, &right, "", &room).failure);
}

/// A gRPC response whose head names `head_status`, with `body` and the trailers `tail`.
fn grpc_read(head_status: []const u8, body: []const u8, tail: *const Lines, room: *Room) Response {
    const head: Lines = .{ .lines = &.{ .{ .name = "content-type", .value = "application/grpc" }, .{ .name = "grpc-status", .value = head_status } } };
    const incoming: Incoming = .{ .status = ok, .headers = head.lookup(), .body = body, .trailers = tail.lookup() };
    return Response.init(grpc, &incoming, &room.storage(), &decoders());
}

test "a head's gRPC status counts only for a Trailers-Only response" {
    var room: Room = .{};
    var body_room: [buffer_len]u8 = undefined;
    const none: Lines = .{ .lines = &.{} };
    // PROTOCOL-HTTP2.md, "Responses": a head with a status and nothing after it is Trailers-Only.
    const only = grpc_read("9", "", &none, &room);
    try testing.expectEqual(Code.failed_precondition, only.failure.?.code);
    // A body follows: the head's status is ignored, and the missing trailers fail the call.
    var with_body = grpc_read("9", enveloped(0, &.{ 0x0a, 1, 'a' }, &body_room), &none, &room);
    try testing.expectEqualStrings("a", (try with_body.next(Note)).?.text);
    try testing.expectEqual(@as(?Note, null), try with_body.next(Note));
    try testing.expect(with_body.failure.?.code != Code.failed_precondition);
    // Trailers follow: theirs is the status.
    const tail: Lines = .{ .lines = &.{.{ .name = "grpc-status", .value = "9" }} };
    var with_trailers = grpc_read("8", "", &tail, &room);
    try testing.expectEqual(@as(?Note, null), try with_trailers.next(Note));
    try testing.expectEqual(Code.failed_precondition, with_trailers.failure.?.code);
}

test "a streamed response's head status waits for its body to end empty" {
    var room: Room = .{};
    const head: Lines = .{ .lines = &.{ .{ .name = "content-type", .value = "application/grpc-web" }, .{ .name = "grpc-status", .value = "9" } } };
    const incoming: Incoming = .{ .status = ok, .headers = head.lookup(), .body = "", .streamed = true };
    var response = Response.init(grpc_web, &incoming, &room.storage(), &decoders());
    try testing.expect(!response.done);
    response.end_body("");
    try testing.expectEqual(@as(?Note, null), try response.next(Note));
    try testing.expectEqual(Code.failed_precondition, response.failure.?.code);
}

test "a streamed response's head status is ignored once a message arrived" {
    var room: Room = .{};
    var body_room: [buffer_len]u8 = undefined;
    const head: Lines = .{ .lines = &.{ .{ .name = "content-type", .value = "application/grpc-web" }, .{ .name = "grpc-status", .value = "9" } } };
    const incoming: Incoming = .{ .status = ok, .headers = head.lookup(), .body = "", .streamed = true };
    var response = Response.init(grpc_web, &incoming, &room.storage(), &decoders());
    const body = enveloped(0, &.{ 0x0a, 1, 'a' }, &body_room);
    try testing.expectEqual(body.len, try response.feed(body));
    try testing.expectEqualStrings("a", (try response.next(Note)).?.text);
    response.end_body("");
    try testing.expectEqual(@as(?Note, null), try response.next(Note));
    // The trailers frame is missing, and the head's status does not stand in for it.
    try testing.expectEqualStrings("missing trailers frame", response.failure.?.message);
}

/// The tag of Note's field 1, a string: field number 1, wire type 2 (protobuf encoding guide,
/// "Message Structure").
const text_tag = 0x0a;

/// A gRPC-Web body of `messages`, each a Note of one letter, then a trailers frame of `status`.
fn web_body(comptime messages: []const u8, comptime status: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    inline for (messages) |letter| {
        len += enveloped(0, &.{ text_tag, 1, letter }, out[len..]).len;
    }
    len += enveloped(flag_trailers, "grpc-status: " ++ status ++ "\r\n", out[len..]).len;
    return out[0..len];
}

const plain_web_head: Lines = .{ .lines = &.{.{ .name = "content-type", .value = "application/grpc-web" }} };

test "a unary or client-stream response with two messages or none fails unimplemented" {
    var room: Room = .{};
    var body_room: [buffer_len]u8 = undefined;
    for ([_]@import("method.zig").StreamType{ .unary, .client_stream }) |stream_type| {
        var speaks = grpc_web;
        speaks.stream_type = stream_type;
        // statuscodes.md: a response cardinality violation is UNIMPLEMENTED, at the client.
        var two = read(speaks, ok, &plain_web_head, web_body("ab", "0", &body_room), &room);
        try testing.expectEqualStrings("a", (try two.next(Note)).?.text);
        try testing.expectEqual(@as(?Note, null), try two.next(Note));
        try testing.expectEqual(Code.unimplemented, two.failure.?.code);
        var none = read(speaks, ok, &plain_web_head, web_body("", "0", &body_room), &room);
        try testing.expectEqual(@as(?Note, null), try none.next(Note));
        try testing.expectEqual(Code.unimplemented, none.failure.?.code);
        // An error with no message keeps its own code.
        var failed = read(speaks, ok, &plain_web_head, web_body("", "9", &body_room), &room);
        try testing.expectEqual(@as(?Note, null), try failed.next(Note));
        try testing.expectEqual(Code.failed_precondition, failed.failure.?.code);
        var one = read(speaks, ok, &plain_web_head, web_body("a", "0", &body_room), &room);
        try testing.expectEqualStrings("a", (try one.next(Note)).?.text);
        try testing.expectEqual(@as(?Note, null), try one.next(Note));
        try testing.expectEqual(@as(?rpc_error.RpcError, null), one.failure);
    }
}

test "a stream's response may hold any number of messages, and a Trailers-Only one none" {
    var room: Room = .{};
    var body_room: [buffer_len]u8 = undefined;
    var speaks = grpc_web;
    speaks.stream_type = .server_stream;
    var none = read(speaks, ok, &plain_web_head, web_body("", "0", &body_room), &room);
    try testing.expectEqual(@as(?Note, null), try none.next(Note));
    try testing.expectEqual(@as(?rpc_error.RpcError, null), none.failure);
    // PROTOCOL-HTTP2.md, "Responses": a Trailers-Only success of a unary call holds no message.
    speaks.stream_type = .unary;
    const only: Lines = .{ .lines = &.{ .{ .name = "content-type", .value = "application/grpc-web" }, .{ .name = "grpc-status", .value = "0" } } };
    var trailers_only = read(speaks, ok, &only, "", &room);
    try testing.expectEqual(@as(?Note, null), try trailers_only.next(Note));
    try testing.expectEqual(Code.unimplemented, trailers_only.failure.?.code);
}
