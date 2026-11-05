# connect-zig

[Connect RPC](https://connectrpc.com/) for Zig 0.16: Connect, gRPC and gRPC-Web servers and
clients, with no allocator in the library. It holds:

- `protobuf`: the protobuf binary encoding and the proto3 JSON mapping, over generated structs.
  Decoding copies nothing: strings and repeated fields point into the input.
- `connect`: the Connect, gRPC and gRPC-Web protocols as functions over header values and body
  bytes. It does no I/O and reads no clock.
- `connect_colibri`: servers and clients over [colibri](https://github.com/c4milo/colibri)'s h11,
  h2 and h3.
- `protoc-gen-connect-zig`: the protoc plugin that `buf generate` runs.

What works, and what a later step owes, is in [docs/design.md](docs/design.md) §8. The choices
and what each beat are in [docs/decisions.md](docs/decisions.md).

## Generate code

Build the plugin, then name it in `buf.gen.yaml`:

```yaml
version: v2
plugins:
  - local: zig-out/bin/protoc-gen-connect-zig
    out: gen
```

`buf generate` writes one `<file>.pb.zig` for each `.proto` file, split into a file for each
declaration past 500 lines. A message is a struct with a `FieldNumber` enum, an enum a
non-exhaustive `enum(i32)`, and each RPC a `connect.Method`. The code passes the same lint rules
as the library (decision 17).

A generated file imports other modules by name, and its header lists them: `protobuf`, `connect`
when it declares a service, and one module for each `.proto` file it imports. The module of
`kitchen/v1/shared.proto` is `kitchen_v1_shared`:

```zig
const shared = b.createModule(.{ .root_source_file = b.path("gen/kitchen/v1/shared.pb.zig") });
shared.addImport("protobuf", connect_zig.module("protobuf"));
kitchen.addImport("kitchen_v1_shared", shared);
```

## Serve

A handler fills its response and returns null, or returns the error the client reads. Each
method becomes a route of colibri's `server.router`:

```zig
fn say(app: *App, _: *adapter.Call, request: *const eliza.SayRequest, response: *eliza.SayResponse) ?connect.RpcError {
    app.calls += 1;
    if (request.sentence.len == 0) return .{ .code = .invalid_argument, .message = "say something" };
    response.sentence = reply(app, "You said \"{s}\". How does that make you feel?", .{request.sentence});
    return null;
}

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

The route reads the protocol from each request, so one route answers Connect, gRPC and gRPC-Web,
in the proto and JSON codecs. [examples/eliza/socket_server.zig](examples/eliza/socket_server.zig)
serves it on a TCP socket:

```sh
zig build run-eliza-server -- 8080
curl --json '{"sentence":"I feel tired"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
```

## Call

A client call is a `connect_colibri.Exchange`, which writes a `client.Request` for colibri's
`client.ConnectionPool` and reads the `client.Response` it fills:

```zig
try say_proto.init(.{}, &.{.{ .sentence = service.said }}, buffers_of(0));
try introduce.init(.{ .protocol = .grpc_web }, &.{.{ .name = service.name }}, buffers_of(2));
_ = try pool.request(&say_proto.request, &say_proto.response);
```

[examples/eliza/exchange.zig](examples/eliza/exchange.zig) runs a client against the server
over h2 and h11 and checks every answer. The client speaks Connect and gRPC-Web. Plain gRPC needs
response trailers, which colibri's client does not expose yet (decision 11).

## Add it to a project

```zig
const connect_zig = b.dependency("connect_zig", .{ .target = target });
module.addImport("protobuf", connect_zig.module("protobuf"));
module.addImport("connect", connect_zig.module("connect"));
module.addImport("connect_colibri", connect_zig.module("connect_colibri"));
```

## Check it

```sh
zig build test             # the lint, every module's tests, the examples
tools/generate_check.sh    # buf generate equals examples/gen
tools/interop_check.sh     # buf curl and curl against the socket server
```

## License

Apache-2.0. See [LICENSE](LICENSE).
