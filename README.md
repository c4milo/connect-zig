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
fn say(app: *App, _: *adapter.Call, request: *const eliza.SayRequest, response: *eliza.SayResponse) ?connect.RpcError {
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

### 4. Route it

Each method becomes a route of colibri's `server.router`. One route answers every protocol and
codec, so there is nothing else to configure:

```zig
pub const routes = server.router(App, .{
    .error_handler = on_error,
    .routes = .{
        adapter.post(App, Service.say, say, route_options),
        adapter.get(App, Service.say, say, route_options),
        adapter.post(App, Service.introduce, introduce, route_options),
        adapter.post(App, Service.converse, converse, route_options),
    },
});
```

### 5. Call it

A client call is a `connect_colibri.Exchange`. It writes a request for colibri's
`client.ConnectionPool` and reads the response the pool fills in:

```zig
try say_proto.init(.{}, &.{.{ .sentence = service.said }}, buffers_of(0));
try introduce.init(.{ .protocol = .grpc_web }, &.{.{ .name = service.name }}, buffers_of(2));
_ = try pool.request(&say_proto.request, &say_proto.response);
```

The whole client and server are in [examples/eliza](examples/eliza). They are the best place to
start reading.

## Good to know

> [!IMPORTANT]
> In this first version, a stream is read whole and written into the router's response memory.
> A long server stream is bounded by that memory, and a bidirectional stream is half-duplex
> (decision 12). zstd and brotli are read but not written, because stdx has no encoder for them
> yet (decision 10).

Still to come:

- [ ] The [connectrpc conformance suite](https://github.com/connectrpc/conformance) against the
  client and the server
- [ ] A gRPC client, once colibri's client exposes trailers
- [ ] Long and full-duplex streams
- [ ] `Any`, `Struct`, `Value` and `ListValue` in JSON, and unknown fields kept

## Contributing

The rules of the tree are in [CLAUDE.md](CLAUDE.md), the design and its build plan are in
[docs/design.md](docs/design.md), and each choice with what it beat is in
[docs/decisions.md](docs/decisions.md). Before you send a change, run the same checks CI runs:

```sh
zig build test            # the lint, every module's tests and the examples
tools/generate_check.sh   # buf generate still writes examples/gen
tools/interop_check.sh    # buf curl and curl against the ELIZA server
```

## License

connect-zig is licensed under the [Apache License 2.0](LICENSE).
