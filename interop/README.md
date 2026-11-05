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

## The contract

Each client is a directory with a `run.sh` that the check calls as:

```sh
interop/<client>/run.sh <base-url> <cases-dir> <descriptors>
```

- `<base-url>` is the server's origin, such as `http://127.0.0.1:41234`. The server speaks h11 and
  h2 with prior knowledge in cleartext.
- `<cases-dir>` holds one `<name>.binpb` file for each case of `examples/testdata/coverage`: a
  `coverage.v1.Everything`, the message that holds every protobuf type, in binary.
- `<descriptors>` is a `FileDescriptorSet` of `examples/proto`, from `buf build
  --as-file-descriptor-set`, for a client whose build compiles the schema itself.

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
