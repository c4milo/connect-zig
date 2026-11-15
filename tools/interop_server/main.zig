//! The server that `tools/interop_languages_check.sh` runs the clients of interop/ against:
//! `interop.v1.InteropService` on `colibri.Server`, h11 and h2 over TLS on a TCP socket, and h3 on
//! the UDP socket of the same port, under the test identity (decision 25). Run it with `zig build
//! run-interop-server -- [port]`. Port 0 lets the kernel choose. It prints `listening on port
//! <port>`, and serves until it is killed.
const std = @import("std");
const connect = @import("connect");
const server = @import("server");
const colibri = @import("colibri");
const tls = @import("tls");
const rpc = @import("connect_colibri");
const identity = @import("test_identity");
const coverage = @import("coverage");
const interop = @import("interop");
const constants = @import("constants.zig");
const service = @import("interop.zig");
const App = @import("app.zig").App;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (colibri decision 94).
    _ = @import("hooks");
}

/// The types an Any in a JSON message may name: the coverage cases' (decision 21), which the
/// interop service echoes.
pub const protobuf_any_types: []const type = &.{ coverage.Everything, coverage.Nested, coverage.Scalars };

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

/// The router, with its pool. A method Connect does not serve gets 405, on every path.
const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = service.routes ++ rpc.Refusals(App, interop.InteropService.echo).routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes, .header_bytes = 0 });

const Server = colibri.Server(.{ .tcp_connections = constants.tcp_connections, .quic_connections = constants.quic_connections }, .private);

/// What a program probes once and passes every TLS configuration. This one probes nothing, so
/// each session runs ChaCha20 alone.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known },
    .timing = .not_stated,
};

/// All the program holds, which `main` allocates once before the first call (decision 42).
const State = struct {
    http_server: Server,
    router: Router,
    app: App,
    /// The server reads gzip and zstd messages, and answers in the one a client accepts first.
    gzip_decoder: connect.GzipDecoder,
    gzip_encoder: connect.GzipEncoder,
    zstd_decoder: connect.ZstdDecoder,
    zstd_encoder: connect.ZstdEncoder,
};

pub fn main(init: std.process.Init) !void {
    const port = try port_of(init);
    const state = try init.arena.allocator().create(State);
    state.router = .{};
    state.app = .{ .codings = .{
        .decoders = .{ .gzip = &state.gzip_decoder, .zstd = &state.zstd_decoder },
        .encoders = .{ .gzip = &state.gzip_encoder, .zstd = &state.zstd_encoder },
    } };
    // The Unix time when the server starts, which its TLS session tickets carry.
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    try state.http_server.init(&.{
        .port = port,
        .identity = .{ .chain = identity.chain_pem, .key = identity.key_pem },
        .cpu = cpu,
        .unix_seconds = unix_seconds,
    }, &state.router, &state.app);
    defer state.http_server.deinit();
    // A script that asked for port 0 reads the port from this line.
    std.debug.print("listening on port {d}\n", .{state.http_server.port()});
    try state.http_server.run();
}

fn port_of(init: std.process.Init) !u16 {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const text = args.next() orelse return constants.port_default;
    return std.fmt.parseInt(u16, text, constants.decimal);
}
