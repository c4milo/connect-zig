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
const colibri = @import("colibri");
const tls = @import("tls");
const server_compat = @import("connectrpc_conformance_v1_server_compat");
const constants = @import("constants.zig");
const App = @import("app.zig").App;
const Router = @import("service.zig").Router;

/// The types an Any in a JSON message may name (decision 21).
pub const protobuf_any_types = @import("any_types.zig").types;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (colibri decision 94).
    _ = @import("hooks.zig");
}

/// TCP connections alone: config.yaml declares no TLS, so the server serves no h3.
const Server = colibri.ServerOf(.{ .tcp_connections = constants.sockets_max, .quic_connections = 0 });

/// The server speaks cleartext, so no TLS session runs on this CPU description.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known },
    .timing = .not_stated,
};

var http_server: Server align(@alignOf(Server)) = undefined;
var router: Router align(@alignOf(Router)) = .{};
var app: App align(@alignOf(App)) = .{};
var gzip_decoder: connect.GzipDecoder align(@alignOf(connect.GzipDecoder)) = undefined;
var gzip_encoder: connect.GzipEncoder align(@alignOf(connect.GzipEncoder)) = undefined;
var zstd_decoder: connect.ZstdDecoder align(@alignOf(connect.ZstdDecoder)) = undefined;
var zstd_encoder: connect.ZstdEncoder align(@alignOf(connect.ZstdEncoder)) = undefined;
var compat_request_bytes: [constants.compat_request_bytes_max]u8 align(@alignOf(u64)) = undefined;
var compat_response_bytes: [constants.compat_response_bytes]u8 = undefined;
var stdin_buffer: [constants.length_prefix_len]u8 = undefined;
var stdout_buffer: [constants.compat_response_bytes]u8 = undefined;

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
    try http_server.init(.{
        .host = host,
        .port = 0,
        .cpu = cpu,
        .endpoint = .{ .timeouts = .{ .first_request_ns = constants.first_request_timeout_ns, .idle_ns = constants.idle_timeout_ns } },
    });
    defer http_server.deinit();
    try write_response(init.io, http_server.port());
    try http_server.run(&router, &app);
}

/// Reads the length-prefixed ServerCompatRequest from stdin.
fn read_request(io: std.Io) ![]const u8 {
    var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
    // docs/testing_servers.md: "a network-byte-order (i.e. big-endian) 32-bit integer".
    const len = try stdin.interface.takeInt(u32, .big);
    if (len > compat_request_bytes.len) return error.RequestTooLarge;
    try stdin.interface.readSliceAll(compat_request_bytes[0..len]);
    return compat_request_bytes[0..len];
}

/// Writes the length-prefixed ServerCompatResponse, with the port the server bound, to stdout.
fn write_response(io: std.Io, port: u16) !void {
    const response: server_compat.ServerCompatResponse = .{ .host = host, .port = port };
    const encoded = try proto.encode(server_compat.ServerCompatResponse, &response, &compat_response_bytes);
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout.interface.writeInt(u32, @intCast(encoded.len), .big);
    try stdout.interface.writeAll(encoded);
    try stdout.interface.flush();
}
