# connect-zig

[![CI](https://github.com/c4milo/connect-zig/actions/workflows/main.yml/badge.svg)](https://github.com/c4milo/connect-zig/actions/workflows/main.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16.0-f7a41d.svg)](https://ziglang.org/download/#release-0.16.0)
[![Connect conformance: 3,714 of 3,714 server cases, 10,711 of 10,711 client cases](https://img.shields.io/badge/connect_conformance-passing-brightgreen.svg)](https://github.com/c4milo/connect-zig/actions/runs/44007655863)
[![Line coverage: 97.7%](https://img.shields.io/badge/line_coverage-97.7%25-brightgreen.svg)](https://github.com/c4milo/connect-zig/actions/runs/44007655863)

**[Connect RPC](https://connectrpc.com/) for Zig.** Write a `.proto` file, run `buf generate`,
and serve the same handlers to Connect, gRPC, and gRPC-Web clients, in binary protobuf or JSON.

- **Conformant.** It passes [connectrpc's conformance suite](https://github.com/connectrpc/conformance)
  v1.0.7 in Connect, gRPC, and gRPC-Web: all 3,714 server cases and all 10,711 client cases.
- **No allocator in the library.** Every buffer is yours, and every size is a constant you can
  read.
- **Few copies.** Decoded strings and bytes point into the input. A repeated field is read once,
  into storage you pass, and each message is encoded straight into the HTTP body that sends it.
- **No hidden I/O.** The protocol core reads bytes you give it and writes bytes you send. It
  reads no clock, so every test is deterministic.
- **Fast.** On one core, an OpenTelemetry trace receiver built on connect-zig takes 7.0 times as
  many spans a second as one built on connect-go, and 2.7 times as many as one built on
  connect-rust. See [Performance](#performance).
- **HTTP from [colibri](https://github.com/c4milo/colibri).** Servers and clients run over
  HTTP/1.1, HTTP/2, and HTTP/3, which colibri and this README call h11, h2, and h3, in cleartext or
  over TLS.

## Try it

You need [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0) and curl 7.82 or later, the
first release with `--json`. Clone the repository and start the example server:

```sh
git clone https://github.com/c4milo/connect-zig && cd connect-zig
zig build run-eliza-server -- 8080
```

The first build downloads and compiles the dependencies, so it takes longer than later builds.
When the server prints `listening on port 8080`, call [ELIZA](https://en.wikipedia.org/wiki/ELIZA)
from a second terminal:

```sh
curl --cacert examples/harness/tls/ca.pem --json '{"sentence":"I feel tired"}' \
  https://localhost:8080/connectrpc.eliza.v1.ElizaService/Say
```

```json
{"sentence":"You said \"I feel tired\". How does that make you feel?"}
```

If you have the [Buf CLI](https://buf.build/docs/cli/), call the same server with
[`buf curl`](https://buf.build/docs/reference/cli/buf/curl) in any protocol. Set `--protocol` to
`connect`, `grpc`, or `grpcweb`, and add `--http3` to call it over h3:

```sh
buf curl --cacert examples/harness/tls/ca.pem --protocol grpc --schema examples/eliza/proto \
  -d '{"name":"Ada"}' https://localhost:8080/connectrpc.eliza.v1.ElizaService/Introduce
```

## What's inside

connect-zig has six parts:

| Module | What it does |
| --- | --- |
| `protobuf` | The binary encoding and the proto3 JSON mapping, over generated structs. |
| `connect` | The Connect, gRPC, and gRPC-Web rules, as functions over headers and bytes. |
| `connect_colibri` | Routes for colibri's server, and calls for colibri's client. Programs import it as `rpc`. |
| `protovalidate` | Checks a message against the [protovalidate](https://github.com/bufbuild/protovalidate) rules of its schema. |
| `oidc` | Checks an OpenID Connect bearer token, with a server interceptor that requires one. |
| `protoc-gen-connect-zig` | The plugin `buf generate` runs to write your `.pb.zig` files. |

Each protocol supports the same features, except Unary GET:

| | Connect | gRPC | gRPC-Web |
| --- | :---: | :---: | :---: |
| Server: unary, all streams | ✅ | ✅ | ✅ |
| Client: unary, all streams | ✅ | ✅ | ✅ |
| Proto and JSON codecs | ✅ | ✅ | ✅ |
| gzip, zstd, and brotli both ways | ✅ | ✅ | ✅ |
| Unary GET for `NO_SIDE_EFFECTS` | ✅ | n/a[^get] | n/a[^get] |
| Full-duplex bidirectional streams, server and client, over h2 and h3[^duplex] | ✅ | ✅ | ✅ |
| Interceptors, server and client | ✅ | ✅ | ✅ |
| Error details | ✅ | ✅ | ✅ |

[^get]: The Connect protocol defines Unary-Get. gRPC's HTTP/2 spec requires `:method POST`, and
    gRPC-Web keeps that request shape.
[^duplex]: Over h11 a stream is half-duplex: the whole request goes before the response is read.

The protobuf runtime covers every scalar type, `optional`, packed and unpacked repeated fields,
maps, oneofs, enums, recursive messages, and every well-known type with its JSON form. It reads
proto2, proto3, and editions 2023 and 2024. A message keeps the fields its schema does not know,
and writes them back.

## Quick start

[examples/quickstart](examples/quickstart) holds these steps as a project you can copy.
[docs/guide.md](docs/guide.md) explains each step in full: the handler of each stream type,
interceptors, route options, TLS, and the client.

### 1. Add the package

```sh
zig fetch --save git+https://github.com/c4milo/connect-zig#v0.4.0
```

Then import the modules in `build.zig`. Take colibri's modules from connect-zig, too: a second
copy of colibri in your `build.zig.zon` fails the build.

```zig
const connect_zig = b.dependency("connect_zig", .{ .target = target, .rotor = true });
module.addImport("protobuf", connect_zig.module("protobuf"));
module.addImport("connect", connect_zig.module("connect"));
module.addImport("connect_colibri", connect_zig.module("connect_colibri"));
module.addImport("server", connect_zig.module("server"));
module.addImport("client", connect_zig.module("client"));
module.addImport("tls", connect_zig.module("tls"));
module.addImport("colibri", connect_zig.module("colibri"));
```

connect-zig probes no CPU: your program detects its CPU's features once and states them. Their
type is [stdx](https://github.com/c4milo/stdx)'s, so name stdx too, at the commit connect-zig
pins, with the `.release` you pass connect-zig, or false when you pass none:

```sh
zig fetch --save=stdx git+https://github.com/c4milo/stdx#1df5f9f2fd51e8ebc1707e2e77c02afc6041f49f
```

```zig
const stdx = b.dependency("stdx", .{ .target = target, .release = false });
module.addImport("platform", stdx.module("platform"));
```

> [!IMPORTANT]
> A program that imports `connect_colibri` or `oidc` links
> [chapulin](https://github.com/c4milo/chapulin), colibri's TLS library. Define its assertion
> hook once, or the link fails with `undefined symbol: ch_assert_fail`:
>
> ```zig
> export fn ch_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) noreturn {
>     std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
> }
> ```

### 2. Generate code

Install the plugin in a build step of its own, and point `buf.gen.yaml` at it:

```zig
const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
b.step("plugin", "Install protoc-gen-connect-zig").dependOn(&plugin.step);
```

```yaml
version: v2
plugins:
  - local: zig-out/bin/protoc-gen-connect-zig
    out: gen
```

Run `zig build plugin`, then `buf generate`, then `zig build`. Each `.proto` file gives one
`<file>.pb.zig`, which your program imports as a module.

### 3. Write a handler

A handler takes the call's context, its request, and its response. It fills the response and
returns `null`, or returns the error the client reads:

```zig
const connect = @import("connect");
const rpc = @import("connect_colibri");

pub fn say(app: *App, ctx: *rpc.Context, request: *const rpc.Request(eliza.SayRequest), response: *rpc.Response(eliza.SayResponse)) ?connect.RpcError {
    if (request.message.sentence.len == 0) return .{ .code = .invalid_argument, .message = "say something" };
    response.message.sentence = reply(app, "You said \"{s}\". How does that make you feel?", .{request.message.sentence});
    return null;
}
```

Streams take a `RequestStream` or a `ResponseStream` in place of the request or the response.

### 4. Route it and serve it

The routes share one context, your `App`, which holds the CPU features your program detected.
Set the field once, as the program starts, with `.cpu_features = .detect()`:

```zig
const platform = @import("platform");

/// What every route reads: your program's state, and the CPU features it detected as it started.
const App = struct {
    cpu_features: platform.CpuFeatures,
};
```

Each generated service has a `Routes` function, which lists every method as a route of
colibri's `server.Router`. One route answers every protocol and codec:

```zig
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = Service.Routes(rpc, App, @This(), .{ .message_bytes = 4096 }).routes,
}, .{ .requests = 8, .body_bytes = 8192, .response_bytes = 8192, .header_bytes = 0 });
```

`colibri.Server` serves the router. With a certificate it serves h11 and h2 over TLS, and h3;
with none, h11 and h2 in cleartext. [docs/guide.md](docs/guide.md) shows the server and the
memory the router holds.

### 5. Call it

Two clients make a call. colibri's connection pool is the HTTP client: it opens each
connection and sends each request. `connect.Client` is Connect's part, which your calls share.
It holds the CPU features your program detected and the codecs it placed, and it builds each
request for the pool. Make it once, as the program starts:

```zig
const client: connect.Client = .{ .cpu_features = .detect() };
```

A client call is a `connect_colibri.ClientCall(method, .{})`. Its `.protocol` option picks
Connect, gRPC, or gRPC-Web, and the rest of the call stays the same. In this example, `pool` is
colibri's client connection pool, and `buffers` and `storage` are memory that your program owns.
[docs/guide.md](docs/guide.md) shows how to set up each one:

```zig
try say.init(&client, {}, &.{ .protocol = .grpc }, &.{.{ .sentence = "I feel tired" }}, &buffers);
_ = try pool.request(&say.request, &say.response);
// Once the pool reports the call finished:
var response = say.read(storage);
const answer = try response.next(eliza.SayResponse);
```

[examples/](examples) holds twelve projects to copy, from generated messages to streaming,
interceptors, error details, bearer tokens, and an OpenTelemetry trace receiver.

## Validate requests

The `protovalidate` module checks each message against the rules that its schema states with
[protovalidate](https://github.com/bufbuild/protovalidate). To validate every request:

1. Add rules to your schema:

   ```proto
   import "buf/validate/validate.proto";

   message User {
     string email = 1 [(buf.validate.field).string.email = true];
     int32 age = 2 [(buf.validate.field).int32 = {gte: 18, lt: 150}];
   }
   ```

2. Add the interceptor, which checks each request message before its handler runs:

   ```zig
   pub const Values = struct {
       protovalidate: protovalidate.InterceptorRoom(connect, .{}) = .{},
   };
   const Validate = protovalidate.Interceptor(connect, Values, .{});
   pub const route_options: rpc.RouteOptions = .{ .interceptors = &.{Validate} };
   ```

3. The interceptor reads the `cpu_features` field of your `App`, the one your routes read.

A message that breaks a rule ends its call with `invalid_argument`, and with an error detail that
lists each violation.

The rules compile with your program, CEL expressions included. Nothing parses a rule or
interprets an expression at run time. The module passes all 2,872 cases of protovalidate's
conformance suite. A decode with a validation runs 15 to 65 times as fast as protovalidate-go on
arm64, and 13 to 57 times as fast on x86-64.

[docs/protovalidate.md](docs/protovalidate.md) covers CEL rules, predefined rules, patterns,
what stops the build, and the limits.

## Require a bearer token

The `oidc` module checks a JWT that an OpenID Connect provider signed with RS256, ES256, or
EdDSA. It does no I/O and reads no clock: your program fetches the provider's keys and passes
them, with the time. One interceptor requires a valid token on every method but those you
exclude:

```zig
const Auth = oidc.Interceptor(Values, .{ .exclude = &.{"/grpc.health.v1.Health/"} });
```

[docs/guide.md](docs/guide.md), "Require a bearer token", shows the rest.

## Performance

The benchmark serves OpenTelemetry traces: a receiver takes the OpenTelemetry Protocol (OTLP)
over TLS and h2, on one core, and counts each span, the record of one operation in a trace. Its
load is the traffic that one core of a gateway receives from a fleet of 33,000 servers. The load
generator runs on another core of the same machine, over its loopback device. Each bar shows the
highest rate a server held with its 99th-percentile latency (p99) under 100 ms. The bar is the
median of three rounds, and its whisker spans the three:

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, the median of three rounds with their range, and lines of p99 as the rate climbs, on arm64: connect-zig holds 711,570 spans a second, 7.0 times connect-go's 101,213, 2.7 times connect-rust's 263,440, 3.3 times the OpenTelemetry Collector's 215,818, and 8.6 times Vector's 82,310](docs/images/fullstack-arm64.svg)

These results come from an Arm Neoverse-N2 core in CI. The first three come from
[run 266](https://github.com/c4milo/connect-zig/actions/runs/45246119951), and the last two from
[run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610):

- **A whole server.** connect-zig takes 7.0 times as many spans a second as connect-go, 2.7 times
  as many as connect-rust, and 3.3 times as many as the OpenTelemetry Collector. It spends 1.41 µs
  of CPU a span, and it held its rate for a 60-second step. In that run it took 321 MiB when it
  started, where connect-rust grew to 54 MiB. It now starts in 6 MiB, and holds only the memory its
  connections and calls write ([decision 48](docs/decisions.md)).
- **Validation.** With protovalidate checking every span, connect-zig spends 12% more CPU a span,
  connect-rust 9% more, and connect-go 53% more. connect-zig keeps 87% of its rate, which is 2.5
  times connect-rust's rate with protovalidate-buffa and 9.8 times connect-go's with
  protovalidate-go.
- **Compression.** Over TLS, a gzip or zstd export costs connect-zig 5% less CPU a span than an
  uncompressed one, because the smaller export saves more TLS work than decompression costs. In
  cleartext, with no TLS work to save, it costs 7% to 9% more.
- **A routed unary call.** A call through connect-zig's router, protocol, and codec, in memory, is
  9.6 to 12.4 times as fast as connect-go's and 3.3 to 5.6 times as fast as connect-rust's.
- **The codec.** connect-zig encodes and decodes protobuf messages 3.2 to 18.9 times as fast as
  Go's protobuf runtime.

[docs/benchmarks.md](docs/benchmarks.md) holds every chart, the x86-64 results, how each number
is measured, and the limits of each.

## How it is tested

- [connectrpc's conformance suite](https://github.com/connectrpc/conformance): all 3,714 server
  cases over h11 and h2, and all 10,711 client cases over h11, h2, and h3.
- [Google's protobuf conformance suite](https://github.com/protocolbuffers/protobuf/tree/main/conformance):
  5,707 cases pass. A list in the repository names each of the 35 cases that fail, with its
  reason.
- [protovalidate's conformance suite](https://github.com/bufbuild/protovalidate/blob/main/docs/conformance.md):
  all 2,872 cases.
- Clients and servers in Go, TypeScript, Python, and Rust call connect-zig, and connect-zig calls
  them, in every protocol.
- Mutation tests: each check in the library was broken on purpose, and a test failed each time.

[docs/testing.md](docs/testing.md) lists every check and how to run it.

## Known limits

- Over h11, a stream is half-duplex: the whole request goes before the response is read.
- A function handler writes its whole stream in one call. A long stream needs a type handler,
  which [docs/guide.md](docs/guide.md) describes.
- The library does not report a missing `required` field.
- A server stream cannot yet wait for your program's own events once its request has ended
  ([colibri issue 130](https://github.com/c4milo/colibri/issues/130)).

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) explains how to propose a change, and
[SECURITY.md](SECURITY.md) explains how to report a vulnerability. [docs/design.md](docs/design.md)
describes the design, and [docs/decisions.md](docs/decisions.md) records each choice with the
options it beat.

## Changelog

[CHANGELOG.md](CHANGELOG.md) lists what each release adds and changes.

## License

connect-zig is licensed under the [Apache License 2.0](LICENSE).
