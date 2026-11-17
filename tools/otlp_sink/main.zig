//! The server of the full-stack benchmark (design §8 step 28, decision 44): OTLP's
//! `TraceService/Export` on `colibri.Server`, h11 and h2 over TLS on a TCP socket, and h3 on the
//! UDP socket of the same port, under the test identity (decision 25). `tools/fullstack_check.sh`
//! loads it beside OpenTelemetry's Collector. Run it with `zig build run-otlp-sink -- [port]`.
//! Port 0 lets the kernel choose. It prints `listening on port <port>`, and serves until it is
//! killed.
const std = @import("std");
const builtin = @import("builtin");
const server = @import("server");
const colibri = @import("colibri");
const tls = @import("tls");
const platform = @import("platform");
const identity = @import("test_identity");
const constants = @import("constants.zig");
const sink = @import("sink.zig");
const App = sink.App;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (colibri decision 94).
    _ = @import("hooks");
}

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = sink.routes,
}, .{ .requests = constants.requests, .response_bytes = constants.response_bytes, .body_bytes = constants.body_bytes, .header_bytes = 0 });

const Server = colibri.Server(.{ .tcp_connections = constants.tcp_connections, .quic_connections = constants.quic_connections }, .private);

/// All the program holds, which `main` allocates once before the first call (decision 42).
const State = struct {
    http_server: Server,
    router: Router,
    app: App,
};

pub fn main(init: std.process.Init) !void {
    const port = try port_of(init);
    const state = try init.arena.allocator().create(State);
    state.router = .{};
    state.app = .{};
    const cpu = probe();
    // The Unix time when the server starts, which its TLS session tickets carry.
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    try state.http_server.init(&.{
        .port = port,
        .identity = .{ .chain = identity.chain_pem, .key = identity.key_pem },
        .cpu = cpu,
        .unix_seconds = unix_seconds,
    }, &state.router, &state.app);
    defer state.http_server.deinit();
    // A script that asked for port 0 reads the port from this line, and the CPU line says which
    // TLS suites the sessions hold (colibri decision 97).
    std.debug.print("cpu aes_clmul {t}, timing {t}\n", .{ cpu.probe.aes_clmul, cpu.timing });
    std.debug.print("listening on port {d}\n", .{state.http_server.port()});
    try state.http_server.run();
}

/// stdx's probe of the CPU, and the mode of the program's one thread. On arm64 the program sets
/// PSTATE.DIT where the core has FEAT_DIT. It states the mode on every arm64 and x86-64 core, as
/// colibri's test programs do, so its sessions run AES-GCM, as the Collector's do. A program that
/// serves real peers states it only where it knows its thread runs in that mode.
fn probe() tls.Cpu {
    const found = platform.probe();
    const timing: tls.Timing = switch (builtin.cpu.arch) {
        .aarch64 => timing: {
            // Arm's `MSR DIT, #1` (FEAT_DIT), encoded so an assembler without the feature takes it.
            if (found.dit == .yes) asm volatile (".inst 0xd503415f" ::: .{ .memory = true });
            break :timing .data_independent;
        },
        .x86_64 => .data_independent,
        else => .not_stated,
    };
    return .{ .probe = found, .timing = timing };
}

/// The port the command line names, or `port_default`.
fn port_of(init: std.process.Init) !u16 {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const text = args.next() orelse return constants.port_default;
    return std.fmt.parseInt(u16, text, constants.decimal);
}
