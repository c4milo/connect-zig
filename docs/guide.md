# Using connect-zig

This guide takes a service from a `.proto` file to a server and a client. [examples/quickstart](../examples/quickstart)
holds the same steps as a project you can copy, and `tools/package_check.sh` builds it against a
fetched copy of connect-zig on each push.

## 1. Add the package

```sh
zig fetch --save git+https://github.com/c4milo/connect-zig#v0.4.0
```

Then add its one module, `connect_zig`, to your program in `build.zig` ([decision 52](decisions.md)):

```zig
const connect_zig = b.dependency("connect_zig", .{ .target = target, .rotor = true });
module.addImport("connect_zig", connect_zig.module("connect_zig"));
```

The module names each part of the library, colibri's modules, and stdx's `platform`, each the copy
connect-zig builds on. Your program reaches them as fields: `@import("connect_zig").connect`.

| Name | What it is |
| --- | --- |
| `protobuf` | The binary encoding and the proto3 JSON mapping, over generated structs |
| `connect` | The Connect, gRPC, and gRPC-Web rules, as functions over headers and bytes |
| `protovalidate` | The check of a message against the rules of its schema |
| `platform` | stdx's `platform`: the type of the CPU features your program detects and states |
| `connect_colibri` | Routes for colibri's server, and calls for colibri's client |
| `oidc` | The check of an OpenID Connect bearer token, on a host target |
| `server`, `client`, `http`, `tls`, `colibri` | colibri's modules, which `connect_colibri` is built on |
| `buf_validate_validate`, `google_protobuf_descriptor` | The generated code of validate.proto and descriptor.proto |

Do not add colibri or stdx to your own `build.zig.zon`: a second copy of either fails the build
with a file in two modules ([decision 39](decisions.md)). `.rotor = true` builds `colibri.Server`
and `colibri.Client` on [Rotor](https://github.com/c4milo/rotor), colibri's event loop. Without
it, your program drives colibri's engine and pool on its own loop ([decision 32](decisions.md)).

connect-zig probes no CPU. Your program detects its CPU's features once, as it starts, with
`platform.CpuFeatures.detect()`, and states them in a field of its routes' context.

A program that codes messages, checks them, or runs the protocol on an HTTP library of its own
passes `.colibri = false`. Its module then holds no `connect_colibri`, `oidc` or colibri module,
and the program links no chapulin. [examples/std_http](../examples/std_http) serves ELIZA so on
`std.http.Server`, and [examples/protobuf_messages](../examples/protobuf_messages) codes messages
with no RPC.

A program that takes `connect_zig` with colibri links
[chapulin](https://github.com/c4milo/chapulin), the TLS library under colibri. chapulin reports
a failed assertion through one hook, which your program defines once:

```zig
export fn ch_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}
```

Without it, the link fails with `undefined symbol: ch_assert_fail`.

## 2. Generate code

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
generated file as a module, with the modules its header names: `connect_zig`, and the modules of
the files it imports.

```zig
const eliza = b.createModule(.{ .root_source_file = b.path("gen/connectrpc/eliza/v1/eliza.pb.zig") });
eliza.addImport("connect_zig", connect_zig.module("connect_zig"));
module.addImport("eliza", eliza);
```

> [!TIP]
> A generated file imports other generated files by module name. The module of
> `kitchen/v1/shared.proto` is `kitchen_v1_shared`.

## 3. Write a handler

A handler takes the call's context, its request, and its response, as connect-go splits them. It
fills its response and returns `null`, or returns the error the client reads:

```zig
const connect_zig = @import("connect_zig");
const connect = connect_zig.connect;
const rpc = connect_zig.connect_colibri;

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
- `request` holds the message, and `header(name)`, `headers()`, and `query()`.
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
hold the headers, the query, and the trailers, with no message.

## 4. Route it

The routes share one context, your `App`. It holds your program's state, and the CPU features
your program detected: each route reads and writes its messages with them. An `App` with no
field `cpu_features` stops the build.

```zig
const platform = @import("connect_zig").platform;

/// What every route reads: your program's state, and the CPU features it detected as it started.
const App = struct {
    cpu_features: platform.CpuFeatures,
};
```

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

Set the first two above the routes' `message_bytes`. Each call also holds storage of 4 times
`message_bytes`, into which a binary request's repeated fields are read once ([decision 37](decisions.md)).
A decoded message takes more room than its octets. A request whose lists do not fit is still
answered, but each read of such a list parses it again: give your context a field
`messages_past_storage: u64` to count them, and raise the route's `storage_bytes` when it grows.
Each call also holds two buffers of `message_bytes` for its reply. A method whose replies are
short sets `reply_bytes` to the longest it writes, and each call then holds that instead.
`rpc.Refusals` answers 405 with an Allow header to a method Connect does not serve, such as
DELETE, as connect-go does. To give methods options of their own, list each route by hand with
`rpc.post(App, Service.say, say, options)` and `rpc.get`.

`colibri.Server` serves the router on Rotor. A program allocates what it holds once, at the
start:

```zig
const Server = colibri.Server(.{ .tcp_connections = 64, .quic_connections = 8 }, .private);
const State = struct {
    http_server: Server,
    router: Router,
    app: App,
    tls_buffer: [server.Config.tls_buffer_len(64)]u8,
};

const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
    return error.OutOfMemory;
const state: *State = @ptrCast(@alignCast(state_memory));
state.router.init();
// The routes read and write each message with the CPU features the program detects here, once.
state.app = .{ .cpu_features = .detect() };
try state.http_server.init(&.{
    .port = 8443,
    .identity = .{ .chain = chain_pem, .key = key_pem },
    .cpu = cpu,
    .unix_seconds = unix_seconds,
    .engine = .{ .tls_buffer = &state.tls_buffer },
}, &state.router, &state.app);
defer state.http_server.deinit();
try state.http_server.run();
```

Take the `State` from `rawAlloc`, not from `create`. In Debug and ReleaseSafe, `create` writes
the undefined pattern over all of it, so each of its pages is in memory before the first
connection: 318 MiB of the OTLP sink's 331 MB. With `rawAlloc`, a page takes memory only when
the program first writes it, and the sink starts in 6 MiB ([decision 48](decisions.md)).

`init` starts the router where it lies. `state.router = .{}` would copy the router's whole
default value, which the program's image then holds: in the OTLP sink of the benchmarks, 155 MB.

It serves h11 and h2 over TLS on a TCP socket, and h3 on the UDP socket of the same port.
`chain_pem` and `key_pem` are your certificate chain and its key, as PEM text, and `cpu` is what
your program probed of its CPU. `tls_buffer` holds the TLS session of each TCP connection over
TLS, about 83 KB each, for as many connections as it serves at once. With no `identity`, it serves
h11 and h2 in cleartext and no h3, and needs no `tls_buffer`.

## 5. Call it

Two clients make a call. colibri's `client.ConnectionPool` is the HTTP client: it opens each
connection and sends each request. `connect.Client` is Connect's part, which your calls share.
It opens no connection. It holds the CPU features your program detected, and the codecs it
placed in `.encoders` and `.decoders`, none by default, and it builds each request for the
pool. Make it once, as the program starts. A program that serves too gives it the features of
its `App`:

```zig
state.client = .{ .cpu_features = state.app.cpu_features };
```

A client call is a `connect_colibri.ClientCall(method, .{})`. It takes the client first, writes
a request for colibri's `client.ConnectionPool`, and reads the response the pool fills in:

```zig
try say.init(&state.client, {}, &.{ .protocol = .grpc }, &.{.{ .sentence = "I feel tired" }}, &buffers);
_ = try pool.request(&say.request, &say.response);
// Once the pool reports the call finished:
var response = say.read(storage);
const answer = try response.next(eliza.SayResponse);
if (response.failure) |failure| std.debug.print("{s}\n", .{failure.message});
```

`.protocol` picks Connect (the default), gRPC, or gRPC-Web, and the rest of the call stays the same.
On Rotor, `colibri.Client(.{}, .private)` holds the pool. Over TLS, the pool's configuration
names what it trusts:

```zig
const anchors = try tls.pem.anchors(ca_pem, &anchor_der, &anchor_room);
const trust: tls.Trust = .{ .web_pki = .{ .anchors = anchors, .server_name = "api.example.com" } };
const config: client.Config = .{ .tls = .{ .trust = trust, .cpu = cpu }, .authority = "api.example.com" };
```

A client or bidirectional stream can stream both ways: `init_stream` builds the call, and its
`Sender` sends each message while the program reads each answer as it arrives.
[examples/streaming](../examples/streaming) shows the pool's events for such a call.

A client call lists interceptors of its own in its options. `on_request(context, request)` may
add headers, and `on_response(context, response)` sees each response's head. `context` is the
value that `init` takes, of the type the options name as `Context` ([decision 44](decisions.md)). A `*State`
lets an interceptor count what it sees. A call with no context passes `{}`.

## 6. Require a bearer token

The `oidc` module checks a JWT that an OpenID Connect provider signed with RS256, ES256, or
EdDSA. It does no I/O and reads no clock: your program fetches the provider's JWK Set and passes
its text and the time. It is a field of the module, as the others are:

```zig
const oidc = @import("connect_zig").oidc;

// The context of your routes holds the verifier, as `app.oidc`. Its JSON readers take the CPU
// features your program detected once, the context's own.
try app.oidc.init(&.{ .issuer = "https://accounts.example.com", .audience = "my-service", .cpu_features = app.cpu_features });
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
`exp`, and `nbf` ([decision 34](decisions.md)). A call with no valid token gets `unauthenticated` and a
`WWW-Authenticate: Bearer` header. On an excluded path, `oidc` stays null. `oidc` checks
signatures with chapulin, which colibri already links, so it adds no second crypto library.

The route table's `.Values` serves any interceptor: it is a struct you declare, and each call
starts with its defaults ([decision 35](decisions.md)). One table names one type for all its routes, so a table
that joins services declares one struct with the fields of each.

## 7. Validate a message

The `protovalidate` module checks a message against the rules its schema states.
[protovalidate.md](protovalidate.md) is its guide.

## Streams

> [!IMPORTANT]
> A function handler writes its whole stream in one call, so the router's response memory bounds
> it ([decision 12](decisions.md)). A long stream takes a type handler with `next`, which gives one message at a
> time ([decision 33](decisions.md)). Over h11 both sides of a stream are half-duplex.

## Protobuf editions

Editions 2023 and 2024 follow [protobuf.dev's editions
overview](https://protobuf.dev/editions/overview/): field presence, packed and expanded repeated
fields, delimited messages, closed enums, and `utf8_validation`. The library does not report a
missing required field ([decision 23](decisions.md)).

## More examples

[examples/](../examples) holds twelve projects, each a Zig project you can copy ([decision 41](decisions.md)). They
range from generated messages to streaming, interceptors, error details, bearer tokens, a
GitHub-style API, an OpenTelemetry trace receiver, and a socket server. Each checks itself
with `zig build test`, and serves its service with `zig build serve` for curl and `buf curl`.
[examples/std_io](../examples/std_io) runs with no Rotor: it drives colibri's engine over Zig's
`std.Io`. [examples/README.md](../examples/README.md) says where to start.
