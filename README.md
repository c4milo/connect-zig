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
- **Fast.** Binary and JSON encoding and decoding run 1.6 to 16 times faster than Go's protobuf
  runtime (see [Performance](#performance)).
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
curl --cacert examples/testdata/tls/ca.pem --json '{"sentence":"I feel tired"}' \
  https://localhost:8080/connectrpc.eliza.v1.ElizaService/Say
```

```json
{"sentence":"You said \"I feel tired\". How does that make you feel?"}
```

The same server answers [`buf curl`](https://buf.build/docs/reference/cli/buf/curl) in every
protocol, over h2 or, with `--http3`, h3. Try `--protocol grpc` or `--protocol grpcweb`:

```sh
buf curl --cacert examples/testdata/tls/ca.pem --protocol grpc --schema examples/proto \
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
| Full-duplex bidirectional streams (server) | ✅ | ✅ | ✅ |
| Full-duplex bidirectional streams (client), over h2 and h3[^duplex] | ✅ | ✅ | ✅ |
| Interceptors, server and client | ✅ | ✅ | ✅ |
| Error details | ✅ | ✅ | ✅ |

[^get]: The Connect protocol defines Unary-Get. gRPC's HTTP/2 spec requires `:method POST`, and
    gRPC-Web keeps that request shape.
[^duplex]: Over h11 a stream is half-duplex, on the client as on the server: the whole request
    goes before the response is read. The Connect protocol leaves the duplex a stream can use to
    the HTTP version, and proxies that buffer an HTTP/1.1 body would stall an interleaved one.

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

- `ctx: *rpc.Context` is the call: `path()`, `protocol()`, `codec()`, `timeout_ns()`, the
  counts `received()` and `sent()`, and `values(T)`, your own values for this call.
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

Interceptors are types a route lists in its options: `on_call(app, ctx, request, response)`
runs before the handler and may refuse the call, and `on_finish(app, ctx, response, failure)`
sees the outcome. Their request and response are `rpc.AnyRequest` and `rpc.AnyResponse`: the
headers, the query and the trailers, with no message. A client's `rpc.ClientCall` lists its own in
its options, with `on_request`, which may add headers, and `on_response`.

### 4. Route it

Each generated service has a `Routes` function. It lists every method as a route of colibri's
`server.Router`, with the handler of the same name, and a unary method with no side effects as a
GET too. A method you have no handler for fails to compile. One route answers every protocol and
codec:

```zig
pub fn say(app: *App, ctx: *rpc.Context, request: *const rpc.Request(eliza.SayRequest), response: *rpc.Response(eliza.SayResponse)) ?connect.RpcError { ... }
pub fn introduce(...) ?connect.RpcError { ... }
pub fn converse(...) ?connect.RpcError { ... }

pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = Service.Routes(rpc, App, @This(), route_options).routes ++
        rpc.Refusals(App, Service.say).routes,
}, .{ .requests = 8 });
```

`rpc.Refusals` makes a method Connect does not serve, such as DELETE, get 405 with an Allow
header on every path, as connect-go answers. A table names it once, for any one method.

To give methods different options, such as their own interceptors, list routes by hand:
`rpc.post(App, Service.say, say, options)` for each method, and `rpc.get` for a GET.

### 5. Call it

A client call is a `connect_colibri.ClientCall(method, .{})`. It writes a request for colibri's
`client.ConnectionPool` and reads the response the pool fills in:

```zig
try say.init(&.{ .protocol = .grpc }, &.{.{ .sentence = "I feel tired" }}, &buffers);
_ = try pool.request(&say.request, &say.response);
// Once the pool reports the call finished:
var response = say.read(storage);
const answer = try response.next(eliza.SayResponse);
if (response.failure) |failure| std.debug.print("{s}\n", .{failure.message});
```

`.protocol` picks Connect, the default, gRPC or gRPC-Web, and the rest of the call stays the same.
A gRPC call reads its status from the response's trailers.

A client or bidirectional stream can also stream both ways. `init_stream` builds the call, and its
`Sender` sends each message, as the server's `ResponseStream` does. The program passes the pool's events for the
call on, and reads each answer as it arrives:

```zig
try chat.init_stream(&.{}, &buffers);
try chat.start(&pool);
var sender = chat.sender();
try sender.send(&.{ .text = "hello" });
// On the pool's events for chat.id:
//   .headers => chat.on_headers(storage),
//   .body => |piece| chat.on_body(piece.len), then chat.reader.next(demo.ChatMessage),
//   .body_taken => try chat.on_body_taken(),
// and, once every line went, try sender.close_send(). When the pool reports it finished:
var response = chat.read(storage);
```

### 6. Require a bearer token

The `oidc` module checks the token an OpenID Connect provider issued: a JWT signed with RS256,
ES256 or EdDSA. It does no I/O and reads no clock. Your program fetches the provider's JWK Set,
and passes its text and the time:

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
const options: rpc.RouteOptions = .{ .interceptors = &.{Auth}, .Values = Values };
pub const routes = Service.Routes(rpc, App, @This(), options).routes;

// In any callback of a call behind the interceptor, a stream's tenth message included:
if (ctx.values(Values).oidc) |*claims| {
    std.debug.print("{s}\n", .{claims.subject()});
    const email = try claims.string("email"); // ?[]const u8
    const admin = try claims.holds("roles", "admin"); // in an array, or equal
    const since = try claims.integer("auth_time"); // ?i64
}
```

The verifier checks the signature first, with the key the token's header names. It then checks
the issuer, the audience, `exp` and `nbf` (decision 34). A call with no valid token gets
`unauthenticated` and a `WWW-Authenticate: Bearer` header. On an excluded path, the call's
`oidc` stays null.

`RouteOptions.Values` serves any interceptor, not `oidc` alone: it is a struct you declare, and
each call starts with its defaults. An interceptor and a handler read it with
`ctx.values(Values)` (decision 35). It holds your values alone: the call's path and timeout
are on `ctx`, and the headers on the request. Your `App` is still the one value every call
shares.

> [!IMPORTANT]
> `oidc` checks signatures with chapulin's `jws` calls, which chapulin v0.6.0 holds. colibri
> v0.16.1 links chapulin v0.5.0, and one program cannot link both. So a server on
> `connect_colibri` cannot import `oidc` until a colibri release pins chapulin v0.6.0. Until
> then the module's own tests prove it: `zig build test-oidc`.

[examples/](examples) holds ten programs, from generated messages alone to streaming,
interceptors, error details, a GitHub-style API with tokens, rate limits, pages and field masks,
and a server on a socket. Each checks itself, and
[examples/README.md](examples/README.md) says where to start.

The library runs on any event loop (decision 32). The in-memory examples and the socket server
run on [Rotor](https://github.com/c4milo/rotor). `examples/std_io_server.zig` runs on no loop at
all: it drives colibri's `server.Engine` over Zig 0.16's `std.Io` sockets, tasks and clocks, and
`zig build example-std-io` calls it over TCP with connect-zig's client, which runs on `std.Io` too.

## Performance

`zig build bench` times eight messages. `tools/bench_check.sh` runs two baselines beside it on
the same inputs: Go's `google.golang.org/protobuf` v1.36.12, and Buffa, the Rust runtime of
connect-rust. It checks that each writes the same bytes as connect-zig. Each cell is a
baseline's time over connect-zig's: above 1 means connect-zig is faster. The numbers come from
CI's `bench-compare` job of commit `ce62759`
([run 86](https://github.com/c4milo/connect-zig/actions/runs/43085757478)), on GitHub's
`ubuntu-24.04` runner. The three programs ran in the same job. Each run publishes the full table
in its summary: every time, and the four one-kind messages.

![connect-zig is 2.1 to 13.2 times faster than Go's protobuf runtime; Rust's Buffa is faster in 7 of 16 cells](docs/images/speed-vs-go.svg)

Go's time over connect-zig's:

| Message | Binary encode | Binary decode, every field read | JSON encode | JSON decode |
| --- | ---: | ---: | ---: | ---: |
| Small, 40 B | 2.5 | 5.4 | 6.9 | 10.3 |
| Medium, 1 KB | 5.6 | 4.1 | 8.0 | 13.2 |
| Large, 180 KB | 2.1 | 2.1 | 7.3 | 10.4 |
| Deep, 50 levels | 3.5 | 2.7 | 10.3 | 9.9 |

Buffa's time over connect-zig's:

| Message | Binary encode | Binary decode, every field read | JSON encode | JSON decode |
| --- | ---: | ---: | ---: | ---: |
| Small, 40 B | 0.43 | 2.02 | 0.85 | 1.22 |
| Medium, 1 KB | 0.61 | 0.84 | 1.16 | 1.57 |
| Large, 180 KB | 0.74 | 1.03 | 1.67 | 1.19 |
| Deep, 50 levels | 0.94 | 1.08 | 0.83 | 1.56 |

Buffa is faster in 7 of the 16 cells: binary encode of each message, JSON encode of the small
and deep ones, and binary decode of the medium one. connect-zig is faster in the other 9, JSON
decode of each message among them.

## How it is checked

- `zig build test` runs every module's tests and the examples, and each check in the library was
  broken on purpose to prove a test catches it. The examples run a client against the server in
  memory over h11 and h2 in cleartext, and over h3 under a test-only TLS identity.
- `tools/coverage_check.sh` converts every protobuf type, and edition and proto2 files, with
  connect-zig and with Go's runtime through `buf convert`, in each direction between binary and
  JSON, and requires the same message.
- `tools/interop_check.sh` calls the example server with `buf curl`, connect-go's client, in all
  three protocols, and with curl over h11 and h2. It requires a bidirectional stream to answer
  before the client finishes sending, and it reads a server stream of 200000 messages, about
  1.6 MiB through 64 KiB of response memory, over h2 and h3.
- `tools/conformance_check.sh` runs the [connectrpc conformance
  suite](https://github.com/connectrpc/conformance) v1.0.4 against a conformance server: 2714
  cases in Connect, gRPC and gRPC-Web, over h11 and h2, in proto and JSON, with gzip and zstd.
  All 2714 pass. It then runs the suite's reference server against the conformance client:
  8264 cases, over h11, h2 and h3, in cleartext and over TLS. 8263 pass; the one left is a
  timing case of the reference server, listed in `conformance/client_known_flaky.txt` with its
  reason.
- `tools/interop_languages_check.sh` calls the server from [clients in other
  languages](interop): connect-go and grpc-go, connect-es on Node, Python's grpcio, and Rust's
  tonic and connect-rust. Each echoes every coverage case, in every protocol, codec and
  compression its library speaks, and runs every stream shape, a typed error, a timeout, headers
  and trailers: 758 calls.
- `tools/interop_servers_check.sh` runs the mirror: connect-zig's client calls [servers in other
  languages](interop#the-server-side), connect-go and grpc-go, connect-node, grpcio and
  connect-rust, with every coverage case in Connect proto and JSON with GET, gRPC and gRPC-Web,
  over h2 and HTTP/1.1, with gzip, every stream shape, a typed error, a timeout, headers and
  trailers: 831 calls.
- `tools/package_check.sh` fetches the tracked files into a new project, as `zig fetch` keeps
  them, and builds it: the three library modules and the plugin.
- `oidc`'s tests verify the known answers of RFC 7515 and RFC 8037, RS256 tokens that OpenSSL
  signs, and ES256 and EdDSA tokens that Zig's standard library signs, so each signature
  chapulin checks comes from another implementation.
- `tools/perf_check.sh` counts the instructions of each benchmark operation under callgrind and
  fails when one takes more than 2% above `bench/instructions.txt`. Counts do not move with a
  shared runner's load, so CI catches a regression that wall time would hide.

CI runs each check as a job of its own, so each shows apart among a change's checks, and writes
its results to the job's summary: the interop matrix, the instruction table, the conformance
totals. A failure also shows as an annotation on the change.

## Good to know

> [!IMPORTANT]
> A function handler writes its whole stream in one call, into the router's response memory, so
> that memory bounds it (decision 12). A long stream takes a type handler with `next`, which
> gives one message at a time (decision 33). It cannot yet wait for an event of the program
> once its request ended. A type handler streams full-duplex, and so does a client's streamed
> call, over h2 and h3 (decision 18). Over h11 both sides are half-duplex. brotli is read but
> not written yet, since stdx has no brotli encoder (decision 10).

Editions 2023 and 2024 follow [protobuf.dev's editions
overview](https://protobuf.dev/editions/overview/): field presence, packed and expanded repeated
fields, delimited messages, closed enums and `utf8_validation`. A number a closed enum does not
name goes to the unknown fields, as upb keeps it, and is written back. One difference remains: the
library does not report a missing required field (decision 23).

Still to come:

- [x] The [connectrpc conformance suite](https://github.com/connectrpc/conformance) against the
  server
- [x] The conformance suite against the client
- [x] HTTP/3 on the socket server, over a UDP socket
- [x] zstd compression of messages, both ways
- [ ] brotli compression of messages, once stdx ships its encoder
- [x] A gRPC client, over h11, h2 and h3
- [x] Full-duplex streams on the client side, over h2 and h3
- [x] The client against servers in Go, TypeScript, Python and Rust
- [x] Long server streams
- [x] OpenID Connect bearer tokens, checked on the server
- [ ] `oidc` beside `connect_colibri` in one program, once colibri pins chapulin v0.6.0
- [x] HTTP/3 in the in-memory examples, with a test-only TLS identity
- [x] Full-duplex streams on the server, interceptors and error details
- [x] `Any`, `Struct`, `Value` and `ListValue` in JSON
- [x] Editions 2023 and 2024, and proto2 groups
- [x] Unknown fields kept and written back

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) is the summary, and [SECURITY.md](SECURITY.md) says where to
report a vulnerability. The rules of the tree are in [CLAUDE.md](CLAUDE.md), the design and its build plan are in
[docs/design.md](docs/design.md), and each choice with what it beat is in
[docs/decisions.md](docs/decisions.md). Before you send a change, run the same checks CI runs:

```sh
tools/ci.sh               # every check below, as CI runs them
zig build test            # the lint, every module's tests and the examples
tools/package_check.sh    # a project that fetches connect-zig builds against it
tools/generate_check.sh   # buf generate still writes examples/gen and bench/gen
tools/interop_check.sh    # buf curl and curl against the example server
tools/coverage_check.sh   # every protobuf type against Go's runtime
tools/conformance_check.sh  # the connectrpc conformance suite against the server and client
tools/interop_languages_check.sh  # Go, TypeScript, Python and Rust clients against the server
tools/interop_servers_check.sh    # the client against Go, TypeScript, Python and Rust servers
tools/perf_check.sh       # instructions of each benchmark operation against the baseline
tools/bench_check.sh      # the benchmark beside Go's
```

## Changelog

[CHANGELOG.md](CHANGELOG.md) lists what each release adds and changes.

## License

connect-zig is licensed under the [Apache License 2.0](LICENSE).
