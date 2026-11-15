# ELIZA

The ELIZA service of the Connect project, `connectrpc.eliza.v1.ElizaService`, served by
connect-zig over colibri. It has one method of each kind:

- `Say`, unary, which a Connect client may also send as a GET, since it has no side effects;
- `Introduce`, a server stream;
- `Converse`, a bidirectional stream.

## Files

| Path | Holds |
| --- | --- |
| [proto/connectrpc/eliza/v1/eliza.proto](proto/connectrpc/eliza/v1/eliza.proto) | The schema |
| [gen/](gen) | The code `buf generate` writes from it |
| [src/service/service.zig](src/service/service.zig) | The handlers, over any program's `App` |
| [src/app.zig](src/app.zig) | This example's `App` and route table |
| [src/main.zig](src/main.zig) | The check: a client that calls every method in memory |
| [src/serve.zig](src/serve.zig) | The same routes on a socket, to play with |

## Run it

```sh
zig build run
```

The check runs three rounds, over h2, h11 and h3, in one process. In each round one client calls
`Say` over Connect as a POST and as a GET, `Introduce` over gRPC-Web and gRPC, `Converse` over
Connect with JSON, and `Say` with an empty sentence over gRPC, which fails with
`invalid_argument`. It exits with an error on a wrong answer, so `zig build test` runs the same.

## Play with it

```sh
zig build serve
```

The server listens on port 8443 over TLS, h11 and h2 on TCP and h3 on UDP, under the examples'
test identity. From the root of the repository:

```sh
curl --cacert examples/harness/tls/ca.pem --json '{"sentence":"I feel tired"}' \
  https://127.0.0.1:8443/connectrpc.eliza.v1.ElizaService/Say
```

```sh
buf curl --cacert examples/harness/tls/ca.pem --schema examples/eliza/proto --protocol grpc \
  -d '{"name":"Ada"}' https://127.0.0.1:8443/connectrpc.eliza.v1.ElizaService/Introduce
```

```sh
buf curl --cacert examples/harness/tls/ca.pem --schema examples/eliza/proto --http3 \
  -d '{"sentence":"Hello"} {"sentence":"I dream of code"}' \
  https://127.0.0.1:8443/connectrpc.eliza.v1.ElizaService/Converse
```

## Generate the code

```sh
zig build plugin
buf generate
```

`zig build plugin` installs connect-zig's plugin to `zig-out/bin`, and `buf generate` runs it over
`proto/`, as [buf.gen.yaml](buf.gen.yaml) says.

## Use the service in another project

The package exports `eliza`, the generated code, and `eliza_service`, the handlers. A program's
`App` holds the service's `Room` in its field `eliza`, so one route table serves ELIZA beside other
services, as [socket_server](../socket_server) does:

```zig
const App = struct { eliza: eliza_service.Room = .{} };
const routes = eliza_service.Service(App).routes;
```
