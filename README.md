# connect-zig

[![CI](https://github.com/c4milo/connect-zig/actions/workflows/main.yml/badge.svg)](https://github.com/c4milo/connect-zig/actions/workflows/main.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16.0-f7a41d.svg)](https://ziglang.org/download/#release-0.16.0)

**[Connect RPC](https://connectrpc.com/) for Zig.** Write a `.proto` file, run `buf generate`,
and serve the same handlers to Connect, gRPC and gRPC-Web clients, in binary protobuf or JSON.

- **No allocator in the library.** Every buffer is yours, and every size is a constant you can
  read.
- **No copies.** Decoding leaves strings, bytes and repeated fields pointing into the input, and
  each RPC message is encoded straight into the HTTP body it goes out in.
- **No hidden I/O.** The protocol core reads bytes you give it and writes bytes you send. It
  reads no clock, so every test is deterministic.
- **Fast.** Binary and JSON encoding and decoding run 1.5 to 6 times faster than Go's protobuf
  runtime on most messages (see [Performance](#performance)).
- **HTTP underneath from [colibri](https://github.com/c4milo/colibri).** Servers and clients run
  over h11, h2 and h3. The in-memory examples and the socket server run over all three;
  the socket server serves h3 on the UDP socket of its port, under a test-only identity.

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
| `connect_colibri` | Routes for colibri's server, and calls for colibri's client. Programs import it as `rpc`. |
| `protoc-gen-connect-zig` | The plugin `buf generate` runs to write your `.pb.zig` files. |

### What works today

| | Connect | gRPC | gRPC-Web |
| --- | :---: | :---: | :---: |
| Server: unary, all streams | ✅ | ✅ | ✅ |
| Client: unary, all streams | ✅ | ✅ | ✅ |
| Proto and JSON codecs | ✅ | ✅ | ✅ |
| gzip and zstd both ways, brotli read | ✅ | ✅ | ✅ |
| Unary GET for `NO_SIDE_EFFECTS` | ✅ | | |
| Full-duplex bidirectional streams (server) | ✅ | ✅ | ✅ |
| Full-duplex bidirectional streams (client) | | | |
| Interceptors, server and client | ✅ | ✅ | ✅ |
| Error details | ✅ | ✅ | ✅ |

The protobuf runtime covers every scalar type, `optional`, packed and unpacked repeated fields,
maps with every key type, oneofs, enums, recursive messages and every well-known type with its
JSON form: Timestamp, Duration, FieldMask, the wrappers, Empty, Struct, Value, ListValue and Any.
It reads proto2, proto3 and editions 2023 and 2024, groups and DELIMITED fields included. A
message keeps the fields its schema does not know and writes them back, so an older service
passes newer fields on.

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
const connect = @import("connect");
const rpc = @import("connect_colibri");

pub fn say(app: *App, _: *rpc.Call, request: *const eliza.SayRequest, response: *eliza.SayResponse) ?connect.RpcError {
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
refuse the call, and `on_finish` sees the outcome. A client's `rpc.ClientCallWith` takes
interceptors with `on_request`, which may add headers, and `on_response`.

### 4. Route it

Each generated service has a `Routes` function. It lists every method as a route of colibri's
`server.router`, with the handler of the same name, and a unary method with no side effects as a
GET too. A method you have no handler for fails to compile. One route answers every protocol and
codec:

```zig
pub fn say(app: *App, call: *rpc.Call, request: *const eliza.SayRequest, response: *eliza.SayResponse) ?connect.RpcError { ... }
pub fn introduce(...) ?connect.RpcError { ... }
pub fn converse(...) ?connect.RpcError { ... }

pub const routes = server.router(App, .{
    .error_handler = on_error,
    .routes = Service.Routes(rpc, App, @This(), route_options).routes ++
        rpc.Refusals(App, Service.say).routes,
});
```

`rpc.Refusals` makes a method Connect does not serve, such as DELETE, get 405 with an Allow
header on every path, as connect-go answers. A table names it once, for any one method.

To give methods different options, such as their own interceptors, list routes by hand:
`rpc.post(App, Service.say, say, options)` for each method, and `rpc.get` for a GET.

### 5. Call it

A client call is a `connect_colibri.ClientCall`. It writes a request for colibri's
`client.ConnectionPool` and reads the response the pool fills in:

```zig
try say.init(.{ .protocol = .grpc }, &.{.{ .sentence = "I feel tired" }}, buffers);
_ = try pool.request(&say.request, &say.response);
// Once the pool reports the call finished:
var response = say.read(storage);
const answer = try response.next(eliza.SayResponse);
if (response.failure) |failure| std.debug.print("{s}\n", .{failure.message});
```

`.protocol` picks Connect, the default, gRPC or gRPC-Web, and the rest of the call stays the same.
A gRPC call reads its status from the response's trailers.

[examples/](examples) holds eight programs, from generated messages alone to streaming,
interceptors, error details, a GitHub-style API with tokens, rate limits, pages and field masks,
and a server on a socket. Each checks itself, and
[examples/README.md](examples/README.md) says where to start.

## Performance

`zig build bench` times four messages, and `tools/bench_check.sh` runs Go's
`google.golang.org/protobuf` beside it on the same inputs and checks both write the same bytes.
Each cell is Go's time over connect-zig's: above 1 means connect-zig is faster.

| Message | Binary encode | Binary decode, every field read | JSON encode | JSON decode |
| --- | ---: | ---: | ---: | ---: |
| Small, 40 B | 4.3 | 4.4 | 3.4 | 4.0 |
| Medium, 1 KB | 4.9 | 3.6 | 4.4 | 5.2 |
| Large, 180 KB | 1.0 | 1.5 | 2.8 | 5.0 |
| Deep, 50 levels | 1.9 | 2.2 | 4.0 | 3.2 |

## How it is checked

- `zig build test` runs every module's tests and the examples, and each check in the library was
  broken on purpose to prove a test catches it. The examples run a client against the server in
  memory over h11 and h2 in cleartext, and over h3 under a test-only TLS identity.
- `tools/coverage_check.sh` converts every protobuf type, and edition and proto2 files, with
  connect-zig and with Go's runtime through `buf convert`, in each direction between binary and
  JSON, and requires the same message.
- `tools/interop_check.sh` calls the example server with `buf curl`, connect-go's client, in all
  three protocols, and with curl over h11 and h2. It requires a bidirectional stream to answer
  before the client finishes sending.
- `tools/conformance_check.sh` runs the [connectrpc conformance
  suite](https://github.com/connectrpc/conformance) v1.0.4 against a conformance server: 2714
  cases in Connect, gRPC and gRPC-Web, over h11 and h2, in proto and JSON, with gzip and zstd.
  All 2714 pass.
- `tools/interop_languages_check.sh` calls the server from [clients in other
  languages](interop): connect-go and grpc-go, connect-es on Node, Python's grpcio and Rust's
  tonic. Each echoes every coverage case, in every protocol, codec and compression its library
  speaks, and runs every stream shape, a typed error, a timeout, headers and trailers: 507 calls.
- `tools/perf_check.sh` counts the instructions of each benchmark operation under callgrind and
  fails when one takes more than 2% above `bench/instructions.txt`. Counts do not move with a
  shared runner's load, so CI catches a regression that wall time would hide.

CI runs each check as a job of its own, so each shows apart among a change's checks, and writes
its results to the job's summary: the interop matrix, the instruction table, the conformance
totals. A failure also shows as an annotation on the change.

## Good to know

> [!IMPORTANT]
> A server stream is written into the router's response memory, so a long one is bounded by it
> (decision 12). A type handler streams full-duplex (decision 18); colibri's client sends its
> request body whole, so the client side of a stream is half-duplex. brotli is read but not
> written yet, since stdx has no brotli encoder (decision 10).

Editions 2023 and 2024 follow [protobuf.dev's editions
overview](https://protobuf.dev/editions/overview/): field presence, packed and expanded repeated
fields, delimited messages, closed enums and `utf8_validation`. A number a closed enum does not
name goes to the unknown fields, as upb keeps it, and is written back. One difference remains: the
library does not report a missing required field (decision 23).

Still to come:

- [x] The [connectrpc conformance suite](https://github.com/connectrpc/conformance) against the
  server
- [ ] The conformance suite against the client, once colibri's client streams a request body
  (colibri step 39)
- [x] HTTP/3 on the socket server, over a UDP socket
- [x] zstd compression of messages, both ways
- [ ] brotli compression of messages, once stdx ships its encoder
- [x] A gRPC client, over h11, h2 and h3
- [ ] Long server streams, and full-duplex on the client side (colibri step 39)
- [x] HTTP/3 in the in-memory examples, with a test-only TLS identity
- [x] Full-duplex streams on the server, interceptors and error details
- [x] `Any`, `Struct`, `Value` and `ListValue` in JSON
- [x] Editions 2023 and 2024, and proto2 groups
- [x] Unknown fields kept and written back

## Contributing

The rules of the tree are in [CLAUDE.md](CLAUDE.md), the design and its build plan are in
[docs/design.md](docs/design.md), and each choice with what it beat is in
[docs/decisions.md](docs/decisions.md). Before you send a change, run the same checks CI runs:

```sh
tools/ci.sh               # every check below, as CI runs them
zig build test            # the lint, every module's tests and the examples
tools/generate_check.sh   # buf generate still writes examples/gen and bench/gen
tools/interop_check.sh    # buf curl and curl against the example server
tools/coverage_check.sh   # every protobuf type against Go's runtime
tools/conformance_check.sh  # the connectrpc conformance suite against the server
tools/interop_languages_check.sh  # Go, TypeScript, Python and Rust clients against the server
tools/perf_check.sh       # instructions of each benchmark operation against the baseline
tools/bench_check.sh      # the benchmark beside Go's
```

## License

connect-zig is licensed under the [Apache License 2.0](LICENSE).
