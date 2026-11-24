# connect-zig

[![CI](https://github.com/c4milo/connect-zig/actions/workflows/main.yml/badge.svg)](https://github.com/c4milo/connect-zig/actions/workflows/main.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16.0-f7a41d.svg)](https://ziglang.org/download/#release-0.16.0)
[![Connect conformance: 3,714 of 3,714 server cases, 10,711 of 10,711 client cases](https://img.shields.io/badge/connect_conformance-passing-brightgreen.svg)](https://github.com/c4milo/connect-zig/actions/runs/44007655863)
[![Line coverage: 97.7%](https://img.shields.io/badge/line_coverage-97.7%25-brightgreen.svg)](https://github.com/c4milo/connect-zig/actions/runs/44007655863)

**[Connect RPC](https://connectrpc.com/) for Zig.** Write a `.proto` file, run `buf generate`,
and serve the same handlers to Connect, gRPC, and gRPC-Web clients, in binary protobuf or JSON.

- **Conformant.** It passes every case of [connectrpc's conformance
  suite](https://github.com/connectrpc/conformance) v1.0.7, server and client.
- **No allocator and no hidden I/O.** Every buffer is yours, and the core reads no clock.
- **Fast.** An OpenTelemetry receiver on connect-zig takes 7.0 times the spans a second of one on
  connect-go. See [Performance](#performance).
- **HTTP from [colibri](https://github.com/c4milo/colibri):** HTTP/1.1, HTTP/2, and HTTP/3 (h11,
  h2, and h3), in cleartext or over TLS.

## Try it

You need [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0) and curl 7.82 or later. Start
the example server:

```sh
git clone https://github.com/c4milo/connect-zig && cd connect-zig
zig build run-eliza-server -- 8080
```

When it prints `listening on port 8080`, call [ELIZA](https://en.wikipedia.org/wiki/ELIZA) from a
second terminal:

```sh
curl --cacert examples/harness/tls/ca.pem --json '{"sentence":"I feel tired"}' \
  https://localhost:8080/connectrpc.eliza.v1.ElizaService/Say
```

```json
{"sentence":"You said \"I feel tired\". How does that make you feel?"}
```

With the [Buf CLI](https://buf.build/docs/cli/), `buf curl` calls it in any protocol: set
`--protocol` to `connect`, `grpc`, or `grpcweb`, and add `--http3` for h3:

```sh
buf curl --cacert examples/harness/tls/ca.pem --protocol grpc --schema examples/eliza/proto \
  -d '{"name":"Ada"}' https://localhost:8080/connectrpc.eliza.v1.ElizaService/Introduce
```

## What's inside

| Module | What it does |
| --- | --- |
| `protobuf` | The binary encoding and the proto3 JSON mapping, over generated structs. |
| `connect` | The Connect, gRPC, and gRPC-Web rules, as functions over headers and bytes. |
| `connect_colibri` | Routes for colibri's server, and calls for colibri's client. Programs import it as `rpc`. |
| `protovalidate` | Checks a message against the [protovalidate](https://github.com/bufbuild/protovalidate) rules of its schema. |
| `oidc` | Checks an OpenID Connect bearer token, with a server interceptor that requires one. |
| `protoc-gen-connect-zig` | The plugin `buf generate` runs to write your `.pb.zig` files. |

Each protocol supports the same features:

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

The protobuf runtime reads proto2, proto3, and editions 2023 and 2024, with every well-known type
and its JSON form. A message keeps the fields its schema does not know.

## Quick start

[examples/quickstart](examples/quickstart) holds these steps as a project, and
[docs/guide.md](docs/guide.md) explains each one in full.

### 1. Add the package

```sh
zig fetch --save git+https://github.com/c4milo/connect-zig#v0.4.0
```

Then import the modules in `build.zig`. Take colibri's modules from connect-zig: a second copy of
colibri fails the build.

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

Your program detects its CPU's features once, with [stdx](https://github.com/c4milo/stdx)'s type.
Name stdx at the commit connect-zig pins, with the `.release` you pass connect-zig:

```sh
zig fetch --save=stdx git+https://github.com/c4milo/stdx#1df5f9f2fd51e8ebc1707e2e77c02afc6041f49f
```

```zig
const stdx = b.dependency("stdx", .{ .target = target, .release = false });
module.addImport("platform", stdx.module("platform"));
```

> [!IMPORTANT]
> A program that imports `connect_colibri` or `oidc` links
> [chapulin](https://github.com/c4milo/chapulin), colibri's TLS library, and must define its
> assertion hook, or the link fails with `undefined symbol: ch_assert_fail`:
>
> ```zig
> export fn ch_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) noreturn {
>     std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
> }
> ```

### 2. Generate code

Install the plugin, and point `buf.gen.yaml` at it:

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

Run `zig build plugin`, then `buf generate`. Each `.proto` file gives one `<file>.pb.zig` module.

### 3. Write a handler

A handler fills the response and returns `null`, or returns the error the client reads:

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

The routes share one context, your `App`, which holds the CPU features. Set them once at start,
with `.cpu_features = .detect()`:

```zig
const platform = @import("platform");

/// What every route reads: your program's state, and the CPU features it detected as it started.
const App = struct {
    cpu_features: platform.CpuFeatures,
};
```

A generated service's `Routes` lists each method as a route of colibri's `server.Router`, for every
protocol and codec:

```zig
pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = Service.Routes(rpc, App, @This(), .{ .message_bytes = 4096 }).routes,
}, .{ .requests = 8, .body_bytes = 8192, .response_bytes = 8192, .header_bytes = 0 });
```

`colibri.Server` serves the router: h11, h2, and h3 with a certificate, and h11 and h2 in cleartext
without one.

### 5. Call it

colibri's connection pool sends each request, and `connect.Client` builds it. Make the client once:

```zig
const client: connect.Client = .{ .cpu_features = .detect() };
```

A call is a `connect_colibri.ClientCall(method, .{})`, whose `.protocol` picks Connect, gRPC, or
gRPC-Web. `pool` is colibri's connection pool, and `buffers` and `storage` are your memory:

```zig
try say.init(&client, {}, &.{ .protocol = .grpc }, &.{.{ .sentence = "I feel tired" }}, &buffers);
_ = try pool.request(&say.request, &say.response);
// Once the pool reports the call finished:
var response = say.read(storage);
const answer = try response.next(eliza.SayResponse);
```

[examples/](examples) holds twelve projects to copy.

## Validate requests

The `protovalidate` module checks each request against its schema's
[protovalidate](https://github.com/bufbuild/protovalidate) rules:

1. Add rules to your schema:

   ```proto
   import "buf/validate/validate.proto";

   message User {
     string email = 1 [(buf.validate.field).string.email = true];
     int32 age = 2 [(buf.validate.field).int32 = {gte: 18, lt: 150}];
   }
   ```

2. Add the interceptor, which reads your `App`'s `cpu_features`:

   ```zig
   pub const Values = struct {
       protovalidate: protovalidate.InterceptorRoom(connect, .{}) = .{},
   };
   const Validate = protovalidate.Interceptor(connect, Values, .{});
   pub const route_options: rpc.RouteOptions = .{ .interceptors = &.{Validate} };
   ```

A message that breaks a rule gets `invalid_argument`, with each violation in an error detail. The
rules compile with your program, CEL included, and nothing interprets them at run time.
[docs/protovalidate.md](docs/protovalidate.md) has the details.

## Require a bearer token

The `oidc` module checks an OpenID Connect JWT signed with RS256, ES256, or EdDSA. Your program
passes the provider's keys and the time. One interceptor requires a token on every method but
those you exclude:

```zig
const Auth = oidc.Interceptor(Values, .{ .exclude = &.{"/grpc.health.v1.Health/"} });
```

[docs/guide.md](docs/guide.md) shows the rest.

## Performance

The benchmark loads an OpenTelemetry (OTLP) receiver on one core, over TLS and h2, with a gateway
core's traffic for 33,000 servers. Each bar is the highest rate held with p99 under 100 ms, the
median of three rounds:

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, the median of three rounds with their range, and lines of p99 as the rate climbs, on arm64: connect-zig holds 711,570 spans a second, 7.0 times connect-go's 101,213, 2.7 times connect-rust's 263,440, 3.3 times the OpenTelemetry Collector's 215,818, and 8.6 times Vector's 82,310](docs/images/fullstack-arm64.svg)

On an Arm Neoverse-N2 core in CI's
[run 266](https://github.com/c4milo/connect-zig/actions/runs/45246119951) and
[run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610), connect-zig:

- takes 7.0 times connect-go's spans a second, 2.7 times connect-rust's, and 3.3 times the
  OpenTelemetry Collector's;
- keeps 87% of its rate with protovalidate, 9.8 times connect-go's with protovalidate-go;
- makes a routed unary call 9.6 to 12.4 times as fast as connect-go;
- encodes and decodes protobuf 3.2 to 18.9 times as fast as Go's runtime.

[docs/benchmarks.md](docs/benchmarks.md) holds every chart, the x86-64 results, and the method.

## How it is tested

- [connectrpc's conformance suite](https://github.com/connectrpc/conformance): all 3,714 server
  cases over h11 and h2, and all 10,711 client cases over h11, h2, and h3.
- [Google's protobuf conformance suite](https://github.com/protocolbuffers/protobuf/tree/main/conformance):
  5,707 cases pass, and a list names the 35 that fail, with reasons.
- [protovalidate's conformance suite](https://github.com/bufbuild/protovalidate/blob/main/docs/conformance.md):
  all 2,872 cases.
- Interop with clients and servers in Go, TypeScript, Python, and Rust, in every protocol.
- Mutation tests: each check was broken on purpose, and a test failed each time.

[docs/testing.md](docs/testing.md) lists every check and how to run it.

## Known limits

- A function handler writes its whole stream in one call; a long stream needs a type handler.
- The library does not report a missing `required` field.
- A server stream cannot yet wait for your program's own events once its request has ended
  ([colibri issue 130](https://github.com/c4milo/colibri/issues/130)).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
[docs/design.md](docs/design.md) describes the design, [docs/decisions.md](docs/decisions.md) each
choice, and [CHANGELOG.md](CHANGELOG.md) each release.

## License

connect-zig is licensed under the [Apache License 2.0](LICENSE).
