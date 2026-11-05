# Examples

Programs a project that depends on connect-zig would write. Each one checks what it receives and
exits with an error when something is wrong, so `zig build examples` runs them all as a test.

Start at the top: each example adds one layer to the one before it.

| Example | What it shows | Run it |
| --- | --- | --- |
| [protobuf_messages.zig](protobuf_messages.zig) | Generated messages in binary and JSON, with no RPC | `zig build example-protobuf_messages` |
| [sans_io_call.zig](sans_io_call.zig) | A whole call through `connect` alone: no socket, no HTTP library | `zig build example-sans_io_call` |
| [eliza/exchange.zig](eliza/exchange.zig) | A client and a server over colibri's h2 and h11, in memory | `zig build example-eliza` |
| [eliza/socket_server.zig](eliza/socket_server.zig) | The ELIZA server on a TCP socket, for curl and `buf curl` | `zig build run-eliza-server -- 8080` |

## The ELIZA service

[proto/connectrpc/eliza/v1/eliza.proto](proto/connectrpc/eliza/v1/eliza.proto) declares one
method of each kind:

- `Say`, unary, which a Connect client may also send as a GET;
- `Introduce`, a server stream;
- `Converse`, a bidirectional stream.

[eliza/service.zig](eliza/service.zig) holds its handlers and its route table. Both ELIZA programs
serve it. [eliza/link.zig](eliza/link.zig) is colibri's in-memory link, copied unchanged, which
stands where sockets would be.

## Generated code

`buf generate` writes [gen/](gen) from [proto/](proto) with the plugin this repository builds:

- `connectrpc/eliza/v1/eliza.proto`: the ELIZA service;
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
  -d '{"name":"Ada"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Introduce
```
