//! The conformance server: connectrpc.conformance.v1.ConformanceService for the connectrpc
//! conformance runner in server mode (design §8 step 7). `tools/conformance_check.sh` runs it.
//!
//! The runner writes one ServerCompatRequest to stdin, and reads one ServerCompatResponse from
//! stdout, each after a 4-octet big-endian length (connectconformance `--help`;
//! docs/testing_servers.md, "Starting your server"). The server listens on 127.0.0.1 at a port
//! the kernel chooses, in cleartext, and serves h11 and h2 with prior knowledge until the runner
//! ends it with SIGTERM, whose default action ends the process.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
const socket_loop = @import("socket_loop");
const service = @import("connectrpc_conformance_v1_service");
const server_compat = @import("connectrpc_conformance_v1_server_compat");
const constants = @import("constants.zig");
const App = @import("app.zig").App;
const Router = @import("service.zig").Router;

/// The types an Any in a JSON message may name (decision 21): every message the service reads
/// and writes, since a request echoes in a response's `requests`, and an error's details.
pub const protobuf_any_types = .{
    service.UnaryRequest,                      service.UnaryResponse,
    service.IdempotentUnaryRequest,            service.IdempotentUnaryResponse,
    service.ServerStreamRequest,               service.ServerStreamResponse,
    service.ClientStreamRequest,               service.ClientStreamResponse,
    service.BidiStreamRequest,                 service.BidiStreamResponse,
    service.UnimplementedRequest,              service.UnimplementedResponse,
    service.ConformancePayload,                service.ConformancePayload.RequestInfo,
    service.ConformancePayload.ConnectGetInfo, service.Error,
    service.Header,
};

const Server = socket_loop.SocketServer(App, Router, .{
    .sockets_max = constants.sockets_max,
    .socket_buffer_len = constants.socket_buffer_len,
    .log_requests = false,
    .timeouts = .{ .first_request_ns = constants.first_request_timeout_ns, .idle_ns = constants.idle_timeout_ns },
});

var socket_server: Server align(@alignOf(Server)) = .{};
var app: App align(@alignOf(App)) = .{};
var gzip_decoder: connect.GzipDecoder align(@alignOf(connect.GzipDecoder)) = undefined;
var gzip_encoder: connect.GzipEncoder align(@alignOf(connect.GzipEncoder)) = undefined;
var zstd_decoder: connect.ZstdDecoder align(@alignOf(connect.ZstdDecoder)) = undefined;
var zstd_encoder: connect.ZstdEncoder align(@alignOf(connect.ZstdEncoder)) = undefined;
var compat_request_bytes: [constants.compat_request_bytes_max]u8 align(@alignOf(u64)) = undefined;

/// The host the runner's client connects to.
const host = "127.0.0.1";

pub fn main(init: std.process.Init) !void {
    const request_bytes = try read_request(init.io);
    const request = try proto.decode(server_compat.ServerCompatRequest, request_bytes);
    // config.yaml declares no TLS, so the runner never asks for it; a request for it fails here
    // rather than serving cleartext to a client that expects TLS.
    if (request.use_tls or request.client_tls_cert.len != 0) return error.TlsUnsupported;
    if (request.message_receive_limit > constants.message_bytes) return error.ReceiveLimitTooLarge;
    app.message_receive_limit = request.message_receive_limit;
    app.io = init.io;
    app.codings = .{
        .decoders = .{ .gzip = &gzip_decoder, .zstd = &zstd_decoder },
        .encoders = .{ .gzip = &gzip_encoder, .zstd = &zstd_encoder },
    };
    try socket_server.serve(&app, 0, Listening{ .io = init.io });
}

/// Reads the length-prefixed ServerCompatRequest from stdin.
fn read_request(io: std.Io) ![]const u8 {
    var buffer: [constants.length_prefix_len]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &buffer);
    var prefix: [constants.length_prefix_len]u8 = undefined;
    try stdin.interface.readSliceAll(&prefix);
    // docs/testing_servers.md: "a network-byte-order (i.e. big-endian) 32-bit integer".
    const len = std.mem.readInt(u32, &prefix, .big);
    if (len > compat_request_bytes.len) return error.RequestTooLarge;
    try stdin.interface.readSliceAll(compat_request_bytes[0..len]);
    return compat_request_bytes[0..len];
}

/// Writes the length-prefixed ServerCompatResponse, with the port the server bound, to stdout.
const Listening = struct {
    io: std.Io,

    pub fn on_listening(listening: Listening, port: u16) !void {
        var message: [constants.compat_response_bytes]u8 = undefined;
        const response: server_compat.ServerCompatResponse = .{ .host = host, .port = port };
        const encoded = try proto.encode(server_compat.ServerCompatResponse, &response, &message);
        var prefix: [constants.length_prefix_len]u8 = undefined;
        std.mem.writeInt(u32, &prefix, @intCast(encoded.len), .big);
        var buffer: [constants.compat_response_bytes]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(listening.io, &buffer);
        try stdout.interface.writeAll(&prefix);
        try stdout.interface.writeAll(encoded);
        try stdout.interface.flush();
    }
};
