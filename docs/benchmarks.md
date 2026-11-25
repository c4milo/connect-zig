# Benchmarks

How connect-zig's benchmarks are measured, with their charts. CI runs the benchmarks on each tag,
and attaches the charts they draw to the tag's GitHub release (decision 44). This page shows the
latest release's. Each chart names the run and the commit that drew it, and that run's summary
holds every table, the x86-64 results included.

Each chart also compares connect-zig's bars with the previous tag's. A dashed line crosses a bar
at the previous tag's value, and ▲ or ▼ after its label marks a value 5% or more better or worse.
A chart whose CPU model differs from the previous tag's marks nothing, since its times do not
compare. The release's notes and the run's summary list the same changes as a table. A time compares only
with times of the same job on the same machine, as [performance.md](performance.md) asks.

## The codec

![Bars of the speed of connect-zig and of Buffa, connect-rust's codec, in multiples of Go's protobuf runtime, connect-go's codec, on arm64](https://github.com/c4milo/connect-zig/releases/latest/download/speed-vs-go-arm64.svg)

`zig build bench` times binary and JSON encoding and decoding of eight messages.
`tools/bench_check.sh` runs the same inputs through Go's `google.golang.org/protobuf` v1.36.12 and
Buffa, and checks that each writes the same bytes. It runs three rounds in a rotated order, and
each cell is the median round. A bar is a speed in multiples of Go's, so a longer bar is faster.

Each decode the chart draws reads every field. Go and Buffa build the whole message, while
connect-zig parses a repeated field when it is read, so connect-zig reads with `decode_into`
(decision 37).

## Request routing

![Bars of the speed of a routed unary call through connect-zig and connect-rust, in multiples of connect-go's, on arm64](https://github.com/c4milo/connect-zig/releases/latest/download/call-vs-go-arm64.svg)

`bench/call.zig` runs one unary call in memory through each library's router, route, protocol,
and codec, with no socket, TLS, or HTTP/2 framing. Each program builds its request once and times
the calls alone. connect-go's router is an `http.ServeMux`.

The small message's call also runs in tables of 16 and 256 routes. colibri searches each path
segment, so connect-zig's call grows with the table. The run's summary holds those times.

## OpenTelemetry trace ingestion

An OTLP receiver on one core, over TLS and h2, takes the traffic of one gateway core for 33,000
servers.

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, the median of three rounds with their range, and lines of p99 as the rate climbs, on arm64](https://github.com/c4milo/connect-zig/releases/latest/download/fullstack-arm64.svg)

<details>
<summary>The same on x86-64.</summary>

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, the median of three rounds with their range, and lines of p99 as the rate climbs, on x86-64](https://github.com/c4milo/connect-zig/releases/latest/download/fullstack.svg)

</details>

`tools/fullstack_check.sh` loads these servers with the same OTLP exports:

- connect-zig's OTLP receiver, `tools/otlp_sink`.
- The [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) v0.165.0, with its OTLP
  receiver and `nop` exporter.
- [Vector](https://vector.dev/) v0.62.0, with its `opentelemetry` source and `blackhole` sink. Its
  gRPC listener speaks TLS 1.2 alone.
- [Rotel](https://github.com/streamfold/rotel) v0.2.7, with its OTLP receiver and `blackhole`
  exporter. Its receiver has no TLS.
- [connect-go](https://github.com/connectrpc/connect-go) v1.18.1 and
  [connect-rust](https://github.com/connectrpc/connect-rust) v0.9.1, in `tools/fullstack/`.

Each server decodes and checks every span, counts it, and drops it, on one core.

The load, `tools/fullstack/load`, holds 516 connections across the climb. 70%, 25%, and 5% of them
send gzip exports of 16, 128, and 512 spans, from 32 versions of each. It sends on a fixed
schedule, and a call's latency counts from its scheduled instant. Each step lasts 10 s. The rate
climbs until p99 passes 100 ms, a call is refused, or the server takes less than 95% of the spans.
Each server runs three rounds on new processes, in a rotated order. A bar is the median round, and
its whisker spans the three rounds.

The run's summary also gives the highest rate each server held with p99 at or under 10 ms, the
CPU time a span and the peak memory, the climbs in cleartext h2 beside Rotel
(`fullstack-cleartext`), and the calls a second of `fullstack-peak`, which loads each server over
TLS as fast as it answers. "connect-go, 320 MiB" in it runs with `GOGC=off` and
`GOMEMLIMIT=320MiB`, about connect-zig's memory.

The limits of these measurements:

- Every server and the load run on one machine, over its loopback device.
- An x86-64 runner's CPU model changes from job to job. Compare a number only with the numbers of
  its own table.
- On x86-64 the server's CPU shares its physical core with the CPU that runs the scripts.
- A rate held lasts 10 s. The run's summary says whether each server held its median rate for a
  step of 60 s.
- connect-zig's sink holds 64 calls at once and answers 503 past them. More connections or exports
  over 256 KiB need larger limits.
- Vector and Rotel do not set `TCP_NODELAY`, so their p99 stays near 40 ms at low rates. The climb
  runs them as they ship.

### Validating every span

Each Connect receiver runs again over TLS and checks every span against OTLP's span rules, in
`tools/fullstack/validate`, two of them CEL.

![Bars of the spans a second one core holds over TLS with p99 under 100 ms, for each Connect receiver without and with protovalidate, the median of three rounds, and lines of p99 as the rate climbs, on arm64](https://github.com/c4milo/connect-zig/releases/latest/download/fullstack-validate-arm64.svg)

connect-zig uses `protovalidate.Interceptor` (`zig build otlp-sink-validate`), connect-go
[protovalidate-go](https://github.com/bufbuild/protovalidate-go) v1.4.1, and connect-rust
[protovalidate-buffa](https://github.com/mathematic-inc/protovalidate-buffa) 0.8.0. Before each
climb, the check sends an export that breaks a rule, and fails when a validating receiver takes it.

### With compression

The three Connect receivers take the production model's exports over TLS, uncompressed and in
gzip, zstd, and brotli.

![Bars of the spans a second each Connect receiver holds over TLS with exports in gzip, zstd, and brotli, as a share of the same receiver with uncompressed exports in the same round, and of its calls a second at peak, on arm64](https://github.com/c4milo/connect-zig/releases/latest/download/fullstack-compression-arm64.svg)

`tools/fullstack/compression.sh` runs three rounds of each coding. stdx writes gzip at its default
level, and zstd and brotli at level 1. Each receiver decodes with its library's own decoders. A
bar is a share of the same receiver uncompressed in the same round, so bars of two libraries do
not compare. The octets of each class's first export:

| Export | Uncompressed | gzip | zstd | brotli |
| --- | ---: | ---: | ---: | ---: |
| 16 spans | 7,984 | 2,454 (3.3×) | 2,527 (3.2×) | 2,500 (3.2×) |
| 128 spans | 61,353 | 9,332 (6.6×) | 9,646 (6.4×) | 9,228 (6.6×) |
| 512 spans | 233,192 | 30,976 (7.5×) | 31,101 (7.5×) | 29,933 (7.8×) |

The limits of these measurements:

- Compare a share only within its table.
- No OpenTelemetry exporter sends brotli.

## Validation

One decode of a request message and one validation of it, through five implementations.

![Bars of the speed of a decode with a validation through connect-zig, protovalidate-buffa, prost-protovalidate, and protovalidate-es, in multiples of protovalidate-go's, on arm64](https://github.com/c4milo/connect-zig/releases/latest/download/validate-vs-go-arm64.svg)

`tools/validate_compare_check.sh` times five implementations on one schema,
`bench/validate/proto`, and fails when two give one message different verdicts:

| Implementation | Language | How it checks a rule |
| --- | --- | --- |
| connect-zig's `protovalidate` | Zig | Code the compiler makes from each rule, CEL included (decision 47) |
| [protovalidate-go](https://github.com/bufbuild/protovalidate-go) v1.4.1 | Go | Rules read from descriptors, CEL run by cel-go |
| [protovalidate-es](https://github.com/bufbuild/protovalidate-es) 1.3.0 | TypeScript on Node.js | Rules read from descriptors, CEL run by an interpreter |
| [protovalidate-buffa](https://github.com/mathematic-inc/protovalidate-buffa) 0.8.0 | Rust | Rust code its plugin writes from each rule |
| [prost-protovalidate](https://github.com/zs-dima/prost-protovalidate) 0.6.1 | Rust | Rules read through prost-reflect, CEL run by an interpreter |

`Small` has three fields with one standard rule each. `Medium` is a typical API request, with two
CEL rules and a standard rule of each kind. `Rules` holds CEL rules alone.
`bench/validate/cases` holds a valid and an invalid message of each. Each program keeps one
validator and times the median of 11 batches of about 20 ms. connect-zig decodes with
`decode_into` (decision 37).

The run's summary holds the nanoseconds of each case, with the decode and without it, on both
machines.
