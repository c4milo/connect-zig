# Examples

Programs a project that depends on connect-zig would write. Each one checks what it receives and
exits with an error when something is wrong, so `zig build examples` runs them all as a test.

Start at the top: each example adds one layer to the one before it.

| Example | What it shows | Run it |
| --- | --- | --- |
| [protobuf_messages.zig](protobuf_messages.zig) | Generated messages in binary and JSON, with no RPC | `zig build example-protobuf_messages` |
| [sans_io_call.zig](sans_io_call.zig) | A whole call through `connect` alone: no socket, no HTTP library | `zig build example-sans_io_call` |
| [eliza.zig](eliza.zig) | A client and a server over colibri's h2 and h11, in memory | `zig build example-eliza` |
| [streaming.zig](streaming.zig) | Bidirectional, client and server streams, and a stream that fails | `zig build example-streaming` |
| [interceptors.zig](interceptors.zig) | Server interceptors that log and authenticate, and client interceptors | `zig build example-interceptors` |
| [errors.zig](errors.zig) | Errors with typed details in Connect, gRPC and gRPC-Web | `zig build example-errors` |
| [socket_server.zig](socket_server.zig) | Both services on a TCP socket, for curl and `buf curl` | `zig build run-eliza-server -- 8080` |

## The services

[services/](services) holds what the programs share:

- [services/eliza.zig](services/eliza.zig) serves `connectrpc.eliza.v1.ElizaService`, with one
  method of each kind: `Say`, unary, which a Connect client may also send as a GET;
  `Introduce`, a server stream; `Converse`, a bidirectional stream.
- [services/demo.zig](services/demo.zig) serves `demo.v1.DemoService`, from
  [proto/demo/v1/demo.proto](proto/demo/v1/demo.proto): `Whoami` behind the `Logging` and `Auth`
  interceptors, `Chat` and `Sum` as type handlers that take each message as it arrives,
  `Countdown`, and `Divide`, which fails with a `DivisionByZero` detail.
- [services/routes.zig](services/routes.zig) puts both under one `server.router`, which
  [services/app.zig](services/app.zig)'s `App` runs.
- [services/link.zig](services/link.zig) is colibri's in-memory link, copied unchanged, which
  stands where sockets would be. [services/link_server.zig](services/link_server.zig) and
  [services/link_client.zig](services/link_client.zig) run the server and the client over it.

### A type handler

A function handler takes a client stream whole. A type handler takes each message as it
arrives, so it answers while the client still sends: over h2 the stream is full-duplex.

```zig
const Chat = struct {
    pub const State = struct { turns: u32 = 0 };

    pub fn on_message(_: *App, _: *adapter.Call, state: *State, request: *const demo.ChatMessage, sender: *adapter.Sender(demo.ChatMessage)) ?connect.RpcError {
        state.turns += 1;
        sender.send(&.{ .text = request.text }) catch return .{ .code = .resource_exhausted };
        return null;
    }

    pub fn on_end(_: *App, _: *adapter.Call, _: *State, _: *adapter.Sender(demo.ChatMessage)) ?connect.RpcError {
        return null;
    }
};
```

### An interceptor

An interceptor is a type that a route lists in its options. `on_call` runs before the handler and
may refuse the call; `on_finish` runs after it and returns the outcome the client reads.

```zig
pub const Auth = struct {
    pub fn on_call(_: *App, call: *adapter.Call) ?connect.RpcError {
        _ = caller_of(call) orelse return .{ .code = .unauthenticated, .message = "a bearer token is required" };
        return null;
    }
};

const guarded: adapter.RouteOptions = .{ .interceptors = &.{ Logging, Auth } };
```

A client interceptor is a type an `ExchangeWith` lists, with `on_request` and `on_response`.

## Generated code

`buf generate` writes [gen/](gen) from [proto/](proto) with the plugin this repository builds:

- `connectrpc/eliza/v1/eliza.proto`: the ELIZA service;
- `demo/v1/demo.proto`: the demo service;
- `coverage/v1/coverage.proto`: every protobuf type, which `tools/coverage_check.sh` converts with
  [coverage.zig](coverage.zig) and with Go, over the cases in [testdata/coverage](testdata/coverage);
- `kitchen/v1/kitchen.proto`: every shape the generator writes, from maps and oneofs to
  recursion and well-known types;
- `large/v1/large.proto`: a file long enough that the plugin splits it into a file for each
  declaration.

[generated_test.zig](generated_test.zig) compiles all of it and round-trips its messages, and
`tools/generate_check.sh` fails when `buf generate` writes anything other than what is committed.

## Try the socket server

```sh
zig build run-eliza-server -- 8080
```

Then, in a second terminal:

```sh
curl --json '{"sentence":"I feel tired"}' \
  http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
buf curl --http2-prior-knowledge --protocol grpc --schema examples/proto \
  -H 'authorization: Bearer Ada' http://127.0.0.1:8080/demo.v1.DemoService/Whoami
buf curl --http2-prior-knowledge --protocol grpc --schema examples/proto \
  -d @- http://127.0.0.1:8080/demo.v1.DemoService/Chat
```

The last command reads one JSON message per line from stdin, and prints each answer as it
arrives, before you end the stream with Ctrl-D.
