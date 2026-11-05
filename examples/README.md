# Examples

Programs a project that depends on connect-zig would write. Each one checks what it receives and
exits with an error when something is wrong, so `zig build examples` runs them all as a test.

Start at the top: each example adds one layer to the one before it.

| Example | What it shows | Run it |
| --- | --- | --- |
| [protobuf_messages.zig](protobuf_messages.zig) | Generated messages in binary and JSON, with no RPC | `zig build example-protobuf_messages` |
| [sans_io_call.zig](sans_io_call.zig) | A whole call through `connect` alone: no socket, no HTTP library | `zig build example-sans_io_call` |
| [eliza.zig](eliza.zig) | A client and a server over colibri's h2, h11 and h3, in memory | `zig build example-eliza` |
| [streaming.zig](streaming.zig) | Bidirectional, client and server streams, and a stream that fails, over h2, h11 and h3 | `zig build example-streaming` |
| [interceptors.zig](interceptors.zig) | Server interceptors that log and authenticate, and client interceptors, over h2 and h3 | `zig build example-interceptors` |
| [errors.zig](errors.zig) | Errors with typed details in Connect, gRPC and gRPC-Web, over h2 and h3 | `zig build example-errors` |
| [github.zig](github.zig) | A GitHub-style API used as a real client would: tokens, rate limits, pages, field masks, private resources, streams | `zig build example-github` |
| [socket_server.zig](socket_server.zig) | Both services on a TCP socket, for curl and `buf curl` | `zig build run-eliza-server -- 8080` |

## The services

[services/](services) holds what the programs share:

- [services/eliza.zig](services/eliza.zig) serves `connectrpc.eliza.v1.ElizaService` through
  its generated `Routes`, with one method of each kind: `Say`, unary, which a Connect client may also send as a GET;
  `Introduce`, a server stream; `Converse`, a bidirectional stream.
- [services/demo.zig](services/demo.zig) serves `demo.v1.DemoService`, from
  [proto/demo/v1/demo.proto](proto/demo/v1/demo.proto): `Whoami` behind the `Logging` and `Auth`
  interceptors, `Chat` and `Sum` as type handlers that take each message as it arrives,
  `Countdown`, and `Divide`, which fails with a `DivisionByZero` detail.
- [services/github.zig](services/github.zig) and [services/github_issues.zig](services/github_issues.zig)
  serve `github.v1.RepositoryService` and `github.v1.IssueService`, from
  [proto/github/v1/github.proto](proto/github/v1/github.proto), over the fixed tables of
  [services/github_store.zig](services/github_store.zig). Every route runs behind `Auth`, which
  reads a bearer token, and `RateLimit`, which counts each caller's calls and sets GitHub's
  `x-ratelimit-*` headers. Failures carry `NotFound`, `AlreadyExists`, `BadField` and
  `RateLimited` details, and a private repository reads as not found to anyone but its owner.
- [services/routes.zig](services/routes.zig) puts all three under one `server.router`, which
  [services/app.zig](services/app.zig)'s `App` runs.
- [services/link.zig](services/link.zig) and [services/link_datagram.zig](services/link_datagram.zig)
  are colibri's in-memory links for octet streams and for datagrams, copied unchanged, which stand
  where sockets would be. [services/link_server.zig](services/link_server.zig) and
  [services/link_client.zig](services/link_client.zig) run the server and the client over them.

### Rounds and protocols

Each program over the links runs its calls in rounds, one `client.ConnectionPool` for each:

- A round over h2 or h11 runs TCP in cleartext over the stream link: h2 with prior knowledge,
  and h11 (decision 13).
- A round over h3 runs QUIC over the datagram link. The server presents the test-only identity
  of [testdata/tls](testdata/tls), and the client trusts its CA (decision 25). Both judge the
  certificates at the fixed instant 1_800_000_000, which a real program reads from its clock.

Over h3 every protocol answers as it does over h2: Connect POST and GET, gRPC-Web, and gRPC's
errors, which the server sends Trailers-Only. A gRPC success still needs response trailers that
colibri's client does not expose (decision 11). colibri's client sends a request body whole, so
these programs show the server's type handlers answer each message, not that the client reads an
answer while it still sends.

### A type handler

A function handler takes a client stream whole. A type handler takes each message as it
arrives, so it answers while the client still sends: over h2 the stream is full-duplex.

```zig
const Chat = struct {
    pub const State = struct { turns: u32 = 0 };

    pub fn on_message(_: *App, _: *rpc.Call, state: *State, request: *const demo.ChatMessage, sender: *rpc.Sender(demo.ChatMessage)) ?connect.RpcError {
        state.turns += 1;
        sender.send(&.{ .text = request.text }) catch return .{ .code = .resource_exhausted };
        return null;
    }

    pub fn on_end(_: *App, _: *rpc.Call, _: *State, _: *rpc.Sender(demo.ChatMessage)) ?connect.RpcError {
        return null;
    }
};
```

### An interceptor

An interceptor is a type that a route lists in its options. `on_call` runs before the handler and
may refuse the call; `on_finish` runs after it and returns the outcome the client reads.

```zig
pub const Auth = struct {
    pub fn on_call(_: *App, call: *rpc.Call) ?connect.RpcError {
        _ = caller_of(call) orelse return .{ .code = .unauthenticated, .message = "a bearer token is required" };
        return null;
    }
};

const guarded: rpc.RouteOptions = .{ .interceptors = &.{ Logging, Auth } };
```

A client interceptor is a type an `ExchangeWith` lists, with `on_request` and `on_response`.

## Generated code

`buf generate` writes [gen/](gen) from [proto/](proto) with the plugin this repository builds:

- `connectrpc/eliza/v1/eliza.proto`: the ELIZA service;
- `demo/v1/demo.proto`: the demo service;
- `editions/v1/editions.proto` and `legacy/v1/legacy.proto`: edition 2023's features, and proto2
  with its groups, which the same check covers;
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
