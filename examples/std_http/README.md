# ELIZA on std.http

ELIZA's service on Zig's own HTTP server, `std.http.Server`, called with `std.http.Client`, over
HTTP/1.1 on a loopback socket. connect-zig runs the protocol and colibri runs nothing. The
project asks for connect-zig with `.colibri = false` (decision 52), so the program links no
chapulin. This is how a program serves Connect on an HTTP library of its own.

- `Say`, unary, over Connect in JSON, and once with an empty sentence, which the server answers
  with `invalid_argument`;
- `Introduce`, a server stream, over gRPC-Web, whose status comes in a trailers frame.

`std.http` speaks HTTP/1.1 alone and sends no trailers, so the program speaks Connect and
gRPC-Web, which carry a call's status in the body, and not gRPC.

The project uses the ELIZA schema of [eliza](../eliza), which it depends on by path. Its build
passes eliza `.colibri = false` too, so both ask for one connect-zig.

## Run it

```sh
zig build run
```

The program starts the server on a port the kernel chooses, makes the three calls, and checks
each answer. `zig build test` does the same.

## Play with it

```sh
zig build serve -- 8080
```

```sh
curl --json '{"sentence":"I feel tired"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
buf curl --protocol grpcweb --http2-prior-knowledge=false --schema ../eliza/proto \
  -d '{"name":"Ada"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Introduce
```
