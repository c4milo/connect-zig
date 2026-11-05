//! Calls from a client to a server through this module alone, with the HTTP layer reduced to
//! header lists and bodies in memory: each protocol, each codec, each stream type, and errors.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const gzip = @import("gzip");
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
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Note", .fields = &.{
        .{ .name = "text", .number = 1, .kind = .string, .json_name = "text", .proto_name = "text" },
        .{ .name = "count", .number = 2, .kind = .int32, .json_name = "count", .proto_name = "count" },
    } };
};

const say: connect.Method = .{ .service = "test.Svc", .name = "Say", .Request = Note, .Response = Note, .stream_type = .unary, .idempotency = .no_side_effects };
const count_up: connect.Method = .{ .service = "test.Svc", .name = "CountUp", .Request = Note, .Response = Note, .stream_type = .server_stream };
const gather: connect.Method = .{ .service = "test.Svc", .name = "Gather", .Request = Note, .Response = Note, .stream_type = .client_stream };

const List = struct {
    entries: []const Header,

    fn find(context: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const List = @ptrCast(@alignCast(context));
        for (self.entries) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    fn lookup(self: *const List) server_head.Lookup {
        return .{ .context = self, .find_fn = find };
    }
};

const Server = struct {
    buffers: [4][4096]u8 = undefined,
    body: [4096]u8 = undefined,
    body_len: usize = 0,
    head: server_reply.Head = .{ .status = 0 },
    trailers_storage: [1024]u8 = undefined,
    trailers: []const Header = &.{},
    trailer_out: [connect.trailers.trailers_max]Header = undefined,
    encoder: connect.GzipEncoder = undefined,
    decoder: gzip.Decoder = undefined,

    fn scratch(server: *Server) message_codec.Scratch {
        return .{ .message = &server.buffers[0], .work = &server.buffers[1], .tokens = &server.buffers[2] };
    }

    /// Serves `method`: each request message is echoed `count` times, or the call fails with
    /// `failure` when it is set.
    fn serve(server: *Server, comptime method: connect.Method, request: *const client_call.Request, failure: ?connect.RpcError) !void {
        const list: List = .{ .entries = request.headers() };
        const target = request.target;
        const question = std.mem.indexOfScalar(u8, target, '?');
        const query = if (question) |at| target[at + 1 ..] else null;
        const decoders: connect.Decoders = .{ .gzip = &server.decoder };
        const decision = server_head.accept(request.http_method, query, list.lookup(), .{
            .stream_type = method.stream_type,
            .idempotency = method.idempotency,
            .decoders = decoders,
            .can_compress = true,
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
        var reply: server_reply.Reply = .{ .accepted = accepted, .scratch = server.scratch(), .encoder = &server.encoder };
        if (failure) |rpc_failure| return server.fail(&reply, rpc_failure, &body);
        var messages = server_request.Messages.init(accepted, request.body, .{ .message = &server.buffers[3], .work = &server.buffers[1], .tokens = &server.buffers[2] }, decoders);
        server.head = reply.head(false);
        for (0..16) |_| {
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
    buffers: [4][4096]u8 = undefined,
    response_buffers: [4][4096]u8 = undefined,
    details: [4]connect.Detail = undefined,
    metadata: [8]Header = undefined,
    decoder: gzip.Decoder = undefined,
    encoder: connect.GzipEncoder = undefined,
    head_list: List = .{ .entries = &.{} },
    trailer_list: List = .{ .entries = &.{} },

    fn call_buffers(client: *Client) client_call.Buffers {
        return .{ .body = &client.buffers[0], .scratch = .{ .message = &client.buffers[1], .work = &client.buffers[2], .tokens = &.{} }, .values = &client.buffers[3] };
    }

    fn response(client: *Client, speaks: connect.Speaks, server: *const Server) client_response.Response {
        client.head_list = .{ .entries = server.head.headers() };
        client.trailer_list = .{ .entries = server.trailers };
        const storage: client_response.Storage = .{
            .scratch = .{ .message = &client.response_buffers[0], .work = &client.response_buffers[1], .tokens = &client.response_buffers[2] },
            .octets = &client.response_buffers[3],
            .details = &client.details,
            .metadata = &client.metadata,
        };
        return client_response.read(speaks, .{
            .status = server.head.status,
            .headers = client.head_list.lookup(),
            .body = server.body[0..server.body_len],
            .trailers = client.trailer_list.lookup(),
        }, storage, .{ .gzip = &client.decoder });
    }
};

fn speaks_of(comptime method: connect.Method, options: client_call.Options) connect.Speaks {
    return .{ .protocol = options.protocol, .codec = options.codec, .enveloped = options.protocol != .connect or method.stream_type.enveloped() };
}

var server_state: Server = .{};
var client_state: Client = .{};

fn round_trip(comptime method: connect.Method, options: client_call.Options, messages: []const Note, failure: ?connect.RpcError) !client_response.Response {
    var with_codings = options;
    with_codings.decoders = .{ .gzip = &client_state.decoder };
    with_codings.encoder = &client_state.encoder;
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
