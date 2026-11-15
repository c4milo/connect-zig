# connect-zig

[![CI](https://github.com/c4milo/connect-zig/actions/workflows/main.yml/badge.svg)](https://github.com/c4milo/connect-zig/actions/workflows/main.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16.0-f7a41d.svg)](https://ziglang.org/download/#release-0.16.0)
[![Connect conformance: 2714 of 2714 server cases, 8264 of 8264 client cases](https://img.shields.io/badge/connect_conformance-passing-brightgreen.svg)](https://github.com/c4milo/connect-zig/actions/runs/43746293217)
[![Line coverage: 97.6%](https://img.shields.io/badge/line_coverage-97.6%25-brightgreen.svg)](https://github.com/c4milo/connect-zig/actions/runs/43680656658)

**[Connect RPC](https://connectrpc.com/) for Zig.** Write a `.proto` file, run `buf generate`,
and serve the same handlers to Connect, gRPC and gRPC-Web clients, in binary protobuf or JSON.

- **Conformant.** It passes [connectrpc's conformance suite](https://github.com/connectrpc/conformance)
  v1.0.4 in Connect, gRPC and gRPC-Web: all 2714 server cases, and all 8264 client cases.
- **No allocator in the library.** Every buffer is yours, and every size is a constant you can
  read.
- **No copies.** Decoding leaves strings, bytes and repeated fields pointing into the input, and
  each message is encoded straight into the HTTP body it goes out in.
- **No hidden I/O.** The protocol core reads bytes you give it and writes bytes you send. It
  reads no clock, so every test is deterministic.
- **Fast.** Binary and JSON encoding and decoding run 2.4 to 24 times faster than Go's protobuf
  runtime on x86-64, and 2.3 to 32 times on arm64 (see [Performance](#performance)).
- **HTTP from [colibri](https://github.com/c4milo/colibri).** Servers and clients run over h11,
  h2 and h3, in cleartext or over TLS.

## Try it in 30 seconds

You need [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0) and curl.

```sh
git clone https://github.com/c4milo/connect-zig && cd connect-zig
zig build run-eliza-server -- 8080
```

In a second terminal, talk to [ELIZA](https://en.wikipedia.org/wiki/ELIZA):

```sh
curl --cacert examples/harness/tls/ca.pem --json '{"sentence":"I feel tired"}' \
  https://localhost:8080/connectrpc.eliza.v1.ElizaService/Say
```

```json
{"sentence":"You said \"I feel tired\". How does that make you feel?"}
```

The same server answers [`buf curl`](https://buf.build/docs/reference/cli/buf/curl) in every
protocol, over h2 or, with `--http3`, h3. Try `--protocol grpc` or `--protocol grpcweb`:

```sh
buf curl --cacert examples/harness/tls/ca.pem --protocol grpc --schema examples/eliza/proto \
  -d '{"name":"Ada"}' https://localhost:8080/connectrpc.eliza.v1.ElizaService/Introduce
```

## What's inside

| Module | What it does |
| --- | --- |
| `protobuf` | The binary encoding and the proto3 JSON mapping, over generated structs. |
| `connect` | The Connect, gRPC and gRPC-Web rules, as functions over headers and bytes. |
| `connect_colibri` | Routes for colibri's server, and calls for colibri's client. Programs import it as `rpc`. |
| `oidc` | The check of an OpenID Connect bearer token, and a server interceptor that requires one. |
| `protoc-gen-connect-zig` | The plugin `buf generate` runs to write your `.pb.zig` files. |

### What works today

| | Connect | gRPC | gRPC-Web |
| --- | :---: | :---: | :---: |
| Server: unary, all streams | ✅ | ✅ | ✅ |
| Client: unary, all streams | ✅ | ✅ | ✅ |
| Proto and JSON codecs | ✅ | ✅ | ✅ |
| gzip and zstd both ways, brotli read | ✅ | ✅ | ✅ |
| Unary GET for `NO_SIDE_EFFECTS` | ✅ | n/a[^get] | n/a[^get] |
| Full-duplex bidirectional streams, server and client, over h2 and h3[^duplex] | ✅ | ✅ | ✅ |
| Interceptors, server and client | ✅ | ✅ | ✅ |
| Error details | ✅ | ✅ | ✅ |

[^get]: The Connect protocol defines Unary-Get. gRPC's HTTP/2 spec requires `:method POST`, and
    gRPC-Web keeps that request shape.
[^duplex]: Over h11 a stream is half-duplex: the whole request goes before the response is read.
    The Connect protocol leaves the duplex to the HTTP version, and a proxy that buffers an
    HTTP/1.1 body would stall an interleaved one.

The protobuf runtime covers every scalar type, `optional`, packed and unpacked repeated fields,
maps with every key type, oneofs, enums and recursive messages. It covers every well-known type
with its JSON form. It reads proto2, proto3 and editions 2023 and 2024, groups and DELIMITED fields
included. A message keeps the fields its schema does not know and writes them back, so an older
service passes newer fields on.

## Use it in your project

[examples/quickstart](examples/quickstart) holds these steps as a project you can copy.
`tools/package_check.sh` builds it against a fetched copy of connect-zig on each push.

### 1. Add the package

```sh
zig fetch --save git+https://github.com/c4milo/connect-zig#v0.1.0
```

Then import the modules in `build.zig`:

```zig
const connect_zig = b.dependency("connect_zig", .{ .target = target, .rotor = true });
module.addImport("protobuf", connect_zig.module("protobuf"));
module.addImport("connect", connect_zig.module("connect"));
module.addImport("connect_colibri", connect_zig.module("connect_colibri"));
// colibri's modules, which connect_colibri is built on.
module.addImport("server", connect_zig.module("server"));
module.addImport("client", connect_zig.module("client"));
module.addImport("tls", connect_zig.module("tls"));
module.addImport("colibri", connect_zig.module("colibri"));
```

Take colibri's modules from connect-zig, and do not add colibri to your own `build.zig.zon`: a
second colibri fails the build (decision 39). `.rotor = true` builds `colibri.Server` and
`colibri.Client` on [Rotor](https://github.com/c4milo/rotor), colibri's event loop. Without it,
your program drives colibri's engine and pool on its own loop (decision 32).

A program that imports `connect_colibri` or `oidc` links
[chapulin](https://github.com/c4milo/chapulin), the TLS library under colibri. chapulin reports
a failed assertion through one hook, which your program defines once:

```zig
export fn ch_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}
```

Without it, the link fails with `undefined symbol: ch_assert_fail`.

### 2. Generate code

Install the plugin from your `build.zig` in a step of its own, since your program imports the
code it writes:

```zig
const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
b.step("plugin", "Install protoc-gen-connect-zig").dependOn(&plugin.step);
```

Then point `buf.gen.yaml` at it:

```yaml
version: v2
plugins:
  - local: zig-out/bin/protoc-gen-connect-zig
    out: gen
```

Run `zig build plugin`, then `buf generate`, then `zig build`. Each `.proto` file gives one
`<file>.pb.zig`. A message becomes a struct with a `FieldNumber` enum, an enum a non-exhaustive
`enum(i32)`, and each RPC a `connect.Method`. Give your program each
generated file as a module, with the modules its header names:

```zig
const eliza = b.createModule(.{ .root_source_file = b.path("gen/connectrpc/eliza/v1/eliza.pb.zig") });
eliza.addImport("protobuf", connect_zig.module("protobuf"));
eliza.addImport("connect", connect_zig.module("connect"));
module.addImport("eliza", eliza);
```

> [!TIP]
> A generated file imports other generated files by module name. The module of
> `kitchen/v1/shared.proto` is `kitchen_v1_shared`.

### 3. Write a handler

A handler takes the call's context, its request and its response, as connect-go splits them. It
fills its response and returns `null`, or returns the error the client reads:

```zig
const connect = @import("connect");
const rpc = @import("connect_colibri");

pub fn say(app: *App, ctx: *rpc.Context, request: *const rpc.Request(eliza.SayRequest), response: *rpc.Response(eliza.SayResponse)) ?connect.RpcError {
    if (request.message.sentence.len == 0) return .{ .code = .invalid_argument, .message = "say something" };
    response.message.sentence = reply(app, "You said \"{s}\". How does that make you feel?", .{request.message.sentence});
    response.add_header("x-mood", "calm") catch {};
    _ = ctx.timeout_ns();
    return null;
}
```

- `ctx` is the call: `path()`, `protocol()`, `codec()`, `timeout_ns()`, the counts `received()`
  and `sent()`, and `values(T)`, your own values for this call.
- `request` holds the message, and `header(name)`, `headers()` and `query()`.
- `response` holds the message to fill, and `add_header` and `add_trailer`.

Each stream type takes the request and the response that fit it:

| Stream type | Handler takes |
| --- | --- |
| Unary | `*const Request(Req)`, `*Response(Res)` |
| Server stream | `*const Request(Req)`, `*ResponseStream(Res)`, which sends each message |
| Client stream | `*RequestStream(Req)`, which reads each message, `*Response(Res)` |
| Bidirectional | `*RequestStream(Req)`, `*ResponseStream(Res)` |

A function handler takes a client stream whole. To answer each message as it arrives, write the
handler as a type with `on_message` and `on_end`: over h2 the stream is then full-duplex.

An interceptor is a type that a route lists in its options. Its `on_call(app, ctx, request,
response)` runs before the handler and may refuse the call, and `on_finish(app, ctx, response,
failure)` sees the outcome. Its request and response, `rpc.AnyRequest` and `rpc.AnyResponse`,
hold the headers, the query and the trailers, with no message.

### 4. Route it

Each generated service has a `Routes` function. It lists every method as a route of colibri's
`server.Router`, with the handler of the same name. A unary method with no side effects is a GET
too, and a method with no handler fails to compile. One route answers every protocol and codec:

```zig
/// The longest message a method reads or writes.
const route_options: rpc.RouteOptions = .{ .message_bytes = 4096 };

pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = Service.Routes(rpc, App, @This(), route_options).routes ++
        rpc.Refusals(App, Service.say).routes,
}, .{ .requests = 8, .body_bytes = 8192, .response_bytes = 8192, .header_bytes = 0 });
```

The router holds the memory of each call it answers at once, and gives no size a default:

- `body_bytes` holds a request body, which the route reads in place at its end. A longer body
  gets 413.
- `response_bytes` holds a reply with its headers. A longer reply gets 500.
- `header_bytes` is 0, since each route reads its header at the head.

Set the first two above the routes' `message_bytes`. Each call also holds storage of
`message_bytes`, into which a binary request's repeated fields are read once (decision 37).
`rpc.Refusals` answers 405 with an Allow header to a method Connect does not serve, such as
DELETE, as connect-go does. To give methods options of their own, list each route by hand with
`rpc.post(App, Service.say, say, options)` and `rpc.get`.

`colibri.Server` serves the router on Rotor. A program allocates what it holds once, at the
start:

```zig
const Server = colibri.Server(.{ .tcp_connections = 64, .quic_connections = 8 }, .private);
const State = struct { http_server: Server, router: Router, app: App };

const state = try init.arena.allocator().create(State);
state.router = .{};
state.app = .{};
try state.http_server.init(&.{
    .port = 8443,
    .identity = .{ .chain = chain_pem, .key = key_pem },
    .cpu = cpu,
    .unix_seconds = unix_seconds,
}, &state.router, &state.app);
defer state.http_server.deinit();
try state.http_server.run();
```

It serves h11 and h2 over TLS on a TCP socket, and h3 on the UDP socket of the same port.
`chain_pem` and `key_pem` are your certificate chain and its key, as PEM text, and `cpu` is what
your program probed of its CPU. With no `identity`, it serves h11 and h2 in cleartext, and no h3.

### 5. Call it

A client call is a `connect_colibri.ClientCall(method, .{})`. It writes a request for colibri's
`client.ConnectionPool` and reads the response the pool fills in:

```zig
try say.init({}, &.{ .protocol = .grpc }, &.{.{ .sentence = "I feel tired" }}, &buffers);
_ = try pool.request(&say.request, &say.response);
// Once the pool reports the call finished:
var response = say.read(storage);
const answer = try response.next(eliza.SayResponse);
if (response.failure) |failure| std.debug.print("{s}\n", .{failure.message});
```

`.protocol` picks Connect, the default, gRPC or gRPC-Web, and the rest of the call stays the same.
On Rotor, `colibri.Client(.{}, .private)` holds the pool. Over TLS, the pool's configuration
names what it trusts:

```zig
const anchors = try tls.pem.anchors(ca_pem, &anchor_der, &anchor_room);
const trust: tls.Trust = .{ .web_pki = .{ .anchors = anchors, .server_name = "api.example.com" } };
const config: client.Config = .{ .tls = .{ .trust = trust, .cpu = cpu }, .authority = "api.example.com" };
```

A client or bidirectional stream can stream both ways: `init_stream` builds the call, and its
`Sender` sends each message while the program reads each answer as it arrives.
[examples/streaming](examples/streaming) shows the pool's events for such a call.

A client call lists interceptors of its own in its options. `on_request(context, request)` may
add headers, and `on_response(context, response)` sees each response's head. `context` is the
value that `init` takes, of the type the options name as `Context` (decision 44). A `*State`
lets an interceptor count what it sees. A call with no context passes `{}`.

### 6. Require a bearer token

The `oidc` module checks a JWT that an OpenID Connect provider signed with RS256, ES256 or
EdDSA. It does no I/O and reads no clock: your program fetches the provider's JWK Set and passes
its text and the time. Import it as the others, as `connect_zig.module("oidc")`:

```zig
const oidc = @import("oidc");

// The context of your routes holds the verifier, as `app.oidc`.
try app.oidc.init(&.{ .issuer = "https://accounts.example.com", .audience = "my-service" });
try app.oidc.set_keys(jwks_text); // again when app.oidc.keys_stale()
app.oidc.set_time(unix_seconds); // when your clock moves

// Each call keeps its own claims in its values.
const Values = struct { oidc: ?oidc.Claims = null };

// Each method of the service needs a valid token, except those you exclude.
const Auth = oidc.Interceptor(Values, .{ .exclude = &.{ "/grpc.health.v1.Health/", "/auth.v1.Auth/Login" } });
const options: rpc.RouteOptions = .{ .interceptors = &.{Auth} };
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .Values = Values, // the type of each call's values
    .routes = Service.Routes(rpc, App, @This(), options).routes,
}, router_options);

// In any callback of a call behind the interceptor:
if (ctx.values(Values).oidc) |*claims| {
    std.debug.print("{s}\n", .{claims.subject()});
    const email = claims.string("email") catch null; // ?[]const u8
    const admin = claims.holds("roles", "admin") catch false; // in an array, or equal
}
```

The verifier checks the signature with the key the token names, then the issuer, the audience,
`exp` and `nbf` (decision 34). A call with no valid token gets `unauthenticated` and a
`WWW-Authenticate: Bearer` header. On an excluded path, `oidc` stays null. `oidc` checks
signatures with chapulin, which colibri already links, so it adds no second crypto library.

The route table's `.Values` serves any interceptor: it is a struct you declare, and each call
starts with its defaults (decision 35). One table names one type for all its routes, so a table
that joins services declares one struct with the fields of each.

### More examples

[examples/](examples) holds twelve projects, each a Zig project you can copy (decision 41). They
range from generated messages to streaming, interceptors, error details, bearer tokens, a
GitHub-style API, an OpenTelemetry trace receiver and a socket server. Each checks itself
with `zig build test`, and serves its service with `zig build serve` for curl and `buf curl`.
[examples/std_io](examples/std_io) runs with no Rotor: it drives colibri's engine over Zig's
`std.Io`. [examples/README.md](examples/README.md) says where to start.

## Performance

`zig build bench` times binary and JSON encoding and decoding of eight messages, then a routed
unary call. `tools/bench_check.sh` runs the same inputs through Go's `google.golang.org/protobuf`
v1.36.12, connect-go's codec, and Buffa, connect-rust's codec. It checks that each writes the
same bytes as connect-zig. The numbers below come from CI's two `bench-compare` jobs of
commit `493b3e0` ([run 129](https://github.com/c4milo/connect-zig/actions/runs/43657281850)). One
ran on an AMD EPYC 9V45 core (x86-64) and one on an Arm Neoverse-N2 core (arm64), each with the
three programs in one job. The run's summary holds every table.

Each chart draws the speed of connect-zig and of Buffa in multiples of Go's. A longer bar is
faster, and Go is the line at 1. The charts time the codecs alone, with no code of connect-go or
connect-rust. A binary decode with every field read takes `decode_into`, which reads each
repeated field once (decision 37).

On x86-64, Buffa is faster than connect-zig in 1 of 16 cells, binary encode of the deep message:

![Bars of the speed of connect-zig and of Buffa, connect-rust's codec, in multiples of Go's protobuf runtime, connect-go's codec, on x86-64: connect-zig is 3.2 to 19.6 times faster than Go's protobuf runtime, and Buffa is faster than connect-zig in 1 of 16 cells](docs/images/speed-vs-go.svg)

On arm64, Buffa is faster in none:

![Bars of the speed of connect-zig and of Buffa, connect-rust's codec, in multiples of Go's protobuf runtime, connect-go's codec, on arm64: connect-zig is 3.0 to 21.7 times faster than Go's protobuf runtime, and Buffa is faster than connect-zig in no cell](docs/images/speed-vs-go-arm64.svg)

The routed calls (`bench/call.zig`) run the same unary call in memory through connect-zig,
connect-go and connect-rust. CI's `bench-compare` job prints them beside each other.

## How it is checked

- `zig build test` runs the lint, every module's tests and the examples. Each check in the
  library was broken on purpose to prove a test catches it. The examples run a client against
  the server in memory over h11, h2 and h3.
- `tools/line_coverage_check.sh` runs each module's tests under kcov (decision 43). On CI's
  [run 136](https://github.com/c4milo/connect-zig/actions/runs/43680656658) they ran 97.6% of
  the library's 8489 lines.
- `tools/conformance_check.sh` runs the [connectrpc conformance
  suite](https://github.com/connectrpc/conformance) v1.0.4, as CI's
  [run 148](https://github.com/c4milo/connect-zig/actions/runs/43746293217) did on colibri v0.17.0.
  The server passes all 2714 cases, over h11 and h2. The client passes all 8264, over h11, h2
  and h3, in cleartext and over TLS. One client case, a timing case of the reference server,
  may fail and is listed in `conformance/client_known_flaky.txt`.
- `tools/protobuf_conformance_check.sh` runs [Google's protobuf conformance
  suite](https://github.com/protocolbuffers/protobuf/tree/main/conformance) in binary and JSON,
  for proto3, proto2 and edition 2023. 5635 cases pass, and
  `conformance/protobuf_known_failing.txt` lists each of the 107 that fail, with its reason.
- `tools/coverage_check.sh` converts every protobuf type with connect-zig and with Go's runtime,
  between binary and JSON both ways, and requires the same message.
- `tools/interop_languages_check.sh` calls the server from [clients in Go, TypeScript, Python
  and Rust](interop), 758 calls. `tools/interop_servers_check.sh` calls their servers with
  connect-zig's client, 831 calls. Each covers every protocol, codec, stream shape and error.
- `tools/interop_check.sh` calls the example server with `buf curl` and curl, and with
  OpenTelemetry's Go SDK, which exports spans to the example trace receiver.
- `tools/package_check.sh` builds `examples/quickstart` against connect-zig as `zig fetch` keeps
  it, and calls it over TLS on h11, h2 and h3.
- `tools/perf_check.sh` counts each benchmark operation's instructions under callgrind, and
  fails past 2% above `bench/instructions.txt`. Counts do not move with a shared runner's load.

CI runs each check as a job of its own, and writes its results to the job's summary. The tests
and the comparison with Go and Rust run a second time on an arm64 runner.

## Good to know

> [!IMPORTANT]
> A function handler writes its whole stream in one call, so the router's response memory bounds
> it (decision 12). A long stream takes a type handler with `next`, which gives one message at a
> time (decision 33). Over h11 both sides of a stream are half-duplex.

Editions 2023 and 2024 follow [protobuf.dev's editions
overview](https://protobuf.dev/editions/overview/): field presence, packed and expanded repeated
fields, delimited messages, closed enums and `utf8_validation`. The library does not report a
missing required field (decision 23).

Not yet done:

- brotli compression of messages, which waits for an encoder in stdx (decision 10);
- a stream that waits for an event of the program once its request ended (colibri issue 130).

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) is the summary, and [SECURITY.md](SECURITY.md) says where to
report a vulnerability. The rules of the tree are in [CLAUDE.md](CLAUDE.md), the design and its
build plan in [docs/design.md](docs/design.md), and each choice with what it beat in
[docs/decisions.md](docs/decisions.md). Before you send a change, run the checks CI runs:

```sh
tools/ci.sh               # every check below, as CI runs them
zig build test            # the lint, every module's tests and the examples
tools/package_check.sh    # a project that fetches connect-zig builds against it
tools/generate_check.sh   # buf generate still writes each gen/
tools/interop_check.sh    # buf curl, curl and OpenTelemetry's SDK against the example server
tools/coverage_check.sh   # every protobuf type against Go's runtime
tools/conformance_check.sh  # the connectrpc conformance suite against the server and client
tools/interop_languages_check.sh  # Go, TypeScript, Python and Rust clients against the server
tools/interop_servers_check.sh    # the client against Go, TypeScript, Python and Rust servers
tools/perf_check.sh       # instructions of each benchmark operation against the baseline
tools/bench_check.sh      # the benchmark beside Go's and Rust's
```

## Changelog

[CHANGELOG.md](CHANGELOG.md) lists what each release adds and changes.

## License

connect-zig is licensed under the [Apache License 2.0](LICENSE).
