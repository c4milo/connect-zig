//! What a server reads from a request's head before it reads the body: the protocol, the
//! codec, the codings of the request and of the response, the timeout and, for a GET, the query
//! (Connect protocol, "Unary-Request", "Unary-Get-Request" and "Streaming-Request";
//! PROTOCOL-HTTP2.md, "Requests"; PROTOCOL-WEB.md).
const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");
const compression = @import("compression.zig");
const method = @import("method.zig");
const timeout = @import("timeout.zig");
const get = @import("get.zig");
const rpc_error = @import("rpc_error.zig");
const constants = @import("constants.zig");
const status = constants.protocol.status;
const Speaks = protocol.Speaks;
const Coding = compression.Coding;
const RpcError = rpc_error.RpcError;

/// Finds a request header's value by name, case-insensitively, through the HTTP library's own
/// lookup.
pub const Lookup = struct {
    context: *const anyopaque,
    find_fn: *const fn (context: *const anyopaque, name: []const u8) ?[]const u8,

    pub fn find(lookup: Lookup, name: []const u8) ?[]const u8 {
        return lookup.find_fn(lookup.context, name);
    }
};

pub const Accepted = struct {
    speaks: Speaks,
    request_coding: Coding,
    response_coding: Coding,
    /// The timeout the client asked for, in nanoseconds.
    timeout_ns: ?u64,
    /// The query of a unary GET.
    query: ?get.Query = null,
};

/// A request the server answers without calling the handler.
pub const Refused = struct {
    /// The HTTP status. A refusal of the media type or the method has no body (Connect
    /// protocol, "Unary-Request": a server answers 415 with no Connect error).
    http_status: u16,
    /// The error, in the protocol the request speaks, when the protocol is known.
    failure: ?RpcError = null,
    speaks: ?Speaks = null,
};

pub const Decision = union(enum) {
    accepted: Accepted,
    refused: Refused,
};

pub const Options = struct {
    stream_type: method.StreamType,
    idempotency: method.Idempotency = .unknown,
    /// What the server decompresses.
    decoders: compression.Decoders = .{},
    /// The encoders the server compresses responses with, which name the codings it can choose.
    encoders: compression.Encoders = .{},
};

/// Reads the head of a request for a method of `options.stream_type`.
pub fn accept(http_method: []const u8, query: ?[]const u8, headers: Lookup, options: Options) Decision {
    if (std.mem.eql(u8, http_method, "GET")) return accept_get(query orelse "", headers, options);
    // Connect protocol, "Unary-Request": a request is a POST, or a GET of a NO_SIDE_EFFECTS method.
    if (!std.mem.eql(u8, http_method, "POST")) return .{ .refused = .{ .http_status = status.method_not_allowed } };
    const content_type = headers.find("content-type") orelse return .{ .refused = .{ .http_status = status.unsupported_media_type } };
    const speaks = protocol.of_content_type(content_type) catch return .{ .refused = .{ .http_status = status.unsupported_media_type } };
    // Connect protocol: a unary method takes a unary content type, and a stream an enveloped one.
    if (speaks.protocol == .connect and speaks.enveloped != options.stream_type.enveloped()) {
        return .{ .refused = .{ .http_status = status.unsupported_media_type } };
    }
    return accept_post(speaks, headers, options);
}

const Names = struct { encoding: []const u8, accept: []const u8, timeout: []const u8 };

fn names_of(speaks: Speaks) Names {
    return switch (speaks.protocol) {
        // Connect protocol: a unary request names its coding in Content-Encoding, and a stream in
        // Connect-Content-Encoding.
        .connect => if (speaks.enveloped)
            .{ .encoding = "connect-content-encoding", .accept = "connect-accept-encoding", .timeout = "connect-timeout-ms" }
        else
            .{ .encoding = "content-encoding", .accept = "accept-encoding", .timeout = "connect-timeout-ms" },
        .grpc, .grpc_web => .{ .encoding = "grpc-encoding", .accept = "grpc-accept-encoding", .timeout = "grpc-timeout" },
    };
}

fn accept_post(speaks: Speaks, headers: Lookup, options: Options) Decision {
    const names = names_of(speaks);
    if (speaks.protocol == .connect and !speaks.enveloped) {
        if (headers.find("connect-protocol-version")) |version| {
            // Connect protocol, "Unary-Request": the only version is 1.
            if (!std.mem.eql(u8, version, constants.protocol.connect_protocol_version)) {
                return refuse(speaks, .invalid_argument, "connect-protocol-version must be 1");
            }
        }
    }
    const request_coding = coding_of(headers.find(names.encoding)) orelse return refuse(speaks, .unimplemented, "unknown request compression");
    if (!options.decoders.accepts(request_coding)) return refuse(speaks, .unimplemented, "unsupported request compression");
    const timeout_ns = read_timeout(speaks, headers.find(names.timeout)) catch return refuse(speaks, .invalid_argument, "malformed timeout");
    const response_coding = compression.choose(headers.find(names.accept) orelse "", options.encoders);
    return .{ .accepted = .{ .speaks = speaks, .request_coding = request_coding, .response_coding = response_coding, .timeout_ns = timeout_ns } };
}

fn accept_get(query: []const u8, headers: Lookup, options: Options) Decision {
    // Connect protocol, "Unary-Get-Request": only methods with no side effects take a GET.
    if (options.stream_type != .unary or options.idempotency != .no_side_effects) return .{ .refused = .{ .http_status = status.method_not_allowed } };
    const read = get.read_query(query) catch return .{ .refused = .{ .http_status = status.bad_request } };
    const speaks: Speaks = .{ .protocol = .connect, .codec = read.codec, .enveloped = false };
    if (!options.decoders.accepts(read.coding)) return refuse(speaks, .unimplemented, "unsupported request compression");
    const timeout_ns = read_timeout(speaks, headers.find("connect-timeout-ms")) catch return refuse(speaks, .invalid_argument, "malformed timeout");
    const response_coding = compression.choose(headers.find("accept-encoding") orelse "", options.encoders);
    return .{ .accepted = .{ .speaks = speaks, .request_coding = read.coding, .response_coding = response_coding, .timeout_ns = timeout_ns, .query = read } };
}

fn coding_of(value: ?[]const u8) ?Coding {
    return Coding.from_name(value orelse return .identity);
}

fn read_timeout(speaks: Speaks, value: ?[]const u8) timeout.Error!?u64 {
    const text = value orelse return null;
    return switch (speaks.protocol) {
        .connect => try timeout.parse_connect(text),
        .grpc, .grpc_web => try timeout.parse_grpc(text),
    };
}

fn refuse(speaks: Speaks, code: @import("code.zig").Code, message: []const u8) Decision {
    assert(code != .ok);
    const http_status: u16 = if (speaks.protocol == .connect) code.http_status() else status.ok;
    return .{ .refused = .{ .http_status = http_status, .failure = .{ .code = code, .message = message }, .speaks = speaks } };
}

const testing = std.testing;

const TestHeaders = struct {
    entries: []const rpc_error.Header,

    fn find(context: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestHeaders = @ptrCast(@alignCast(context));
        return rpc_error.find_header(self.entries, name);
    }

    fn lookup(self: *const TestHeaders) Lookup {
        return .{ .context = self, .find_fn = find };
    }
};

test "a Connect unary POST is accepted with its codings and timeout" {
    const headers: TestHeaders = .{ .entries = &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept-Encoding", .value = "gzip" },
        .{ .name = "Connect-Timeout-Ms", .value = "250" },
    } };
    var encoder: compression.GzipEncoder = undefined;
    const decision = accept("POST", null, headers.lookup(), .{ .stream_type = .unary, .encoders = .{ .gzip = &encoder } });
    const accepted = decision.accepted;
    try testing.expectEqual(protocol.Codec.json, accepted.speaks.codec);
    try testing.expectEqual(Coding.gzip, accepted.response_coding);
    try testing.expectEqual(@as(?u64, 250_000_000), accepted.timeout_ns);
}

test "a stream with a unary content type, an unknown type and a GET of a mutation are refused" {
    const unary_type: TestHeaders = .{ .entries = &.{.{ .name = "content-type", .value = "application/proto" }} };
    try testing.expectEqual(@as(u16, 415), accept("POST", null, unary_type.lookup(), .{ .stream_type = .server_stream }).refused.http_status);
    const unknown: TestHeaders = .{ .entries = &.{.{ .name = "content-type", .value = "text/html" }} };
    try testing.expectEqual(@as(u16, 415), accept("POST", null, unknown.lookup(), .{ .stream_type = .unary }).refused.http_status);
    try testing.expectEqual(@as(u16, 405), accept("GET", "encoding=proto&message=", unary_type.lookup(), .{ .stream_type = .unary }).refused.http_status);
    try testing.expectEqual(@as(u16, 405), accept("PUT", null, unary_type.lookup(), .{ .stream_type = .unary }).refused.http_status);
}

test "an unsupported coding is unimplemented, in the request's own protocol" {
    const headers: TestHeaders = .{ .entries = &.{
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "grpc-encoding", .value = "snappy" },
    } };
    const refused = accept("POST", null, headers.lookup(), .{ .stream_type = .unary }).refused;
    try testing.expectEqual(@as(u16, 200), refused.http_status);
    try testing.expectEqual(@import("code.zig").Code.unimplemented, refused.failure.?.code);
    const gzipped: TestHeaders = .{ .entries = &.{
        .{ .name = "content-type", .value = "application/proto" },
        .{ .name = "content-encoding", .value = "gzip" },
    } };
    try testing.expectEqual(@as(u16, 501), accept("POST", null, gzipped.lookup(), .{ .stream_type = .unary }).refused.http_status);
}

test "a GET of a method with no side effects is accepted with its query" {
    const headers: TestHeaders = .{ .entries = &.{} };
    const decision = accept("GET", "encoding=json&message=e30", headers.lookup(), .{ .stream_type = .unary, .idempotency = .no_side_effects });
    try testing.expectEqual(protocol.Codec.json, decision.accepted.query.?.codec);
}
