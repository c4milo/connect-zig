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
