//! Calls from a client to a server through this module alone, with the HTTP layer reduced to
//! header lists and bodies in memory: each protocol, each codec, each stream type, and errors.
const std = @import("std");
const rpc_error = @import("rpc_error.zig");
const testing = std.testing;
const proto = @import("protobuf");
const gzip = @import("gzip");
const zstd = @import("zstd");
const connect = @import("connect.zig");
const client_call = @import("client_call.zig");
const client_response = @import("client_response.zig");
const server_head = @import("server_head.zig");
const server_request = @import("server_request.zig");
const server_reply = @import("server_reply.zig");
const message_codec = @import("message_codec.zig");
const Header = connect.Header;

const Note = struct {
    text: []const u8 = "",
    count: i32 = 0,
    pub const FieldNumber = enum(u29) { text = 1, count = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Note", .fields = &.{
        proto.field_of(FieldNumber.text, .string, .{}),
        proto.field_of(FieldNumber.count, .int32, .{}),
    } };
};

const say: connect.Method = .{ .service = "test.Svc", .name = "Say", .Request = Note, .Response = Note, .stream_type = .unary, .idempotency = .no_side_effects };
const count_up: connect.Method = .{ .service = "test.Svc", .name = "CountUp", .Request = Note, .Response = Note, .stream_type = .server_stream };
const gather: connect.Method = .{ .service = "test.Svc", .name = "Gather", .Request = Note, .Response = Note, .stream_type = .client_stream };

const List = struct {
    entries: []const Header,

    fn find(context: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const List = @ptrCast(@alignCast(context));
        return rpc_error.find_header(self.entries, name);
    }

    fn lookup(self: *const List) server_head.Lookup {
        return .{ .context = self, .find_fn = find };
    }
};

/// The octets of each buffer a side of the exchange holds.
const buffer_len = 4096;
const trailers_storage_len = 1024;
const details_max = 4;
const metadata_max = 8;
/// The messages one call carries, at most.
const notes_max = 16;

const Server = struct {
    message: [buffer_len]u8 = undefined,
    work: [buffer_len]u8 = undefined,
    tokens: [buffer_len]u8 = undefined,
    request_message: [buffer_len]u8 = undefined,
    body: [buffer_len]u8 = undefined,
    body_len: usize = 0,
    head: server_reply.Head = .{ .status = 0 },
    trailers_storage: [trailers_storage_len]u8 = undefined,
    trailers: []const Header = &.{},
    trailer_out: [connect.trailers.trailers_max]Header = undefined,
    encoder: connect.GzipEncoder = undefined,
    decoder: gzip.Decoder = undefined,
    zstd_encoder: connect.ZstdEncoder = undefined,
    zstd_decoder: zstd.HttpDecoder = undefined,

    fn scratch(server: *Server) message_codec.Scratch {
        return .{ .message = &server.message, .work = &server.work, .tokens = &server.tokens };
    }

    /// Serves `method`: each request message is echoed `count` times, or the call fails with
    /// `failure` when it is set.
    fn serve(server: *Server, comptime method: connect.Method, request: *const client_call.Request, failure: ?connect.RpcError) !void {
        const list: List = .{ .entries = request.headers() };
        const target = request.target;
        const question = std.mem.indexOfScalar(u8, target, '?');
        const query = if (question) |at| target[at + 1 ..] else null;
        const decoders: connect.Decoders = .{ .gzip = &server.decoder, .zstd = &server.zstd_decoder };
        const encoders: connect.Encoders = .{ .gzip = &server.encoder, .zstd = &server.zstd_encoder };
        const decision = server_head.accept(request.http_method, query, list.lookup(), .{
            .stream_type = method.stream_type,
            .idempotency = method.idempotency,
            .decoders = decoders,
            .encoders = encoders,
        });
        var body: std.Io.Writer = .fixed(&server.body);
        defer server.body_len = body.end;
        const accepted = switch (decision) {
            .accepted => |accepted| accepted,
            .refused => |refused| {
                var reply = server_reply.refusal_reply(refused, server.scratch()) orelse {
                    server.head = .{ .status = refused.http_status };
                    return;
                };
                return server.fail(&reply, refused.failure.?, &body);
            },
        };
        var reply: server_reply.Reply = .{ .accepted = accepted, .scratch = server.scratch(), .encoders = encoders };
        if (failure) |rpc_failure| return server.fail(&reply, rpc_failure, &body);
        var messages = server_request.Messages.init(accepted, request.body, .{ .message = &server.request_message, .work = &server.work, .tokens = &server.tokens }, decoders);
        server.head = reply.head(false);
        for (0..notes_max) |_| {
            const note = try messages.next(method.Request) orelse break;
            for (0..@intCast(@max(note.count, 1))) |index| {
                const prepared = try reply.prepare(Note, &.{ .text = note.text, .count = @intCast(index) });
                if (!accepted.speaks.enveloped) server.head = reply.head(prepared.compressed);
                try reply.write_message(prepared, &body);
            }
        }
        if (accepted.speaks.enveloped) server.trailers = try reply.finish(null, &.{.{ .name = "x-served", .value = "yes" }}, &body, &server.trailers_storage, &server.trailer_out);
    }

    fn fail(server: *Server, reply: *server_reply.Reply, failure: connect.RpcError, body: *std.Io.Writer) !void {
        if (reply.error_only()) {
            server.head = try reply.error_head(failure, &server.trailers_storage);
            return reply.write_error_body(failure, body);
        }
        server.head = reply.head(false);
        server.trailers = try reply.finish(failure, &.{}, body, &server.trailers_storage, &server.trailer_out);
    }
};

const Client = struct {
    body: [buffer_len]u8 = undefined,
    message: [buffer_len]u8 = undefined,
    work: [buffer_len]u8 = undefined,
    values: [buffer_len]u8 = undefined,
    response_message: [buffer_len]u8 = undefined,
    response_work: [buffer_len]u8 = undefined,
    response_tokens: [buffer_len]u8 = undefined,
    response_octets: [buffer_len]u8 = undefined,
    details: [details_max]connect.Detail = undefined,
    metadata: [metadata_max]Header = undefined,
    decoder: gzip.Decoder = undefined,
    encoder: connect.GzipEncoder = undefined,
    zstd_decoder: zstd.HttpDecoder = undefined,
    zstd_encoder: connect.ZstdEncoder = undefined,
    head_list: List = .{ .entries = &.{} },
    trailer_list: List = .{ .entries = &.{} },

    fn call_buffers(client: *Client) client_call.Buffers {
        return .{ .body = &client.body, .scratch = .{ .message = &client.message, .work = &client.work, .tokens = &.{} }, .values = &client.values };
    }

    fn response(client: *Client, speaks: connect.Speaks, server: *const Server) client_response.Response {
        client.head_list = .{ .entries = server.head.headers() };
        client.trailer_list = .{ .entries = server.trailers };
        const storage: client_response.Storage = .{
            .scratch = .{ .message = &client.response_message, .work = &client.response_work, .tokens = &client.response_tokens },
            .octets = &client.response_octets,
            .details = &client.details,
            .metadata = &client.metadata,
        };
        return client_response.read(speaks, .{
            .status = server.head.status,
            .headers = client.head_list.lookup(),
            .body = server.body[0..server.body_len],
            .trailers = client.trailer_list.lookup(),
        }, storage, .{ .gzip = &client.decoder, .zstd = &client.zstd_decoder });
    }
};

fn speaks_of(comptime method: connect.Method, options: client_call.Options) connect.Speaks {
    return .{ .protocol = options.protocol, .codec = options.codec, .enveloped = options.protocol != .connect or method.stream_type.enveloped() };
}

// Each test thread holds its own pair, which the test cases reuse.
threadlocal var server_state: Server align(@alignOf(Server)) = .{};
threadlocal var client_state: Client align(@alignOf(Client)) = .{};

fn round_trip(comptime method: connect.Method, options: client_call.Options, messages: []const Note, failure: ?connect.RpcError) !client_response.Response {
    var with_codings = options;
    // A case that names its decoders keeps them: its accept list is what the server chooses from.
    const named = options.decoders.gzip != null or options.decoders.zstd != null;
    if (!named) with_codings.decoders = .{ .gzip = &client_state.decoder, .zstd = &client_state.zstd_decoder };
    with_codings.encoders = .{ .gzip = &client_state.encoder, .zstd = &client_state.zstd_encoder };
    const request = try client_call.request(method, with_codings, messages, client_state.call_buffers());
    try server_state.serve(method, &request, failure);
    return client_state.response(speaks_of(method, options), &server_state);
}

const protocols = [_]connect.Protocol{ .connect, .grpc, .grpc_web };
const codecs = [_]connect.Codec{ .proto, .json };

test "a unary call returns its message in every protocol and codec" {
    for (protocols) |protocol| for (codecs) |codec| {
        var response = try round_trip(say, .{ .protocol = protocol, .codec = codec }, &.{.{ .text = "hello" }}, null);
        const note = (try response.next(Note)).?;
        try testing.expectEqualStrings("hello", note.text);
        try testing.expectEqual(@as(?Note, null), try response.next(Note));
        try testing.expectEqual(@as(?connect.RpcError, null), response.failure);
    };
}

test "a server stream returns each message, then success and the metadata" {
    for (protocols) |protocol| {
        var response = try round_trip(count_up, .{ .protocol = protocol }, &.{.{ .text = "n", .count = 3 }}, null);
        for (0..3) |index| try testing.expectEqual(@as(i32, @intCast(index)), (try response.next(Note)).?.count);
        try testing.expectEqual(@as(?Note, null), try response.next(Note));
        try testing.expectEqual(@as(?connect.RpcError, null), response.failure);
    }
}

test "a client stream sends every message in one body" {
    var response = try round_trip(gather, .{ .protocol = .connect, .codec = .json }, &.{ .{ .text = "a" }, .{ .text = "b" } }, null);
    try testing.expectEqualStrings("a", (try response.next(Note)).?.text);
    try testing.expectEqualStrings("b", (try response.next(Note)).?.text);
    try testing.expectEqual(@as(?Note, null), try response.next(Note));
}

test "an error reaches the client with its code and message in every protocol" {
    const failure: connect.RpcError = .{ .code = .permission_denied, .message = "nope: 100%", .details = &.{.{ .type_name = "a.B", .value = "v" }} };
    for (protocols) |protocol| {
        var unary = try round_trip(say, .{ .protocol = protocol }, &.{.{}}, failure);
        try testing.expectEqual(@as(?Note, null), try unary.next(Note));
        try testing.expectEqual(connect.Code.permission_denied, unary.failure.?.code);
        try testing.expectEqualStrings("nope: 100%", unary.failure.?.message);
        try testing.expectEqualStrings("a.B", unary.failure.?.details[0].type_name);
        var stream = try round_trip(count_up, .{ .protocol = protocol }, &.{.{}}, failure);
        try testing.expectEqual(@as(?Note, null), try stream.next(Note));
        try testing.expectEqual(connect.Code.permission_denied, stream.failure.?.code);
    }
}

test "a GET, gzip both ways, and a timeout pass through" {
    var response = try round_trip(say, .{ .use_get = true, .codec = .json, .timeout_ns = 5_000_000 }, &.{.{ .text = "got" }}, null);
    try testing.expectEqualStrings("got", (try response.next(Note)).?.text);
    const long = "z" ** 2000;
    var compressed = try round_trip(say, .{ .protocol = .grpc, .request_coding = .gzip }, &.{.{ .text = long }}, null);
    try testing.expectEqualStrings("gzip", server_state.head.headers()[1].value);
    try testing.expectEqualStrings(long, (try compressed.next(Note)).?.text);
    var unary_gzip = try round_trip(say, .{ .request_coding = .gzip }, &.{.{ .text = long }}, null);
    try testing.expectEqualStrings(long, (try unary_gzip.next(Note)).?.text);
}

test "zstd both ways: the client sends it, and a server answers in it to a client that takes it alone" {
    const long = "zstd " ** 300;
    const zstd_only: connect.Decoders = .{ .zstd = &client_state.zstd_decoder };
    var compressed = try round_trip(say, .{ .protocol = .grpc, .request_coding = .zstd, .decoders = zstd_only }, &.{.{ .text = long }}, null);
    try testing.expectEqualStrings("zstd", server_state.head.headers()[1].value);
    // The reply's envelope is flagged compressed, so the server wrote it in zstd.
    try testing.expectEqual(@as(u8, 1), server_state.body[0]);
    try testing.expectEqualStrings(long, (try compressed.next(Note)).?.text);
    var unary = try round_trip(say, .{ .request_coding = .zstd, .decoders = zstd_only }, &.{.{ .text = long }}, null);
    try testing.expectEqualStrings(long, (try unary.next(Note)).?.text);
    // A GET names its message's coding in its query (Connect protocol, "Unary-Get-Request").
    var get = try round_trip(say, .{ .use_get = true, .request_coding = .zstd, .decoders = zstd_only }, &.{.{ .text = long }}, null);
    try testing.expectEqualStrings(long, (try get.next(Note)).?.text);
}

test "a Connect stream with no end-stream message fails, and a short message is not compressed" {
    var response = try round_trip(count_up, .{}, &.{.{ .text = "n", .count = 1 }}, null);
    // Cut the end-stream envelope off the body the server wrote.
    server_state.body_len = 5 + 3;
    response = client_state.response(speaks_of(count_up, .{}), &server_state);
    try testing.expectEqual(@as(i32, 0), (try response.next(Note)).?.count);
    try testing.expectEqual(@as(?Note, null), try response.next(Note));
    try testing.expectEqual(connect.Code.internal, response.failure.?.code);
    _ = try round_trip(say, .{ .protocol = .grpc, .request_coding = .gzip }, &.{.{ .text = "short" }}, null);
    try testing.expectEqual(@as(u8, 0), server_state.body[0]);
}
