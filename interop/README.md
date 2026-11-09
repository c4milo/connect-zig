# Interop clients

Clients written in other languages call connect-zig's server, the socket server of
`examples/socket_server.zig`, through `interop.v1.InteropService` from
[examples/proto/interop/v1/interop.proto](../examples/proto/interop/v1/interop.proto).
`tools/interop_languages_check.sh` runs each one, and `tools/ci.sh` runs that script.

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
