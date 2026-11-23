# OpenTelemetry's trace export

The four files that OTLP trace export needs, from
[opentelemetry-proto](https://github.com/open-telemetry/opentelemetry-proto) v1.11.1, as
OpenTelemetry wrote them, under the Apache 2.0 license in [LICENSE](LICENSE) (decision 40).

| File | Holds |
| --- | --- |
| `proto/collector/trace/v1/trace_service.proto` | `TraceService`, with its one method `Export` |
| `proto/trace/v1/trace.proto` | Spans, their events, links, and status |
| `proto/resource/v1/resource.proto` | The resource that produced the spans |
| `proto/common/v1/common.proto` | Attribute values, and the scope of the instrumentation |

The denied-words rule of the lint skips this folder, because the files stay as written.
`examples/otlp` serves `TraceService`, and `interop/otel` calls it with OpenTelemetry's Go SDK.
