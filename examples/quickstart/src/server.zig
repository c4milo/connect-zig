//! The README's server, as a program: GreetService on `colibri.Server`, h11 and h2 over TLS on a
//! TCP socket and h3 on the UDP socket of the same port.
//!
//! ```sh
//! greet-server <port> <chain.pem> <key.pem>
//! ```
//!
//! The chain is the server's certificate first, then each certificate that signs it. Port 0 lets
//! the kernel choose. The server prints `listening on port <port>`, and serves until it is
//! killed.
const std = @import("std");
const connect_zig = @import("connect_zig");
const CpuFeatures = connect_zig.CpuFeatures;
const connect = connect_zig.connect;
const rpc = connect_zig.connect_colibri;
const server = connect_zig.colibri.server;
const colibri = connect_zig.colibri;
const tls = connect_zig.colibri.tls;
const oidc = connect_zig.oidc;
const greet_v1 = @import("greet_v1");
const constants = @import("constants.zig");
const Service = greet_v1.GreetService;

pub const Error = error{ArgumentMissing};

/// What the routes read. The verifier is never asked for a token here: its `init` is a call into
/// chapulin through `oidc`, in a program that links colibri's chapulin too, so the build proves
/// that both ask for one chapulin object (decision 34).
const App = struct {
    /// The CPU features the routes read and write each message with, stdx's type. The program
    /// detects them once, as it starts.
    cpu_features: CpuFeatures,
    text: [constants.greeting_len_max]u8 = undefined,
    oidc: oidc.Verifier = undefined,
};

/// Greet answers a name with a greeting. The handler of each method has the method's name.
pub fn greet(app: *App, _: *rpc.Context, request: *const rpc.Request(greet_v1.GreetRequest), response: *rpc.Response(greet_v1.GreetResponse)) ?connect.RpcError {
    if (request.message.name.len == 0) return .{ .code = .invalid_argument, .message = "name someone" };
    response.message.greeting = std.fmt.bufPrint(&app.text, "Hello, {s}", .{request.message.name}) catch {
        return .{ .code = .resource_exhausted, .message = "name too long" };
    };
    return null;
}

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

const route_options: rpc.RouteOptions = .{ .message_bytes = constants.message_bytes };

const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = Service.Routes(rpc, App, @This(), route_options).routes,
}, .{ .requests = constants.requests, .body_bytes = constants.body_bytes, .response_bytes = constants.response_bytes, .header_bytes = 0 });

const Server = colibri.Server(.{ .tcp_connections = constants.tcp_connections, .quic_connections = constants.quic_connections }, .private);

/// The CPU, which this program does not probe, so each TLS session runs ChaCha20 alone. A
/// program that depends on stdx calls its `probe()` instead.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .sve2 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known, .midr = null },
    .timing = .not_stated,
};

/// All the program holds, which `main` allocates once before the first call (decision 42).
const State = struct {
    http_server: Server,
    router: Router,
    app: App,
    chain_pem: [constants.pem_len_max]u8,
    key_pem: [constants.pem_len_max]u8,
    /// The TLS session of each TCP connection: about 83 KB each (colibri decision 167).
    tls_buffer: [server.Config.tls_buffer_len(constants.tcp_connections)]u8,
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.ArgumentMissing, constants.decimal);
    const chain_path = args.next() orelse return error.ArgumentMissing;
    const key_path = args.next() orelse return error.ArgumentMissing;
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.router.init();
    // The program detects the CPU's features once, as it starts.
    state.app = .{ .cpu_features = .detect() };
    const cwd = std.Io.Dir.cwd();
    const chain = try cwd.readFile(init.io, chain_path, &state.chain_pem);
    const key = try cwd.readFile(init.io, key_path, &state.key_pem);
    try state.app.oidc.init(&.{ .issuer = "https://issuer.example", .audience = "quickstart", .cpu_features = state.app.cpu_features });
    std.debug.assert(state.app.oidc.keys_stale());
    // The Unix time when the server starts, which its TLS session tickets carry.
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    try state.http_server.init(&.{
        .port = port,
        .identity = .{ .chain = chain, .key = key },
        .cpu = cpu,
        .unix_seconds = unix_seconds,
        .engine = .{ .tls_buffer = &state.tls_buffer, .cpu_features = state.app.cpu_features },
    }, &state.router, &state.app);
    defer state.http_server.deinit();
    std.debug.print("listening on port {d}\n", .{state.http_server.port()});
    try state.http_server.run();
}
