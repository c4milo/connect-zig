//! A client's request in the protocol it chose, and the reading of the response (Connect protocol;
//! PROTOCOL-HTTP2.md; PROTOCOL-WEB.md). Every octet goes into storage the caller owns.
const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");
const compression = @import("compression.zig");
const envelope = @import("envelope.zig");
const get = @import("get.zig");
const timeout = @import("timeout.zig");
const message_codec = @import("message_codec.zig");
const method_file = @import("method.zig");
const rpc_error = @import("rpc_error.zig");
const constants = @import("constants.zig");
const Header = rpc_error.Header;
const Protocol = protocol.Protocol;
const Codec = protocol.Codec;
const Coding = compression.Coding;

pub const Options = struct {
    protocol: Protocol = .connect,
    codec: Codec = .proto,
    /// The timeout the server enforces, in nanoseconds.
    timeout_ns: ?u64 = null,
    /// Send a unary call of a NO_SIDE_EFFECTS method as a GET (Connect protocol, "Unary-Get-Request").
    use_get: bool = false,
    /// gzip compresses requests when `encoder` is set; identity sends them as they are.
    request_coding: Coding = .identity,
    encoder: ?*compression.GzipEncoder = null,
    /// What the client decompresses, which it names in its accept header.
    decoders: compression.Decoders = .{},
    /// Headers of the program's own, sent with the request: at most `extra_headers_max`.
    headers: []const Header = &.{},
};

pub const Buffers = struct {
    /// The request's body, or a GET's target.
    body: []u8,
    scratch: message_codec.Scratch,
    /// The values of the headers the client writes: the timeout and the accept list.
    values: []u8,
};

/// The most headers `request` writes.
pub const request_headers_max = protocol_headers_max + extra_headers_max;
/// The headers the protocol needs: content type, version, codings, accept list and timeout.
const protocol_headers_max = 6;
/// The headers a program or its interceptors add to one request, at most.
pub const extra_headers_max = 8;

pub const Request = struct {
    http_method: []const u8,
    /// The path, and for a GET its query.
    target: []const u8,
    storage: [request_headers_max]Header = undefined,
    count: usize = 0,
    body: []const u8,

    pub fn headers(request_value: *const Request) []const Header {
        return request_value.storage[0..request_value.count];
    }

    /// Adds a header of the program's own, such as a credential, which an interceptor adds too.
    pub fn add_header(request_value: *Request, name: []const u8, value: []const u8) error{TooManyHeaders}!void {
        if (request_value.count == request_headers_max) return error.TooManyHeaders;
        request_value.add(name, value);
    }

    fn add(request_value: *Request, name: []const u8, value: []const u8) void {
        assert(request_value.count < request_headers_max);
        request_value.storage[request_value.count] = .{ .name = name, .value = value };
        request_value.count += 1;
    }
};

pub const Error = message_codec.EncodeError || error{ NoSpaceLeft, TooManyHeaders };

fn speaks_of(comptime method: method_file.Method, options: Options) protocol.Speaks {
    const enveloped = options.protocol != .connect or method.stream_type.enveloped();
    return .{ .protocol = options.protocol, .codec = options.codec, .enveloped = enveloped };
}

/// Builds the request of a call of `method` that sends `messages`: one for a unary or a server
/// stream, any number for a client or bidirectional stream (decision 12).
pub fn request(comptime method: method_file.Method, options: Options, messages: []const method.Request, buffers: Buffers) Error!Request {
    const single = method.stream_type == .unary or method.stream_type == .server_stream;
    assert(!single or messages.len == 1);
    const speaks = speaks_of(method, options);
    const get_allowed = method.stream_type == .unary and method.idempotency == .no_side_effects;
    if (options.use_get and options.protocol == .connect and get_allowed) return request_get(method, options, &messages[0], buffers);
    var result: Request = .{ .http_method = "POST", .target = comptime method.path(), .body = "" };
    var compressed_any = false;
    var len: usize = 0;
    for (messages) |*message| {
        const octets = try message_codec.encode(method.Request, options.codec, message, buffers.scratch.message);
        const packed_message = message_codec.compress(options.request_coding, options.encoder, octets, buffers.scratch.work);
        compressed_any = compressed_any or packed_message.compressed;
        len += try place(speaks, packed_message.compressed, packed_message.octets, buffers.body[len..]);
    }
    result.body = buffers.body[0..len];
    result.add("content-type", protocol.content_type(speaks));
    try add_protocol_headers(&result, speaks, options, compressed_any, buffers.values);
    try add_extra_headers(&result, options.headers);
    return result;
}

fn add_extra_headers(result: *Request, headers: []const Header) error{TooManyHeaders}!void {
    if (headers.len > extra_headers_max) return error.TooManyHeaders;
    for (headers) |header| try result.add_header(header.name, header.value);
}

/// Writes one message into the body: bare for Connect unary, else in an envelope.
fn place(speaks: protocol.Speaks, compressed: bool, octets: []const u8, room: []u8) error{NoSpaceLeft}!usize {
    if (!speaks.enveloped) {
        if (octets.len > room.len) return error.NoSpaceLeft;
        @memcpy(room[0..octets.len], octets);
        return octets.len;
    }
    return (try envelope.write(.{ .compressed = compressed }, octets, room)).len;
}

fn add_protocol_headers(result: *Request, speaks: protocol.Speaks, options: Options, compressed: bool, values: []u8) error{NoSpaceLeft}!void {
    if (values.len < compression.accept_list_len_max + constants.protocol.connect_timeout_digits_max) return error.NoSpaceLeft;
    const accept = options.decoders.accept_list(values[0..compression.accept_list_len_max]);
    const timeout_room = values[compression.accept_list_len_max..][0..constants.protocol.connect_timeout_digits_max];
    switch (speaks.protocol) {
        .connect => add_connect_headers(result, speaks, options, compressed, accept, timeout_room),
        .grpc, .grpc_web => add_grpc_headers(result, speaks, options, accept, timeout_room),
    }
}

fn add_connect_headers(result: *Request, speaks: protocol.Speaks, options: Options, compressed: bool, accept: []const u8, timeout_room: *[constants.protocol.connect_timeout_digits_max]u8) void {
    // Connect protocol: Connect-Protocol-Version names the version on every POST.
    result.add("connect-protocol-version", constants.protocol.connect_protocol_version);
    const encoding_name = if (speaks.enveloped) "connect-content-encoding" else "content-encoding";
    const accept_name = if (speaks.enveloped) "connect-accept-encoding" else "accept-encoding";
    const announced = compressed or (speaks.enveloped and options.request_coding != .identity);
    if (announced) result.add(encoding_name, options.request_coding.name());
    if (accept.len != 0) result.add(accept_name, accept);
    if (options.timeout_ns) |nanos| result.add("connect-timeout-ms", timeout.format_connect(nanos, timeout_room));
}

fn add_grpc_headers(result: *Request, speaks: protocol.Speaks, options: Options, accept: []const u8, timeout_room: *[constants.protocol.connect_timeout_digits_max]u8) void {
    // PROTOCOL-HTTP2.md: a gRPC client sends "te: trailers"; PROTOCOL-WEB.md names x-grpc-web
    // for a gRPC-Web client.
    if (speaks.protocol == .grpc) result.add("te", "trailers") else result.add("x-grpc-web", "1");
    if (options.request_coding != .identity) result.add("grpc-encoding", options.request_coding.name());
    if (accept.len != 0) result.add("grpc-accept-encoding", accept);
    const grpc_room = timeout_room[0 .. constants.protocol.grpc_timeout_digits_max + 1];
    if (options.timeout_ns) |nanos| result.add("grpc-timeout", timeout.format_grpc(nanos, grpc_room));
}

fn request_get(comptime method: method_file.Method, options: Options, message: *const method.Request, buffers: Buffers) Error!Request {
    const octets = try message_codec.encode(method.Request, options.codec, message, buffers.scratch.message);
    const packed_message = message_codec.compress(options.request_coding, options.encoder, octets, buffers.scratch.work);
    const path = comptime method.path();
    if (buffers.body.len < path.len + 1) return error.NoSpaceLeft;
    @memcpy(buffers.body[0..path.len], path);
    buffers.body[path.len] = '?';
    const coding: Coding = if (packed_message.compressed) .gzip else .identity;
    const query = try get.write_query(options.codec, coding, packed_message.octets, buffers.body[path.len + 1 ..]);
    var result: Request = .{ .http_method = "GET", .target = buffers.body[0 .. path.len + 1 + query.len], .body = "" };
    if (buffers.values.len < compression.accept_list_len_max) return error.NoSpaceLeft;
    const accept = options.decoders.accept_list(buffers.values[0..compression.accept_list_len_max]);
    if (accept.len != 0) result.add("accept-encoding", accept);
    try add_extra_headers(&result, options.headers);
    return result;
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

const say: method_file.Method = .{ .service = "test.Svc", .name = "Say", .Request = Note, .Response = Note, .stream_type = .unary, .idempotency = .no_side_effects };
const upload: method_file.Method = .{ .service = "test.Svc", .name = "Upload", .Request = Note, .Response = Note, .stream_type = .client_stream };

fn find(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, name)) return header.value;
    }
    return null;
}

test "a Connect unary request is the bare message with the protocol's headers" {
    var buffers: [4][128]u8 = undefined;
    const call = try request(say, .{ .timeout_ns = 1_500_000 }, &.{.{ .text = "hi" }}, .{
        .body = &buffers[0],
        .scratch = .{ .message = &buffers[1], .work = &buffers[2], .tokens = &.{} },
        .values = &buffers[3],
    });
    try testing.expectEqualStrings("/test.Svc/Say", call.target);
    try testing.expectEqualSlices(u8, &.{ 0x0a, 2, 'h', 'i' }, call.body);
    try testing.expectEqualStrings("application/proto", find(call.headers(), "content-type").?);
    try testing.expectEqualStrings("2", find(call.headers(), "connect-timeout-ms").?);
    const with_token = try request(say, .{ .headers = &.{.{ .name = "authorization", .value = "Bearer t" }} }, &.{.{}}, .{
        .body = &buffers[0],
        .scratch = .{ .message = &buffers[1], .work = &buffers[2], .tokens = &.{} },
        .values = &buffers[3],
    });
    try testing.expectEqualStrings("Bearer t", find(with_token.headers(), "authorization").?);
}

test "a client stream over gRPC-Web is envelopes, and a GET carries its message in the query" {
    var buffers: [4][128]u8 = undefined;
    const scratch: message_codec.Scratch = .{ .message = &buffers[1], .work = &buffers[2], .tokens = &.{} };
    const stream = try request(upload, .{ .protocol = .grpc_web }, &.{ .{ .text = "a" }, .{} }, .{ .body = &buffers[0], .scratch = scratch, .values = &buffers[3] });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 3, 0x0a, 1, 'a', 0, 0, 0, 0, 0 }, stream.body);
    try testing.expectEqualStrings("1", find(stream.headers(), "x-grpc-web").?);
    const fetch = try request(say, .{ .use_get = true, .codec = .json }, &.{.{ .text = "x" }}, .{ .body = &buffers[0], .scratch = scratch, .values = &buffers[3] });
    try testing.expectEqualStrings("GET", fetch.http_method);
    try testing.expectEqualStrings("/test.Svc/Say?connect=v1&encoding=json&base64=1&message=eyJ0ZXh0IjoieCJ9", fetch.target);
}
