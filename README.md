# connect-zig

[![CI](https://github.com/c4milo/connect-zig/actions/workflows/main.yml/badge.svg)](https://github.com/c4milo/connect-zig/actions/workflows/main.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16.0-f7a41d.svg)](https://ziglang.org/download/#release-0.16.0)

**[Connect RPC](https://connectrpc.com/) for Zig.** Write a `.proto` file, run `buf generate`,
and serve the same handlers to Connect, gRPC and gRPC-Web clients, in binary protobuf or JSON.

- **No allocator in the library.** Every buffer is yours, and every size is a constant you can
  read.
- **No copies when decoding.** Strings, bytes and repeated fields point into the input.
- **No hidden I/O.** The protocol core reads bytes you give it and writes bytes you send. It
  reads no clock, so every test is deterministic.
- **Fast HTTP underneath.** Servers and clients run on
  [colibri](https://github.com/c4milo/colibri)'s h11, h2 and h3.

## Try it in 30 seconds

You need [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0) and curl.

```sh
git clone https://github.com/c4milo/connect-zig && cd connect-zig
zig build run-eliza-server -- 8080
```

In a second terminal, talk to [ELIZA](https://en.wikipedia.org/wiki/ELIZA):

```sh
curl --json '{"sentence":"I feel tired"}' \
  http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
```

```json
{"sentence":"You said \"I feel tired\". How does that make you feel?"}
```

The same server answers [`buf curl`](https://buf.build/docs/reference/cli/buf/curl) in every
protocol. Try `--protocol grpc` or `--protocol grpcweb`:

```sh
buf curl --http2-prior-knowledge --protocol grpc --schema examples/proto \
  -d '{"name":"Ada"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Introduce
```

## What's inside

| Module | What it does |
| --- | --- |
| `protobuf` | The binary encoding and the proto3 JSON mapping, over generated structs. |
| `connect` | The Connect, gRPC and gRPC-Web rules, as functions over headers and bytes. |
| `connect_colibri` | Routes for colibri's server, and calls for colibri's client. |
| `protoc-gen-connect-zig` | The plugin `buf generate` runs to write your `.pb.zig` files. |

### What works today

| | Connect | gRPC | gRPC-Web |
| --- | :---: | :---: | :---: |
| Server: unary, all streams | ✅ | ✅ | ✅ |
| Client: unary, all streams | ✅ | errors only | ✅ |
| Proto and JSON codecs | ✅ | ✅ | ✅ |
| gzip both ways | ✅ | ✅ | ✅ |
| Unary GET for `NO_SIDE_EFFECTS` | ✅ | | |
| Full-duplex bidirectional streams (server) | ✅ | ✅ | ✅ |
| Interceptors, server and client | ✅ | ✅ | ✅ |
| Error details | ✅ | ✅ | ✅ |

> [!NOTE]
> A gRPC client needs HTTP trailers, which colibri's client does not expose yet. Until it does,
> the client reads gRPC errors sent "Trailers-Only" and nothing else (decision 11 in
> [docs/decisions.md](docs/decisions.md)).

## Use it in your project

### 1. Add the package

```sh
zig fetch --save git+https://github.com/c4milo/connect-zig
```

Then import the modules in `build.zig`:

```zig
const connect_zig = b.dependency("connect_zig", .{ .target = target });
module.addImport("protobuf", connect_zig.module("protobuf"));
module.addImport("connect", connect_zig.module("connect"));
module.addImport("connect_colibri", connect_zig.module("connect_colibri"));
```

### 2. Generate code

Build the plugin with `zig build`, then point `buf.gen.yaml` at it:

```yaml
version: v2
plugins:
  - local: zig-out/bin/protoc-gen-connect-zig
    out: gen
```

`buf generate` writes one `<file>.pb.zig` for each `.proto` file:

- a message becomes a struct, with a `FieldNumber` enum that names each field's number;
- an enum becomes a non-exhaustive `enum(i32)`;
- each RPC becomes a `connect.Method` you hand to a route or a client.

> [!TIP]
> A generated file imports other generated files by module name, and its header lists the
> modules it needs. The module of `kitchen/v1/shared.proto` is `kitchen_v1_shared`:
>
> ```zig
> const shared = b.createModule(.{ .root_source_file = b.path("gen/kitchen/v1/shared.pb.zig") });
> shared.addImport("protobuf", connect_zig.module("protobuf"));
> kitchen.addImport("kitchen_v1_shared", shared);
> ```

### 3. Write a handler

A handler fills its response and returns `null`, or returns the error the client reads:

```zig
fn say(app: *App, _: *rpc.Call, request: *const eliza.SayRequest, response: *eliza.SayResponse) ?connect.RpcError {
    app.calls += 1;
    if (request.sentence.len == 0) return .{ .code = .invalid_argument, .message = "say something" };
    response.sentence = reply(app, "You said \"{s}\". How does that make you feel?", .{request.sentence});
    return null;
}
```

Streams get a `Sender` to write messages and a `Receiver` to read them:

| Stream type | Handler takes |
| --- | --- |
| Unary | `*const Request`, `*Response` |
| Server stream | `*const Request`, `*Sender(Response)` |
| Client stream | `*Receiver(Request)`, `*Response` |
| Bidirectional | `*Receiver(Request)`, `*Sender(Response)` |

A function handler takes a client stream whole. To answer each message as it arrives, write the
handler as a type with `on_message` and `on_end`: over h2 the stream is then full-duplex. A
handler reads its call through `rpc.Call`: the protocol, the timeout, the request headers,
and the response headers and trailers it adds.

Interceptors are types a route lists in its options: `on_call` runs before the handler and may
refuse the call, and `on_finish` sees the outcome. A client's `rpc.ExchangeWith` takes
interceptors with `on_request`, which may add headers, and `on_response`.

### 4. Route it

Each generated service has a `Routes` function. It lists every method as a route of colibri's
`server.router`, with the handler of the same name, and a unary method with no side effects as a
GET too. A method you have no handler for fails to compile. One route answers every protocol and
codec:

```zig
const rpc = @import("connect_colibri");

pub fn say(app: *App, call: *rpc.Call, request: *const eliza.SayRequest, response: *eliza.SayResponse) ?connect.RpcError { ... }
pub fn introduce(...) ?connect.RpcError { ... }
pub fn converse(...) ?connect.RpcError { ... }

pub const routes = server.router(App, .{
    .error_handler = on_error,
    .routes = Service.Routes(rpc, App, @This(), route_options).routes,
});
```

To give methods different options, such as their own interceptors, list routes by hand:
`rpc.post(App, Service.say, say, options)` for each method, and `rpc.get` for a GET.

### 5. Call it

A client call is a `connect_colibri.Exchange`. It writes a request for colibri's
`client.ConnectionPool` and reads the response the pool fills in:

```zig
try say_proto.init(.{}, &.{.{ .sentence = "I feel tired" }}, buffers);
_ = try pool.request(&say_proto.request, &say_proto.response);
```

[examples/](examples) holds seven programs, from generated messages alone to streaming,
interceptors, error details and a server on a socket. Each checks itself, and
[examples/README.md](examples/README.md) says where to start.

## Good to know

> [!IMPORTANT]
> A server stream is written into the router's response memory, so a long one is bounded by it
> (decision 12). A type handler streams full-duplex (decision 18); colibri's client sends its
> request body whole, so the client side of a stream is half-duplex. zstd and brotli are read but not written, because stdx has no encoder for them
> yet (decision 10).

Still to come:

- [ ] The [connectrpc conformance suite](https://github.com/connectrpc/conformance) against the
  client and the server
- [ ] A gRPC client, once colibri's client exposes trailers
- [ ] Long server streams, and full-duplex on the client side
- [x] Full-duplex streams on the server, interceptors and error details
- [x] `Any`, `Struct`, `Value` and `ListValue` in JSON
- [x] Editions 2023 and 2024, and proto2 groups
- [ ] Unknown fields kept

## Contributing

The rules of the tree are in [CLAUDE.md](CLAUDE.md), the design and its build plan are in
[docs/design.md](docs/design.md), and each choice with what it beat is in
[docs/decisions.md](docs/decisions.md). Before you send a change, run the same checks CI runs:

```sh
zig build test            # the lint, every module's tests and the examples
tools/generate_check.sh   # buf generate still writes examples/gen and bench/gen
tools/interop_check.sh    # buf curl and curl against the example server
```

To measure the protobuf runtime, run `zig build bench`, or `tools/bench_check.sh`, which also runs
the Go benchmark in `bench/go`, checks that both encode the same bytes, and prints the two side by
side.

## License

connect-zig is licensed under the [Apache License 2.0](LICENSE).
