# The validated OTLP schema

The full-stack check loads three receivers that validate each export with protovalidate:
connect-zig's sink, the receiver on connect-go with protovalidate-go, and the receiver on
connect-rust with protovalidate-buffa (`tools/fullstack_check.sh`). OpenTelemetry's
schema holds no rules, so this folder holds a copy of the four files of `examples/otlp/proto`,
from [opentelemetry-proto](https://github.com/open-telemetry/opentelemetry-proto) v1.11.1, under
the Apache 2.0 license in [LICENSE](proto/opentelemetry/LICENSE). Two of them gain the rules that
the OTLP specification states for a span. The fields, their numbers, and their packages stay as
OpenTelemetry wrote them, so each export's octets and the path of `Export` are the same.

| Message | Field | Rule |
| --- | --- | --- |
| `Span` | `trace_id` | 16 octets |
| `Span` | `span_id` | 8 octets |
| `Span` | `parent_span_id` | empty or 8 octets, as CEL |
| `Span` | `name` | not empty |
| `Span` | `kind` | a defined `SpanKind` |
| `Span` | the message | `end_time_unix_nano` not before `start_time_unix_nano`, as CEL |
| `Status` | `code` | a defined `StatusCode` |
| `KeyValue` | `key` | not empty |

`trace.proto` and `common.proto` say at their top that connect-zig changed them. `gen/` holds the
Zig code that `tools/generate_check.sh` writes from `proto/`, with `buf.gen.yaml`. The root's
`buf.yaml` lists `proto/` as a module of its workspace, which imports validate.proto from
`src/protovalidate/proto`.
