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
/// A check program decodes and encodes with the build target's CPU features: it runs on the
/// machine it was built for, and a library takes the features its program detected.
const protobuf_decoder: proto.Decoder = .init(.target());
const colibri = @import("colibri");
const tls = @import("colibri").tls;
const server_compat = @import("connectrpc_conformance_v1_server_compat");
const constants = @import("constants.zig");
const App = @import("app.zig").App;
const Router = @import("service.zig").Router;

/// The types an Any in a JSON message may name (decision 21).
pub const protobuf_any_types = @import("any_types.zig").types;

/// TCP connections alone: config.yaml declares no TLS, so the server serves no h3.
const Server = colibri.Server(.{ .tcp_connections = constants.sockets_max, .quic_connections = 0 }, .private);

/// The server speaks cleartext, so no TLS session runs on this CPU description.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .sve2 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known, .midr = null },
    .timing = .not_stated,
};

/// All the program holds, which `main` allocates once before the server starts (decision 42).
const State = struct {
    http_server: Server,
    router: Router,
    app: App,
    /// The server reads gzip, zstd and br messages, and answers in the one a client accepts
    /// first.
    gzip_decoder: connect.GzipDecoder,
    gzip_encoder: connect.GzipEncoder,
    zstd_decoder: connect.ZstdDecoder,
    zstd_encoder: connect.ZstdEncoder,
    brotli_decoder: connect.BrotliDecoder,
    brotli_encoder: connect.BrotliEncoder,
    compat_request_bytes: [constants.compat_request_bytes_max]u8 align(@alignOf(u64)),
    compat_response_bytes: [constants.compat_response_bytes]u8,
    stdin_buffer: [constants.length_prefix_len]u8,
    stdout_buffer: [constants.compat_response_bytes]u8,
};

/// The host the runner's client connects to.
const host = "127.0.0.1";

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    const request_bytes = try read_request(init.io, state);
    const request = try protobuf_decoder.decode(server_compat.ServerCompatRequest, request_bytes);
    // config.yaml declares no TLS, so the runner never asks for it; a request for it fails here
    // rather than serving cleartext to a client that expects TLS.
    if (request.use_tls or request.client_tls_cert.len != 0) return error.TlsUnsupported;
    if (request.message_receive_limit > constants.message_bytes) return error.ReceiveLimitTooLarge;
    state.router.init();
    state.app = .{
        .cpu_features = .detect(),
        .message_receive_limit = request.message_receive_limit,
        .io = init.io,
        .codings = .{
            .decoders = .{ .gzip = &state.gzip_decoder, .zstd = &state.zstd_decoder, .brotli = &state.brotli_decoder },
            .encoders = .{ .gzip = &state.gzip_encoder, .zstd = &state.zstd_encoder, .brotli = &state.brotli_encoder },
        },
    };
    try state.http_server.init(&.{
        .host = host,
        .port = 0,
        .cpu = cpu,
        // colibri issues TLS session tickets with it; this server runs no TLS, so 0 serves.
        .unix_seconds = 0,
        .engine = .{ .cpu_features = state.app.cpu_features, .timeouts = .{ .first_request_ns = constants.first_request_timeout_ns, .idle_ns = constants.idle_timeout_ns } },
    }, &state.router, &state.app);
    defer state.http_server.deinit();
    try write_response(init.io, state, state.http_server.port());
    try state.http_server.run();
}

/// Reads the length-prefixed ServerCompatRequest from stdin.
fn read_request(io: std.Io, state: *State) ![]const u8 {
    var stdin = std.Io.File.stdin().reader(io, &state.stdin_buffer);
    // docs/testing_servers.md: "a network-byte-order (i.e. big-endian) 32-bit integer".
    const len = try stdin.interface.takeInt(u32, .big);
    if (len > state.compat_request_bytes.len) return error.RequestTooLarge;
    try stdin.interface.readSliceAll(state.compat_request_bytes[0..len]);
    return state.compat_request_bytes[0..len];
}

/// Writes the length-prefixed ServerCompatResponse, with the port the server bound, to stdout.
fn write_response(io: std.Io, state: *State, port: u16) !void {
    const response: server_compat.ServerCompatResponse = .{ .host = host, .port = port };
    const encoded = try proto.encode(server_compat.ServerCompatResponse, &response, &state.compat_response_bytes);
    var stdout = std.Io.File.stdout().writerStreaming(io, &state.stdout_buffer);
    try stdout.interface.writeInt(u32, @intCast(encoded.len), .big);
    try stdout.interface.writeAll(encoded);
    try stdout.interface.flush();
}
