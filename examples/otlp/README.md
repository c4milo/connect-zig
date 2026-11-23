# OpenTelemetry's trace receiver

A real API that others wrote and many programs call (decision 40): OpenTelemetry's
`opentelemetry.proto.collector.trace.v1.TraceService/Export`, from opentelemetry-proto v1.11.1,
which every OpenTelemetry SDK's gRPC exporter and the OpenTelemetry Collector call. Point an
instrumented program at this server, and its spans arrive here.

![A terminal session: zig build run exports a trace and reads it back, then OpenTelemetry's Go SDK exports to zig build serve](walkthrough.gif)

- `Export` keeps the binary encoding of each request, up to 32 KiB, and answers a request past that
  bound with `partial_success.rejected_spans`, as OTLP says.
- `otlpstore.v1.SpanStore/Received`, a method of this repository, answers with every request it
  kept, as one `ExportTraceServiceRequest`.

`tools/interop_check.sh` checks it with OpenTelemetry's own Go SDK, through
[socket_server](../socket_server): [interop/otel](../../interop/otel) exports a trace and reads it
back, then compares each span with the one the SDK ended, field by field.

## Files

| Path | Holds |
| --- | --- |
| [proto/opentelemetry/](proto/opentelemetry) | The four files of opentelemetry-proto that trace export needs, as OpenTelemetry wrote them, under the Apache 2.0 license |
| [proto/otlpstore/v1/otlpstore.proto](proto/otlpstore/v1/otlpstore.proto) | `SpanStore`, which reads back what the receiver kept |
| [src/service/service.zig](src/service/service.zig) | `Export` and `Received`, over any program's `App` |
| [src/app.zig](src/app.zig) | This example's `App` and route table |
| [src/main.zig](src/main.zig) | The check: a checkout trace of three spans, exported and read back over h2, h11, and h3 |
| [src/serve.zig](src/serve.zig) | The receiver on a socket, for an SDK's exporter |

## Run it

```sh
zig build run
```

## Play with it

```sh
zig build serve
```

The receiver listens on port 8443 over TLS, under the examples' test identity. A Go program sends
its spans with OpenTelemetry's gRPC exporter, which trusts the test CA:

```go
exporter, _ := otlptracegrpc.New(ctx,
    otlptracegrpc.WithEndpoint("127.0.0.1:8443"),
    otlptracegrpc.WithTLSCredentials(credentials.NewClientTLSFromCert(pool, "localhost")))
```

Then read back what it kept, from this folder:

```sh
buf curl --schema proto --cacert ../harness/tls/ca.pem --protocol grpc \
  https://127.0.0.1:8443/otlpstore.v1.SpanStore/Received
```

[interop/otel/main.go](../../interop/otel/main.go) is a whole program that does both.
