//! The server of the full-stack benchmark (design §8 step 28, decision 44): OTLP's
//! `TraceService/Export` on `colibri.Server`, h11 and h2 over TLS on a TCP socket, and h3 on the
//! UDP socket of the same port, under the test identity (decision 25). `tools/fullstack_check.sh`
//! loads it beside OpenTelemetry's Collector. Run it with `zig build run-otlp-sink -- [port]
//! [cleartext]`. Port 0 lets the kernel choose. With `cleartext` it serves h11 and h2 with no TLS,
//! and no h3, for the benchmark's cleartext climb. It prints `listening on port <port>`, and
//! serves until it is killed. `otlp-sink-compression` is the same program with room for more
//! calls at once, for the compression part (`constants.requests_compression`).
const std = @import("std");
const connect = @import("connect");
const server = @import("colibri").server;
const colibri = @import("colibri");
const platform = @import("stdx").platform;
const identity = @import("test_identity");
const sink_options = @import("sink_options");
const constants = @import("constants.zig");
const sink = @import("sink.zig");
const App = sink.App;

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

const Router = server.Router(App, .{
    .error_handler = on_error,
    .Values = sink.Values,
    .routes = sink.routes,
}, .{ .requests = if (sink_options.compression) constants.requests_compression else constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes, .header_bytes = 0 });

const Server = colibri.Server(.{ .tcp_connections = constants.tcp_connections, .quic_connections = constants.quic_connections }, .private);

/// All the program holds, which `main` allocates once before the first call (decision 42). The
/// production model sends gzip, as the Collector's otlp exporter does by default, so the sink
/// reads it. The compression part sends zstd and brotli too, through stdx's decoders.
const State = struct {
    http_server: Server,
    router: Router,
    app: App,
    gzip_decoder: connect.GzipDecoder,
    zstd_decoder: connect.ZstdDecoder,
    brotli_decoder: connect.BrotliDecoder,
    /// The TLS session of each connection over TLS (colibri decision 167). A sink in cleartext
    /// passes none, so this room stays untouched.
    tls_buffer: [server.Config.tls_buffer_len(constants.tcp_connections)]u8,
};

pub fn main(init: std.process.Init) !void {
    const command = try command_of(init);
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.router.init();
    // The CPU's features, taken once, for the routes, the decoders' fast paths and
    // protovalidate's (decision 10 as amended): one value of stdx's `platform.CpuFeatures`.
    const cpu_features: platform.CpuFeatures = .detect();
    state.app = .{ .codings = .{ .decoders = .{
        .gzip = &state.gzip_decoder,
        .zstd = &state.zstd_decoder,
        .brotli = &state.brotli_decoder,
    } }, .cpu_features = cpu_features };
    // On arm64 the program's one thread sets PSTATE.DIT where the core has FEAT_DIT, and stdx then
    // states its timing, so its sessions run AES-GCM, as the Collector's do. On x86-64 stdx states
    // it for every core. A program that serves real peers sets it only where it knows its thread
    // runs in that mode.
    const data_independent = platform.set_data_independent_timing(cpu_features, true);
    // The Unix time when the server starts, which its TLS session tickets carry.
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    // colibri serves h11 and h2 in cleartext, and no h3, when the server has no identity.
    const served: ?colibri.Identity = if (command.cleartext) null else .{ .chain = identity.chain_pem, .key = identity.key_pem };
    try state.http_server.init(&.{
        .port = command.port,
        .identity = served,
        .unix_seconds = unix_seconds,
        .engine = if (command.cleartext) .{ .cpu_features = cpu_features } else .{ .tls_buffer = &state.tls_buffer, .cpu_features = cpu_features },
    }, &state.router, &state.app);
    defer state.http_server.deinit();
    // A script that asked for port 0 reads the port from this line. The server makes its
    // `stdx.crypto` context of `engine.cpu_features` and the system's entropy (colibri decision
    // 175), and the first line says whether this thread set PSTATE.DIT.
    std.debug.print("cpu data_independent_timing_set {}\n", .{data_independent});
    std.debug.print("listening on port {d}\n", .{state.http_server.port()});
    try state.http_server.run();
}

/// What the command line names: the port, or `port_default`, and whether the server runs with no
/// TLS.
const Command = struct { port: u16, cleartext: bool };

fn command_of(init: std.process.Init) !Command {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const port_text = args.next() orelse return .{ .port = constants.port_default, .cleartext = false };
    const port = try std.fmt.parseInt(u16, port_text, constants.decimal);
    const mode = args.next() orelse return .{ .port = port, .cleartext = false };
    if (!std.mem.eql(u8, mode, "cleartext")) return error.ModeUnknown;
    return .{ .port = port, .cleartext = true };
}
