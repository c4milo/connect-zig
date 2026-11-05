//! Example: the ELIZA and demo services on Rotor's loop: h11 and h2 on a TCP socket, in
//! cleartext, and h3 on the UDP socket of the same port, under the test-only identity of
//! `examples/testdata/tls` (decision 28). Run it with `zig build run-eliza-server -- [port]`,
//! then call it with any Connect, gRPC or gRPC-Web client:
//!
//! ```sh
//! curl -sS --json '{"sentence":"I feel tired"}' \
//!   http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
//! buf curl --http2-prior-knowledge --protocol grpc --schema examples/proto \
//!   -d '{"name":"Ada"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Introduce
//! buf curl --http3 --cacert examples/testdata/tls/ca.pem --schema examples/proto \
//!   -d '{"sentence":"hi"}' https://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
//! ```
//!
//! The socket loop lives in `services/socket_loop.zig`, which the conformance server shares
//! (decision 26). This program places it, the TLS identity of its h3 socket, and the codings the
//! services read and write.
const std = @import("std");
const connect = @import("connect");
const tls = @import("tls");
const identity = @import("test_identity");
const socket_loop = @import("socket_loop");
const App = @import("services/app.zig").App;
const Router = @import("services/routes.zig").Router;

const port_default = 8080;

const Server = socket_loop.SocketServer(App, Router, .{ .sockets_max = 8, .socket_buffer_len = 64 * 1024, .quic_connections = 8 });

/// Room for the DER of the chain: a PEM file's DER is at most three quarters of its length.
const chain_der_len = identity.chain_pem.len / 4 * 3;
/// What a program probes once and passes every TLS configuration. This one probes nothing, so
/// each session runs ChaCha20 alone; a program that depends on stdx calls its `probe()` instead.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known },
    .timing = .not_stated,
};

var socket_server: Server align(@alignOf(Server)) = .{};
var app: App align(@alignOf(App)) = .{};
/// The server reads gzip messages and writes them when a client accepts gzip.
var gzip_decoder: connect.GzipDecoder align(@alignOf(connect.GzipDecoder)) = undefined;
var gzip_encoder: connect.GzipEncoder align(@alignOf(connect.GzipEncoder)) = undefined;
/// The same for zstd, which the server answers in when a client lists it before gzip.
var zstd_decoder: connect.ZstdDecoder align(@alignOf(connect.ZstdDecoder)) = undefined;
var zstd_encoder: connect.ZstdEncoder align(@alignOf(connect.ZstdEncoder)) = undefined;
/// The h3 socket's TLS identity and keys, which the endpoint borrows while it serves.
var chain_der: [chain_der_len]u8 = undefined;
var chain_room: [tls.constants.limits.certificate_chain_len_max][]const u8 = undefined;
var key: tls.Key align(@alignOf(tls.Key)) = .{};
var identities: [1]tls.Identity align(@alignOf(tls.Identity)) = undefined;
var cookie_key: [tls.constants.protocol.server_key_len]u8 = undefined;
var ticket_key: [tls.constants.protocol.server_key_len]u8 = undefined;
/// The `std.Io` whose entropy every TLS session draws from.
var entropy_io: std.Io align(@alignOf(std.Io)) = undefined;

/// Prints the port the server bound, which a script reads when it asked for port 0.
const Listening = struct {
    pub fn on_listening(_: Listening, port: u16) !void {
        std.debug.print("listening on port {d}\n", .{port});
    }
};

pub fn main(init: std.process.Init) !void {
    // The key's scalar is wiped once the server stops, whether or not it was read.
    defer key.wipe();
    const port = try port_of(init);
    app.codings = .{
        .decoders = .{ .gzip = &gzip_decoder, .zstd = &zstd_decoder },
        .encoders = .{ .gzip = &gzip_encoder, .zstd = &zstd_encoder },
    };
    try use_identity(init.io);
    try socket_server.serve(&app, port, Listening{});
}

/// Gives the h3 socket the test identity, and the endpoint the operating system's entropy and
/// clock: colibri reads neither (colibri decision 94).
fn use_identity(io: std.Io) !void {
    entropy_io = io;
    io.random(&cookie_key);
    io.random(&ticket_key);
    // The chain, the end-entity first, and the P-256 key the end-entity certificate carries.
    const chain = try tls.pem.chain(identity.chain_pem, &chain_der, &chain_room);
    try tls.pem.key(cpu, identity.key_pem, chain[0], &key);
    identities[0] = .{ .chain = chain, .key = &key };
    socket_server.config.tls = .{ .identities = &identities, .cookie_key = &cookie_key, .ticket_key = &ticket_key, .cpu = cpu };
    socket_server.random = .{ .ptr = &entropy_io, .fillFn = fill_from_io };
    socket_server.now_seconds = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
}

fn fill_from_io(context: *anyopaque, octets: []u8) void {
    const io: *std.Io = @ptrCast(@alignCast(context));
    io.random(octets);
}

fn port_of(init: std.process.Init) !u16 {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const text = args.next() orelse return port_default;
    return std.fmt.parseInt(u16, text, 10);
}
