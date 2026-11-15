#!/bin/sh
# Builds and runs a small project that depends on connect-zig as a fetched package, as the
# README's "Use it in your project" writes it (decision 39). `zig fetch` keeps only the files that
# `.paths` of `build.zig.zon` names. So a file that the build needs and the list omits fails here,
# and nowhere else: each other check builds the whole tree.
# The project installs the plugin, runs `buf generate` with it, and builds a server and a client
# on the colibri modules connect-zig exports, on Rotor. The server serves one method over TCP in
# cleartext. The client calls it in Connect and in gRPC over h2, and curl calls it in JSON over
# h11. `oidc` in the server also proves that connect-zig's request for chapulin equals colibri's:
# two requests that differ link two objects, and the link fails (decision 34). It needs the
# network, for the packages connect-zig depends on, buf (or `BUF` naming it) and curl.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
scratch="$(mktemp -d)"
server_pid=""
trap '[ -n "${server_pid}" ] && kill "${server_pid}" 2>/dev/null; rm -rf "${scratch}"' EXIT
# The tracked files, as the working tree holds them.
git ls-files -z | tar --null -T - -czf "${scratch}/connect-zig.tar.gz"
project="${scratch}/project"
mkdir -p "${project}/src" "${project}/proto/greet/v1"
cat > "${project}/build.zig.zon" <<'ZON'
.{
    .name = .project,
    .version = "0.0.0",
    .fingerprint = 0x2fb3d0eea704f920,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src", "proto", "gen" },
}
ZON
cat > "${project}/buf.gen.yaml" <<'YAML'
version: v2
inputs:
  - directory: proto
plugins:
  - local: zig-out/bin/protoc-gen-connect-zig
    out: gen
YAML
cat > "${project}/proto/greet/v1/greet.proto" <<'PROTO'
syntax = "proto3";

package greet.v1;

message GreetRequest {
  string name = 1;
}

message GreetResponse {
  string greeting = 1;
}

service GreetService {
  rpc Greet(GreetRequest) returns (GreetResponse) {}
}
PROTO
cat > "${project}/build.zig" <<'ZIG'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .rotor = true });
    // The plugin alone, which `buf generate` runs before the programs can build.
    const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
    b.step("plugin", "Install protoc-gen-connect-zig alone").dependOn(&plugin.step);
    b.getInstallStep().dependOn(&plugin.step);
    const greet = b.createModule(.{ .root_source_file = b.path("gen/greet/v1/greet.pb.zig") });
    greet.addImport("protobuf", connect_zig.module("protobuf"));
    greet.addImport("connect", connect_zig.module("connect"));
    const names = [_][]const u8{ "protobuf", "connect", "connect_colibri", "oidc", "server", "client", "tls", "colibri" };
    for ([_][]const u8{ "server", "client" }) |program_name| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{program_name})),
            .target = target,
            .optimize = .Debug,
        });
        for (names) |name| module.addImport(name, connect_zig.module(name));
        module.addImport("greet_v1", greet);
        b.installArtifact(b.addExecutable(.{ .name = b.fmt("greet-{s}", .{program_name}), .root_module = module }));
    }
}
ZIG
cat > "${project}/src/hooks.zig" <<'ZIG'
const std = @import("std");

/// chapulin's one hook, which a program that links colibri's `tls` defines.
export fn ch_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}
ZIG
cat > "${project}/src/server.zig" <<'ZIG'
//! GreetService on `colibri.Server`: h11 and h2 in cleartext on the TCP port it is given, 0 for
//! one the kernel chooses. It prints `listening on port <port>`, and serves until it is killed.
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const server = @import("server");
const colibri = @import("colibri");
const tls = @import("tls");
const oidc = @import("oidc");
const greet_v1 = @import("greet_v1");
const Service = greet_v1.GreetService;

comptime {
    _ = @import("hooks.zig");
}

const App = struct {
    text: [256]u8 = undefined,
    oidc: oidc.Verifier = undefined,
};

pub fn greet(app: *App, _: *rpc.Context, request: *const rpc.Request(greet_v1.GreetRequest), response: *rpc.Response(greet_v1.GreetResponse)) ?connect.RpcError {
    if (request.message.name.len == 0) return .{ .code = .invalid_argument, .message = "name someone" };
    response.message.greeting = std.fmt.bufPrint(&app.text, "Hello, {s}", .{request.message.name}) catch {
        return .{ .code = .resource_exhausted, .message = "name too long" };
    };
    return null;
}

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

const route_options: rpc.RouteOptions = .{ .message_bytes = 4096 };

const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = Service.Routes(rpc, App, @This(), route_options).routes,
}, .{ .requests = 8, .body_bytes = 8192, .response_bytes = 8192 });

const Server = colibri.Server(.{ .tcp_connections = 8, .quic_connections = 0 }, .private);

/// A server with no identity runs no TLS session, so it probes nothing.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known },
    .timing = .not_stated,
};

var http_server: Server = undefined;
var router: Router = .{};
var state: App = .{};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const port = try std.fmt.parseInt(u16, args.next() orelse "0", 10);
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    // A call into chapulin through `oidc`, in a program that links colibri's chapulin too.
    try state.oidc.init(&.{ .issuer = "https://issuer.example", .audience = "project" });
    std.debug.assert(state.oidc.keys_stale());
    try http_server.init(&.{ .port = port, .cpu = cpu, .unix_seconds = unix_seconds }, &router, &state);
    defer http_server.deinit();
    std.debug.print("listening on port {d}\n", .{http_server.port()});
    try http_server.run();
}
ZIG
cat > "${project}/src/client.zig" <<'ZIG'
//! Calls Greet on the server at the port it is given, over h2 in cleartext: once in Connect and
//! once in gRPC, with `connect_colibri`'s `ClientCall` on `colibri.Client`. It exits with an
//! error unless both answers are right.
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const client = @import("client");
const colibri = @import("colibri");
const greet_v1 = @import("greet_v1");
const Service = greet_v1.GreetService;

comptime {
    _ = @import("hooks.zig");
}

const Client = colibri.Client(.{ .quic = false }, .private);
const GreetCall = rpc.ClientCall(Service.greet, .{});

const calls_count = 2;
const buffer_len = 4096;
const entries_max = 8;
const greeting = "Hello, Ada";

const loopback = [_]u8{ 127, 0, 0, 1 };
const addresses = [_]client.Address{.of(&loopback, 0)};

/// Ends the client's run once both calls finished.
const Handler = struct {
    finished: u32 = 0,

    pub fn on_finished(self: *Handler, running: *Client, _: client.Finished) void {
        self.finished += 1;
        if (self.finished == calls_count) running.shutdown();
    }
};

var colibri_client: Client = undefined;
var handler: Handler = .{};
var calls: [calls_count]GreetCall = undefined;
var call_buffers: [calls_count][7][buffer_len]u8 = undefined;
var read_buffers: [4][buffer_len]u8 = undefined;
var details: [entries_max]connect.Detail = undefined;
var metadata: [entries_max]connect.Header = undefined;

fn buffers(set: *[7][buffer_len]u8) rpc.ClientCallBuffers {
    return .{
        .request = .{ .body = &set[0], .scratch = .{ .message = &set[1], .work = &set[2], .tokens = &.{} }, .values = &set[3] },
        .headers = &set[4],
        .trailers = &set[5],
        .body = &set[6],
    };
}

fn storage() connect.client.Storage {
    return .{
        .scratch = .{ .message = &read_buffers[0], .work = &read_buffers[1], .tokens = &read_buffers[2] },
        .octets = &read_buffers[3],
        .details = &details,
        .metadata = &metadata,
    };
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.PortMissing, 10);
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    try colibri_client.init(&.{
        .destination = .{ .addresses = &addresses, .port = port },
        .pool = .{ .authority = "127.0.0.1", .protocols = .{ .h11 = false, .h3 = false } },
        .unix_seconds = unix_seconds,
    }, &handler);
    defer colibri_client.deinit();
    try calls[0].init(&.{}, &.{.{ .name = "Ada" }}, &buffers(&call_buffers[0]));
    try calls[1].init(&.{ .protocol = .grpc }, &.{.{ .name = "Ada" }}, &buffers(&call_buffers[1]));
    for (&calls) |*call| _ = try colibri_client.request(&call.request, &call.response);
    try colibri_client.run();
    for (&calls) |*call| {
        var response = call.read(storage());
        const answer = try response.next(greet_v1.GreetResponse) orelse return error.CallWrong;
        if (response.failure != null) return error.CallWrong;
        if (!std.mem.eql(u8, answer.greeting, greeting)) return error.CallWrong;
    }
    std.debug.print("the client read both answers, in Connect and in gRPC\n", .{});
}
ZIG
cd "${project}"
zig fetch --save=connect_zig "file://${scratch}/connect-zig.tar.gz"
zig build plugin
test -x zig-out/bin/protoc-gen-connect-zig
"${buf}" generate
zig build
zig-out/bin/greet-server 0 2>"${scratch}/server.log" &
server_pid=$!
# The server's first line names its port. 100 tries of 0.1 s wait 10 s at most.
port=""
for _ in $(seq 1 100); do
    port="$(sed -n 's/^listening on port \([0-9][0-9]*\)$/\1/p' "${scratch}/server.log")"
    [ -n "${port}" ] && break
    sleep 0.1
done
if [ -z "${port}" ]; then
    cat "${scratch}/server.log" >&2
    echo "the server printed no port" >&2
    exit 1
fi
zig-out/bin/greet-client "${port}"
answer="$(curl -sS --http1.1 --json '{"name":"Ada"}' "http://127.0.0.1:${port}/greet.v1.GreetService/Greet")"
if [ "${answer}" != '{"greeting":"Hello, Ada"}' ]; then
    echo "curl read ${answer}" >&2
    exit 1
fi
kill "${server_pid}"
wait "${server_pid}" 2>/dev/null || true
server_pid=""
echo "connect-zig builds as a fetched package, and its server and client answer each other"
