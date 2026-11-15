#!/bin/sh
# Builds and runs a small project that depends on connect-zig as a fetched package, as the
# README's "Use it in your project" writes it (decision 39). `zig fetch` keeps only the files that
# `.paths` of `build.zig.zon` names. So a file that the build needs and the list omits fails here,
# and nowhere else: each other check builds the whole tree.
# The project installs the plugin, runs `buf generate` with it, and builds a server and a client
# on the colibri modules connect-zig exports, on Rotor. The server presents the examples' test
# identity (decision 25): TLS on a TCP socket, and h3 on the UDP socket of the same port. The
# client trusts the test CA and calls the method in Connect and in gRPC, once over h2 and once
# over h3. curl calls it in JSON over h11, with TLS. `oidc` in the server also proves that
# connect-zig's request for chapulin equals colibri's: two requests that differ link two
# objects, and the link fails (decision 34). It needs the network, for the packages connect-zig
# depends on, buf (or `BUF` naming it) and curl.
set -eu
cd "$(dirname "$0")/.."
buf="${BUF:-buf}"
scratch="$(mktemp -d)"
server_pid=""
trap '[ -n "${server_pid}" ] && kill "${server_pid}" 2>/dev/null; rm -rf "${scratch}"' EXIT
# The tracked files, as the working tree holds them.
git ls-files -z | tar --null -T - -czf "${scratch}/connect-zig.tar.gz"
project="${scratch}/project"
mkdir -p "${project}/src" "${project}/proto/greet/v1" "${project}/tls"
# The test identity, which the fetched package does not hold. Its module embeds the PEM files.
for file in ca.pem chain.pem key.pem identity.zig; do
    cp "examples/testdata/tls/${file}" "${project}/tls/${file}"
done
cat > "${project}/build.zig.zon" <<'ZON'
.{
    .name = .project,
    .version = "0.0.0",
    .fingerprint = 0x2fb3d0eea704f920,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src", "proto", "gen", "tls" },
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
    const identity = b.createModule(.{ .root_source_file = b.path("tls/identity.zig") });
    const names = [_][]const u8{ "protobuf", "connect", "connect_colibri", "oidc", "server", "client", "tls", "colibri" };
    for ([_][]const u8{ "server", "client" }) |program_name| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{program_name})),
            .target = target,
            .optimize = .Debug,
        });
        for (names) |name| module.addImport(name, connect_zig.module(name));
        module.addImport("greet_v1", greet);
        module.addImport("test_identity", identity);
        b.installArtifact(b.addExecutable(.{ .name = b.fmt("greet-{s}", .{program_name}), .root_module = module }));
    }
}
ZIG
# Each global below states its alignment: Zig 0.16's x86_64 backend, which builds Debug on x86-64,
# can place a global off its type's alignment otherwise (pepegrillo's static-alignment rule).
cat > "${project}/src/hooks.zig" <<'ZIG'
const std = @import("std");

/// chapulin's one hook, which a program that links colibri's `tls` defines.
export fn ch_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}
ZIG
cat > "${project}/src/server.zig" <<'ZIG'
//! GreetService on `colibri.Server`, under the test identity: h11 and h2 over TLS on the TCP port
//! it is given, and h3 on the UDP socket of the same port. Port 0 lets the kernel choose. It
//! prints `listening on port <port>`, and serves until it is killed.
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const server = @import("server");
const colibri = @import("colibri");
const tls = @import("tls");
const oidc = @import("oidc");
const greet_v1 = @import("greet_v1");
const identity = @import("test_identity");
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

const Server = colibri.Server(.{ .tcp_connections = 8, .quic_connections = 8 }, .private);

/// The CPU, which this program does not probe, so each TLS session runs ChaCha20 alone.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known },
    .timing = .not_stated,
};

var http_server: Server align(@alignOf(Server)) = undefined;
var router: Router align(@alignOf(Router)) = .{};
var state: App align(@alignOf(App)) = .{};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const port = try std.fmt.parseInt(u16, args.next() orelse "0", 10);
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    // A call into chapulin through `oidc`, in a program that links colibri's chapulin too.
    try state.oidc.init(&.{ .issuer = "https://issuer.example", .audience = "project" });
    std.debug.assert(state.oidc.keys_stale());
    try http_server.init(&.{
        .port = port,
        .identity = .{ .chain = identity.chain_pem, .key = identity.key_pem },
        .cpu = cpu,
        .unix_seconds = unix_seconds,
    }, &router, &state);
    defer http_server.deinit();
    std.debug.print("listening on port {d}\n", .{http_server.port()});
    try http_server.run();
}
ZIG
cat > "${project}/src/client.zig" <<'ZIG'
//! Calls Greet on the server at the port it is given, over TLS under the test CA: in Connect and
//! in gRPC, in a round over h2 and in a round over h3. Each round runs `connect_colibri`'s
//! `ClientCall` on a `colibri.Client` of its own. It exits with an error unless every answer is
//! right and each round spoke its protocol.
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const client = @import("client");
const colibri = @import("colibri");
const tls = @import("tls");
const greet_v1 = @import("greet_v1");
const identity = @import("test_identity");
const Service = greet_v1.GreetService;

comptime {
    _ = @import("hooks.zig");
}

const Client = colibri.Client(.{}, .private);
const GreetCall = rpc.ClientCall(Service.greet, .{});

const calls_count = 2;
const buffer_len = 4096;
const entries_max = 8;
const greeting = "Hello, Ada";

const loopback = [_]u8{ 127, 0, 0, 1 };
const addresses = [_]client.Address{.of(&loopback, 0)};

/// Room for the DER of the CA bundle, and its one anchor.
const anchor_der_len = identity.ca_pem.len / 4 * 3;
const anchors_max = 1;

/// The CPU, which this program does not probe, so each TLS session runs ChaCha20 alone.
const cpu: tls.Cpu = .{
    .probe = .{ .aes_clmul = .not_known, .dit = .not_known, .sha256 = .not_known, .sha512 = .not_known, .sha3 = .not_known, .ssse3 = .not_known, .sse4_1 = .not_known, .avx2 = .not_known, .vaes = .not_known },
    .timing = .not_stated,
};

/// Each round's protocols, and the one it must speak: h2 over TLS on TCP, then h3 on QUIC.
const Round = struct { protocols: client.Protocols, expected: client.Protocol };
const rounds = [_]Round{
    .{ .protocols = .{ .h11 = false, .h3 = false }, .expected = .h2 },
    .{ .protocols = .{ .h11 = false, .h2 = false }, .expected = .h3 },
};

/// Notes the protocol of the round's connection, and ends the round once both calls finished.
const Handler = struct {
    finished: u32 = 0,
    spoken: ?client.Protocol = null,

    pub fn on_connected(self: *Handler, _: *Client, connected: client.Connected) void {
        self.spoken = connected.protocol;
    }

    pub fn on_finished(self: *Handler, running: *Client, _: client.Finished) void {
        self.finished += 1;
        if (self.finished == calls_count) running.shutdown();
    }
};

var clients: [rounds.len]Client align(@alignOf(Client)) = undefined;
var handlers: [rounds.len]Handler align(@alignOf(Handler)) = .{ Handler{}, Handler{} };
var calls: [calls_count]GreetCall align(@alignOf(GreetCall)) = undefined;
var call_buffers: [calls_count][7][buffer_len]u8 = undefined;
var read_buffers: [4][buffer_len]u8 = undefined;
var details: [entries_max]connect.Detail align(@alignOf(connect.Detail)) = undefined;
var metadata: [entries_max]connect.Header align(@alignOf(connect.Header)) = undefined;
var anchor_der: [anchor_der_len]u8 = undefined;
var anchor_room: [anchors_max]tls.Anchor align(@alignOf(tls.Anchor)) = undefined;

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

fn run_round(running: *Client, handler: *Handler, round: Round, trust: tls.Trust, port: u16, unix_seconds: u64) !void {
    try running.init(&.{
        .destination = .{ .addresses = &addresses, .port = port },
        .pool = .{ .tls = .{ .trust = trust, .cpu = cpu }, .authority = identity.server_name, .protocols = round.protocols },
        .unix_seconds = unix_seconds,
    }, handler);
    defer running.deinit();
    try calls[0].init(&.{}, &.{.{ .name = "Ada" }}, &buffers(&call_buffers[0]));
    try calls[1].init(&.{ .protocol = .grpc }, &.{.{ .name = "Ada" }}, &buffers(&call_buffers[1]));
    for (&calls) |*call| _ = try running.request(&call.request, &call.response);
    try running.run();
    if (handler.spoken != round.expected) return error.ProtocolWrong;
    for (&calls) |*call| {
        var response = call.read(storage());
        const answer = try response.next(greet_v1.GreetResponse) orelse return error.CallWrong;
        if (response.failure != null) return error.CallWrong;
        if (!std.mem.eql(u8, answer.greeting, greeting)) return error.CallWrong;
    }
    std.debug.print("the client read both answers over {s}, in Connect and in gRPC\n", .{@tagName(round.expected)});
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.PortMissing, 10);
    // The client judges the server's chain at this instant (RFC 5280 §4.1.2.5).
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    const anchors = try tls.pem.anchors(identity.ca_pem, &anchor_der, &anchor_room);
    const trust: tls.Trust = .{ .web_pki = .{ .anchors = anchors, .server_name = identity.server_name } };
    for (&clients, &handlers, rounds) |*running, *handler, round| {
        try run_round(running, handler, round, trust, port, unix_seconds);
    }
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
answer="$(curl -sS --http1.1 --cacert tls/ca.pem --json '{"name":"Ada"}' "https://127.0.0.1:${port}/greet.v1.GreetService/Greet")"
if [ "${answer}" != '{"greeting":"Hello, Ada"}' ]; then
    echo "curl read ${answer}" >&2
    exit 1
fi
kill "${server_pid}"
wait "${server_pid}" 2>/dev/null || true
server_pid=""
echo "connect-zig builds as a fetched package, and its server and client answer each other"
