//! How the conformance client reads one ClientCompatRequest: the HTTP versions its pool speaks,
//! the options of its call, its timeout, its delays and when it cancels (docs/testing_clients.md
//! in the conformance suite, "Interacting with the test runner").
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const proto = @import("protobuf");
const tls = @import("tls");
const config = @import("connectrpc_conformance_v1_config");
const client_compat = @import("connectrpc_conformance_v1_client_compat");
const constants = @import("constants.zig");
const echo = @import("echo.zig");

const Request = client_compat.ClientCompatRequest;

/// When the client cancels its call (client_compat.proto, `Cancel`).
pub const Cancel = union(enum) {
    none,
    /// In place of closing the send side, once every request went.
    before_close_send,
    /// This many milliseconds after the send side closed. A cancel that names no timing is this,
    /// at 0 ("as if the after_close_send_ms field were present and zero").
    after_close_send_ms: u32,
    /// Right after this many response messages.
    after_responses: u32,
};

/// What a case asks of its call.
pub const Plan = struct {
    options: connect.client.Options,
    protocols: client.Protocols,
    cancel: Cancel,
    /// The client's own deadline, from the call's start, and the wait before each message a
    /// stream sends.
    timeout_ns: ?u64,
    delay_ns: u64,
    /// A bidirectional stream that reads each answer before it sends the next message.
    full_duplex: bool,
    /// The largest response message the client reads, or 0 for no limit of the case's own.
    receive_limit: u32,
    /// How the client judges the server over TLS, or null for cleartext.
    tls: ?tls.Client,
};

/// What the client cannot do, which it reports instead of a call.
pub const Refusal = error{
    UnsupportedHttpVersion,
    UnsupportedProtocol,
    UnsupportedCodec,
    UnsupportedCompression,
    ClientCertificatesUnsupported,
    InvalidServerCertificate,
    TooManyHeaders,
    RawRequestUnsupported,
};

/// Reads the plan of `request`. The header lines go into `headers`, which the plan's options
/// name.
pub fn plan_of(request: *const Request, codings: *const Codings, headers: []connect.Header) (Refusal || proto.Error)!Plan {
    // docs/testing_clients.md: raw_request is for the reference client alone.
    if (request.raw_request != null) return error.RawRequestUnsupported;
    // client_compat.proto: client_tls_creds asks for a client certificate, which the client
    // does not present (client_config.yaml).
    if (request.client_tls_creds != null) return error.ClientCertificatesUnsupported;
    const protocol = try protocol_of(request.protocol);
    const coding = try coding_of(request.compression);
    return .{
        .options = .{
            .protocol = protocol,
            .codec = try codec_of(request.codec),
            .timeout_ns = timeout_ns_of(request),
            // client_compat.proto: GET applies when the protocol is Connect.
            .use_get = request.use_get_http_method and protocol == .connect,
            .request_coding = coding,
            .encoders = codings.encoders,
            .decoders = codings.decoders,
            .headers = try headers_of(request, headers),
        },
        .protocols = try protocols_of(request.http_version),
        .cancel = cancel_of(request.cancel),
        .timeout_ns = timeout_ns_of(request),
        .delay_ns = @as(u64, request.request_delay_ms) * constants.nanos_per_milli,
        .full_duplex = request.stream_type == .stream_type_full_duplex_bidi_stream,
        .receive_limit = request.message_receive_limit,
        .tls = try tls_of(request.server_tls_cert),
    };
}

/// The server's certificate, in PEM, which the client trusts as a root (docs/testing_clients.md:
/// "treat this certificate as a trusted certificate authority"), or null for cleartext. The
/// runner's certificate names "localhost" (connectconformance v1.0.4, internal/tls.go), which
/// the client sends as server_name and checks the certificate against (RFC 6125 §6).
fn tls_of(certificate: []const u8) Refusal!?tls.Client {
    if (certificate.len == 0) return null;
    const anchors = tls.pem.anchors(certificate, &anchor_der, &anchor_room) catch return error.InvalidServerCertificate;
    if (anchors.len == 0) return error.InvalidServerCertificate;
    return .{ .trust = .{ .web_pki = .{ .anchors = anchors, .server_name = server_name } }, .cpu = cpu };
}

const server_name = "localhost";
var anchor_der: [constants.client_certificate_bytes]u8 = undefined;
var anchor_room: [1]tls.Anchor align(@alignOf(tls.Anchor)) = undefined;

/// The client states nothing of the CPU, so each TLS session runs chapulin's portable code.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known },
    .timing = .not_stated,
};

/// The codings the client compresses and decompresses with.
pub const Codings = struct {
    encoders: connect.Encoders,
    decoders: connect.Decoders,
};

fn timeout_ns_of(request: *const Request) ?u64 {
    const timeout_ms = request.timeout_ms orelse return null;
    return @as(u64, timeout_ms) * constants.nanos_per_milli;
}

/// The versions the pool speaks: the one the case names (docs/testing_clients.md: "The reference
/// server will only support the given version"). In cleartext, h2 goes with prior knowledge.
fn protocols_of(version: config.HTTPVersion) Refusal!client.Protocols {
    return switch (version) {
        .http_version_1 => .{ .h11 = true, .h2 = false, .h3 = false },
        .http_version_2 => .{ .h11 = false, .h2 = true, .h3 = false },
        // RFC 9114 §3.1: h3 runs over QUIC alone, which always runs TLS.
        .http_version_3 => .{ .h11 = false, .h2 = false, .h3 = true, .prefer = .quic },
        else => error.UnsupportedHttpVersion,
    };
}

fn protocol_of(protocol: config.Protocol) Refusal!connect.Protocol {
    return switch (protocol) {
        .protocol_connect => .connect,
        .protocol_grpc => .grpc,
        .protocol_grpc_web => .grpc_web,
        else => error.UnsupportedProtocol,
    };
}

fn codec_of(codec: config.Codec) Refusal!connect.Codec {
    return switch (codec) {
        .codec_proto => .proto,
        .codec_json => .json,
        else => error.UnsupportedCodec,
    };
}

/// The coding the client compresses its requests with. It reads br too, but writes no br
/// (decision 10), so a case that sends br is refused.
fn coding_of(compression: config.Compression) Refusal!connect.Coding {
    return switch (compression) {
        .compression_unspecified, .compression_identity => .identity,
        .compression_gzip => .gzip,
        .compression_zstd => .zstd,
        else => error.UnsupportedCompression,
    };
}

fn cancel_of(cancel: ?Request.Cancel) Cancel {
    const asked = cancel orelse return .none;
    const timing = asked.cancel_timing orelse return .{ .after_close_send_ms = 0 };
    return switch (timing) {
        .before_close_send => .before_close_send,
        .after_close_send_ms => |delay_ms| .{ .after_close_send_ms = delay_ms },
        .after_num_responses => |count| .{ .after_responses = count },
    };
}

/// The case's request headers, one line for each value, in order. The client call writes each
/// name in lowercase, as h2 and h3 carry it (RFC 9113 §8.2.1).
fn headers_of(request: *const Request, lines: []connect.Header) (Refusal || proto.Error)![]const connect.Header {
    var count: usize = 0;
    var groups = request.request_headers.iterator();
    for (0..constants.client_fields_max) |_| {
        const group = try groups.next() orelse return lines[0..count];
        var values = group.value.iterator();
        for (0..constants.client_fields_max) |_| {
            const value = try values.next() orelse break;
            if (count == lines.len) return error.TooManyHeaders;
            lines[count] = .{ .name = group.name, .value = value };
            count += 1;
        }
    }
    return error.TooManyHeaders;
}

/// Decodes the request messages of a case into `messages`, each checked to be of type `T`
/// (docs/testing_clients.md, "Request messages and Any": the type name follows the last "/").
pub fn messages_of(comptime T: type, request: *const Request, messages: []T) (proto.Error || error{ WrongMessageType, TooManyMessages })![]const T {
    var count: usize = 0;
    var anys = request.request_messages.iterator();
    for (0..messages.len + 1) |_| {
        const any = try anys.next() orelse return messages[0..count];
        if (count == messages.len) return error.TooManyMessages;
        if (!std.mem.eql(u8, echo.type_name_of(any.type_url), T.protobuf.full_name)) return error.WrongMessageType;
        messages[count] = try proto.decode(T, any.value);
        count += 1;
    }
    return error.TooManyMessages;
}

const testing = std.testing;

test "a case's versions, protocol, codec and coding map to the client's, and others are refused" {
    try testing.expect((try protocols_of(.http_version_2)).h2);
    try testing.expect(!(try protocols_of(.http_version_2)).h11);
    try testing.expect((try protocols_of(.http_version_3)).h3);
    try testing.expectError(error.UnsupportedHttpVersion, protocols_of(.http_version_unspecified));
    try testing.expectEqual(connect.Protocol.grpc_web, try protocol_of(.protocol_grpc_web));
    try testing.expectEqual(connect.Codec.json, try codec_of(.codec_json));
    try testing.expectError(error.UnsupportedCodec, codec_of(.codec_text));
    try testing.expectEqual(connect.Coding.zstd, try coding_of(.compression_zstd));
    try testing.expectError(error.UnsupportedCompression, coding_of(.compression_br));
}

test "a cancel with no timing cancels right after the send side closes" {
    try testing.expectEqual(Cancel.none, cancel_of(null));
    try testing.expectEqual(Cancel{ .after_close_send_ms = 0 }, cancel_of(.{}));
    try testing.expectEqual(Cancel{ .after_responses = 2 }, cancel_of(.{ .cancel_timing = .{ .after_num_responses = 2 } }));
}
