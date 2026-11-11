//! Example: the ELIZA, demo, GitHub-style and interop services on a socket, through
//! `colibri.Server` (colibri decision 150): h11 and h2 on a TCP socket, in cleartext, and h3 on
//! the UDP socket of the same port, under the test-only identity of `examples/testdata/tls`
//! (decision 28). Run it with `zig build run-eliza-server -- [port]`, then call it with any
//! Connect, gRPC or gRPC-Web client:
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
//! colibri binds, reads the identity, draws the TLS sessions' entropy from the system and runs
//! Rotor's loop. This program gives it the route table, the services' state and the codings they
//! read and write.
const std = @import("std");
const connect = @import("connect");
const colibri = @import("colibri");
const tls = @import("tls");
const identity = @import("test_identity");
const coverage = @import("coverage");
const App = @import("services/app.zig").App;
const Router = @import("services/routes.zig").Router;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (colibri decision 94).
    _ = @import("services/hooks.zig");
}

const port_default = 8080;

/// The types an Any in a JSON message may name: the coverage cases' (decision 21), which the
/// interop service echoes.
pub const protobuf_any_types: []const type = &.{ coverage.Everything, coverage.Nested, coverage.Scalars };

/// 64 TCP connections and 8 QUIC connections at once. A connection past them is accepted and
/// closed, so its client learns it at once.
const Server = colibri.Server(.{ .tcp_connections = 64, .quic_connections = 8 }, .private);

/// What a program probes once and passes every TLS configuration. This one probes nothing, so
/// each session runs ChaCha20 alone; a program that depends on stdx calls its `probe()` instead.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known },
    .timing = .not_stated,
};

var http_server: Server align(@alignOf(Server)) = undefined;
var router: Router align(@alignOf(Router)) = .{};
var app: App align(@alignOf(App)) = .{};
/// The server reads gzip messages and writes them when a client accepts gzip.
var gzip_decoder: connect.GzipDecoder align(@alignOf(connect.GzipDecoder)) = undefined;
var gzip_encoder: connect.GzipEncoder align(@alignOf(connect.GzipEncoder)) = undefined;
/// The same for zstd, which the server answers in when a client lists it before gzip.
var zstd_decoder: connect.ZstdDecoder align(@alignOf(connect.ZstdDecoder)) = undefined;
var zstd_encoder: connect.ZstdEncoder align(@alignOf(connect.ZstdEncoder)) = undefined;

/// The seconds since 1970, from the real-time clock: never before it.
fn unix_seconds(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.real.now(io).toSeconds(), 0));
}

pub fn main(init: std.process.Init) !void {
    const port = try port_of(init);
    app.codings = .{
        .decoders = .{ .gzip = &gzip_decoder, .zstd = &zstd_decoder },
        .encoders = .{ .gzip = &gzip_encoder, .zstd = &zstd_encoder },
    };
    try http_server.init(&.{
        .host = "127.0.0.1",
        .port = port,
        .identity = .{ .chain = identity.chain_pem, .key = identity.key_pem },
        .cpu = cpu,
        // The Unix time when the server starts, which its TLS session tickets carry.
        .unix_seconds = unix_seconds(init.io),
    }, &router, &app);
    defer http_server.deinit();
    // A script that asked for port 0 reads the port from this line.
    std.debug.print("listening on port {d}\n", .{http_server.port()});
    try http_server.run();
}

fn port_of(init: std.process.Init) !u16 {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const text = args.next() orelse return port_default;
    return std.fmt.parseInt(u16, text, 10);
}
