# Examples

Each folder here is a Zig project of its own (decision 41). It has a `build.zig`, a
`build.zig.zon` that names connect-zig, its own schema in `proto/`, the code `buf generate` writes
in `gen/`, and its sources in `src/`. Copy one folder to start a project. Then replace the path
in `build.zig.zon` with a URL:

```sh
zig fetch --save=connect_zig git+https://github.com/c4milo/connect-zig
```

Each project follows the rules of the library (decision 42). The lint reads every project, and no
program holds a container-level `var`: each `main` allocates one `State` at startup.

## The projects

Start at the top: each project adds one layer to the one before it.

| Project | What it shows |
| --- | --- |
| [quickstart](quickstart) | The README's "Use it in your project": a server and a client over TLS on h11, h2 and h3 |
| [protobuf_messages](protobuf_messages) | Generated messages in binary and JSON, with no RPC |
| [sans_io_call](sans_io_call) | A whole call through `connect` alone: no socket, no HTTP library |
| [eliza](eliza) | The ELIZA service, a client and a server over colibri's h11, h2 and h3 |
| [streaming](streaming) | Bidirectional, client and server streams, a stream that fails, and full-duplex over h2 and h3 |
| [interceptors](interceptors) | Server interceptors that log and authenticate, and a client interceptor |
| [errors](errors) | Errors with typed details in Connect, gRPC and gRPC-Web |
| [oidc](oidc) | A service behind OpenID Connect bearer tokens, with an issuer that changes its key |
| [github](github) | A GitHub-style API: tokens, rate limits, pages, field masks, private resources, streams |
| [std_io](std_io) | ELIZA on colibri's engine over `std.Io`, with no Rotor, and a client over TCP |
| [otlp](otlp) | OpenTelemetry's trace receiver, a real API, which OpenTelemetry's Go SDK calls |
| [socket_server](socket_server) | Every service above on one socket, for curl and buf curl |
| [validate](validate) | A service that checks each request against the protovalidate rules of its schema |

## Run them

From a project's folder:

| Command | What it does |
| --- | --- |
| `zig build run` | Runs the example's own check: a client calls the service and checks each answer |
| `zig build test` | The same, and fails on a wrong answer |
| `zig build serve -- [port]` | Serves the example's service on a socket, to play with, port 8443 by default |
| `zig build plugin` | Installs connect-zig's protoc plugin, which `buf generate` runs to write `gen/` |

From the root of the repository, `zig build examples` runs `zig build test` in each project, and
`zig build example-<name>` runs one project's check. These builds share the root's packages and
cache, so each package is fetched once.

The checks of `eliza`, `streaming`, `interceptors`, `errors`, `oidc` and `github` run a client and
a server in one process, over the in-memory links of the [harness](harness). The rounds over h2
and h11 run in cleartext, with prior knowledge for h2. The round over h3 runs QUIC under the
test-only identity of [harness/tls](harness/tls) (decision 25).

## Play with a service

`zig build serve` serves h11 and h2 over TLS on a TCP port, and h3 on the UDP socket of the same
port, under the same test identity. A client trusts its CA, `harness/tls/ca.pem`:

```sh
cd examples/eliza
zig build serve
```

```sh
curl --cacert examples/harness/tls/ca.pem --json '{"sentence":"I feel tired"}' \
  https://127.0.0.1:8443/connectrpc.eliza.v1.ElizaService/Say
buf curl --cacert examples/harness/tls/ca.pem --schema examples/eliza/proto --protocol grpc \
  -d '{"name":"Ada"}' https://127.0.0.1:8443/connectrpc.eliza.v1.ElizaService/Introduce
```

The README of each project lists the calls of its service. [socket_server](socket_server) serves
all of them on one port, and `tools/interop_check.sh` calls it with curl and buf curl.

## The harness

[harness](harness) is a package, not an example. It stands where a program's sockets,
certificate and clock would be:

- colibri's in-memory links, copied unchanged, and a client and a server that run a round of
  calls over them in h11, h2 and h3;
- `Served`, which runs an example's route table on a real socket for `zig build serve`;
- the test-only TLS identity, whose key anyone can read, so no program outside the examples and
  the checks presents it;
- chapulin's hook, which a program that links colibri's `tls` defines.

## One connect-zig in a build

A project that depends on another, as `socket_server` and `std_io` do, passes connect-zig the same
options as the project it depends on. Zig builds one package for each set of options, so other
options give a second `connect` module, and the compile fails with "file exists in modules".
The projects on Rotor pass `.rotor = true`. `std_io` runs with no Rotor (decision 32), so it
passes `.rotor = false` to connect-zig, to `eliza` and to the harness.
