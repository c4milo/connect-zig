# Interop clients and servers

Clients written in other languages call connect-zig's server, the socket server of
`examples/socket_server.zig`, through `interop.v1.InteropService` from
[examples/proto/interop/v1/interop.proto](../examples/proto/interop/v1/interop.proto).
`tools/interop_languages_check.sh` runs each one, and `tools/ci.sh` runs that script. The same
directories hold servers in those languages, which connect-zig's client calls in turn: see
[The server side](#the-server-side).

| Directory | Library | Protocols |
| --- | --- | --- |
| [go](go) | connect-go and grpc-go | Connect, gRPC and gRPC-Web from connect-go; gRPC from grpc-go |
| [typescript](typescript) | connect-es on Node | Connect, gRPC and gRPC-Web |
| [python](python) | grpcio | gRPC |
| [rust](rust) | tonic | gRPC |
| [connect-rust](connect-rust) | connect-rust's `connectrpc` on Buffa | Connect in proto and JSON, over h2 and HTTP/1.1, with GET; gRPC and gRPC-Web |

## The contract

Each client is a directory with a `run.sh` that the check calls as:

```sh
interop/<client>/run.sh <base-url> <cases-dir> <descriptors> <ca>
```

- `<base-url>` is the server's origin, such as `https://127.0.0.1:41234`. The server speaks h11
  and h2 over TLS, and picks one by ALPN.
- `<cases-dir>` holds one `<name>.binpb` file for each case of `examples/testdata/coverage`: a
  `coverage.v1.Everything`, the message that holds every protobuf type, in binary.
- `<descriptors>` is a `FileDescriptorSet` of `examples/proto`, from `buf build
  --as-file-descriptor-set`, for a client whose build compiles the schema itself.
- `<ca>` is the PEM of the CA that signed the server's certificate, the test identity of
  `examples/testdata/tls`. The client trusts it, and no other.

`run.sh` installs what the client needs, pinned by a lock file, into a cache outside the
repository, generates or builds the client, and runs it. It prints one line for each scenario:

```text
ok: <client> <protocol> <scenario>
FAIL: <client> <protocol> <scenario>: <what differed>
```

It exits 0 when every line is `ok`, and 1 otherwise. A scenario the library cannot run, such as
JSON over grpcio, is not printed.

## The scenarios

Each client runs every scenario in each protocol, codec and compression its library speaks. Two
messages are the same when the client's runtime writes the same octets for both, with its
deterministic option where it has one; NaN rules out equality checks that compare floats.

| Scenario | What the client checks |
| --- | --- |
| `echo <case>` | `Echo` of each case answers with the same message. |
| `echo-gzip <case>` | The same, with the request compressed with gzip. |
| `echo-get <case>` | `EchoGet` sent as a Connect GET, where the library offers it. |
| `repeat` | `Repeat` of one case, three times, answers with three copies. |
| `collect` | `Collect` of every case answers with their count and the last case. |
| `chat` | `Chat` answers each case before the client sends the next, over h2. |
| `fail` | `Fail` with code 5 and message "gone" fails with not_found, "gone", and one detail of type `interop.v1.FailRequest` that holds the request. |
| `inspect` | `Inspect` with a 5 s timeout and the header `x-interop-client: <client>` answers with a timeout between 1 and 5010 ms and the header, and sends the header back as a response header and as a trailer. grpc-core rounds a deadline up to the next 10 ms, hence 5010. |

## What connect-rust leaves out

The connect-rust client runs Connect in proto over h2 (`connect-proto`), in JSON over h2
(`connect-json`) and in proto over HTTP/1.1 (`connect-h1`), then gRPC and gRPC-Web over h2. It
leaves out these scenarios, which its library cannot express:

- `chat` over HTTP/1.1. No response arrives until the upload completes, so a bidirectional stream
  is not full duplex there. connect-go's `connect-h1` run leaves it out too.
- `echo-get` in gRPC and gRPC-Web, which send every call as a POST.

Two notes on how it compares messages:

- Buffa's `google.protobuf.Struct` holds its fields in a `HashMap`, and no option writes them in
  key order. Where two messages write different octets, the client compares their proto3 JSON as
  a JSON value, whose objects ignore key order.
- JSON's `"NaN"` holds no payload, so a NaN comes back from a JSON echo with Rust's bits, not the
  case's. In `connect-json`, the client expects each case as Buffa's own JSON round trip gives it.

## The server side

`tools/interop_servers_check.sh [server...]` runs the mirror check: it starts a server written in
another language, and connect-zig's client, `examples/interop_client.zig`, calls it with every
scenario above. `zig build interop-client` builds the client, and `tools/ci.sh` runs the check
as `interop-servers`.

| Server | Directory | Library | Protocols the client runs |
| --- | --- | --- | --- |
| `go` | [go](go) | connect-go | `connect-proto`, `connect-json`, `connect-h1`, `grpc`, `grpc-web`, `grpc-web-h1` |
| `grpc-go` | [go](go) | grpc-go | `grpc` |
| `typescript` | [typescript](typescript) | connect-node, connect-es's router on Node's http2 server | `connect-proto`, `connect-json`, `connect-h1`, `grpc`, `grpc-web`, `grpc-web-h1` |
| `python` | [python](python) | grpcio | `grpc` |
| `connect-rust` | [connect-rust](connect-rust) | connect-rust's `connectrpc` on Buffa | `connect-proto`, `connect-json`, `connect-h1`, `grpc`, `grpc-web`, `grpc-web-h1` |

Each server reuses its client's lock file. Each serves TLS with the test identity of
`examples/testdata/tls`, h2 and HTTP/1.1 picked by ALPN; grpc-go and grpcio serve h2 alone.

### The server's contract

Each directory has a `serve.sh` that the check calls as:

```sh
interop/<directory>/serve.sh <server> <port> <chain> <key> <descriptors>
```

- `<server>` names the server, which picks one where a directory holds two, as `go` holds
  connect-go and grpc-go.
- `<port>` is the TCP port on 127.0.0.1; 0 lets the kernel choose.
- `<chain>` and `<key>` are the PEM files of the test identity.
- `<descriptors>` is the `FileDescriptorSet` of `examples/proto`, for a server whose build
  compiles the schema itself.

`serve.sh` installs and builds what the server needs, as `run.sh` does, then runs it in its
place. The server prints `listening on port <port>` once it listens, and answers each method as
connect-zig's own server of `examples/services/interop.zig` does:

- `Echo` and `EchoGet` answer with the message; `EchoGet` takes a Connect GET.
- `Repeat` sends the message `count` times, and fails out_of_range past 16.
- `Collect` answers with the count of the messages and the last.
- `Chat` answers each message as it arrives, while the client still sends.
- `Fail` fails with the code and message asked for, and the request as its one detail.
- `Inspect` answers with the timeout it saw, in milliseconds, and each `x-interop-*` header as
  `name: value`, and sends each such header back as a response header and as a trailer.

### What the client runs

The client takes the server's name, its origin, the cases, the CA and the runs it speaks:

```sh
zig-out/bin/interop-client [--leave-out=<protocol>/<scenario>]... <server> <base-url> <cases-dir> <ca> <protocol>...
```

A run speaks its protocol and codec: Connect in proto or JSON, gRPC, or gRPC-Web. The `-h1`
runs speak HTTP/1.1, and the others h2. Each run holds one `client.ConnectionPool`, driven by the
conformance client's transport over TCP with `poll` (decision 32). The client prints the lines of
the contract above, with the server's name in place of the client's, and exits 1 when any
failed. It runs `echo-get` in Connect alone, and `chat` full-duplex over h2 and half-duplex over
HTTP/1.1, where every message goes before the client reads an answer (decision 18 as amended).

connect-zig's runtime writes a map's entries in the order it read them, and has no deterministic
option. Where two messages write different octets, the client compares their proto3 JSON as a
JSON value, whose objects ignore key order, as the connect-rust client does. It compares numbers
by their text, except in `connect-json`, where it compares them as values: connect-es writes -0
as 0. JSON's `"NaN"` holds no payload, so a NaN's bits do not count there.

### What the servers leave out

- `chat` over HTTP/1.1 against connect-go and connect-node: both answer a bidirectional stream
  over HTTP/1.1 with 505. The check passes `--leave-out=connect-h1/chat` and
  `--leave-out=grpc-web-h1/chat` for them. connect-rust answers it half-duplex.
- `echo-get` in gRPC and gRPC-Web, which send every call as a POST.
- Every run but `grpc` against grpc-go and grpcio, which speak gRPC alone.
- h3: no server here serves it.
- JSON over gRPC and gRPC-Web, which the client does not send.
