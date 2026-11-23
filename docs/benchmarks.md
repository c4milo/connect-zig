# Benchmarks

How connect-zig's published numbers are measured, with every chart and every table behind them.
Each number comes from one named CI run, as [performance.md](performance.md) asks, and each
time compares only within one job on one machine.

## The codec

From CI's [run 250](https://github.com/c4milo/connect-zig/actions/runs/45111071415), on an Arm Neoverse-N2 core; the x86-64 chart is under it. Binary and JSON encoding and decoding of eight messages, against Go's protobuf
runtime and Buffa, connect-rust's codec. connect-zig is 3.2 to 20.0 times faster than Go, and Buffa
is faster in none of the 16 cells charted.

![Bars of the speed of connect-zig and of Buffa, connect-rust's codec, in multiples of Go's protobuf runtime, connect-go's codec, on arm64: connect-zig is 3.2 to 20.0 times faster than Go's protobuf runtime, and 1.1 to 2.2 times faster than Buffa](images/speed-vs-go-arm64.svg)

<details>
<summary>On x86-64, connect-zig is 4.6 to 21.0 times faster than Go, and 1.1 to 2.0 times faster than Buffa.</summary>

![Bars of the speed of connect-zig and of Buffa, connect-rust's codec, in multiples of Go's protobuf runtime, connect-go's codec, on x86-64: connect-zig is 4.6 to 21.0 times faster than Go's protobuf runtime, and 1.1 to 2.0 times faster than Buffa](images/speed-vs-go.svg)

</details>

`zig build bench` times binary and JSON encoding and decoding of eight messages, then a routed unary
call. `tools/bench_check.sh` runs the same inputs through Go's `google.golang.org/protobuf`
v1.36.12, connect-go's codec, and Buffa, connect-rust's codec. It checks that each writes the same
bytes as connect-zig. The numbers below come from CI's two `bench-compare` jobs of commit `a5db7e1`
([run 250](https://github.com/c4milo/connect-zig/actions/runs/45111071415)), on Ubuntu 26.04. One
ran on an Intel Xeon Platinum 8573C core (x86-64) and one on an Arm Neoverse-N2 core (arm64), each
with the three programs in one job. The run's summary holds every table. An x86-64 runner's CPU
model changes from run to run: run 191's was an AMD EPYC 9V74.

Each chart above draws the speed of connect-zig and of Buffa in multiples of Go's. A
longer bar is faster, and Go is the line at 1. The charts time the codecs alone, with no code of
connect-go or connect-rust. A binary decode with every field read takes `decode_into`, which
reads each repeated field once (decision 37).

The charts draw 16 of the table's 48 cells. Buffa is faster in none of them, on either machine.

In the table's 48 cells, connect-zig is 2.3 to 39.9 times faster than Go on arm64, and 2.3 to
36.8 times on x86-64. Against Buffa, connect-zig is faster in 44 of the 48 cells on arm64 and in
45 on x86-64, by up to 3.77 and 3.33 times. Buffa is faster in the other 4 and 3. On arm64 it
wins tree JSON encode by 1.54 times, strings JSON encode by 1.18 times, packed JSON decode with
every field read by 1.10 times, and varints binary decode by 1.04 times. On x86-64 it wins packed
JSON decode with every field read by 1.20 times, tree JSON decode with every field read by 1.18
times, and packed JSON decode by 1.08 times.

## The routed call

From CI's [run 250](https://github.com/c4milo/connect-zig/actions/runs/45111071415), on an Arm Neoverse-N2 core; the x86-64 chart is under it. One unary call in memory through each library's router, protocol and codec.
connect-zig is 15.3 to 23.4 times as fast as connect-go, and 3.5 to 6.4 times as fast as
connect-rust.

![Bars of the speed of a routed unary call through connect-zig and connect-rust, in multiples of connect-go's, on arm64: connect-zig is 15.3 to 23.4 times as fast as connect-go, and 3.5 to 6.4 times as fast as connect-rust](images/call-vs-go-arm64.svg)

<details>
<summary>On x86-64, connect-zig is 13.9 to 21.3 times as fast as connect-go, and 3.1 to 5.4 times as fast as connect-rust.</summary>

![Bars of the speed of a routed unary call through connect-zig and connect-rust, in multiples of connect-go's, on x86-64: connect-zig is 13.9 to 21.3 times as fast as connect-go, and 3.1 to 5.4 times as fast as connect-rust](images/call-vs-go.svg)

</details>

The routed calls (`bench/call.zig`) run the same unary call in memory through connect-zig,
connect-go and connect-rust: the router, the route, the protocol and the codec, with no socket, no
TLS and no HTTP/2 framing. connect-go's router is an `http.ServeMux`, as a server's is. CI's two
`bench-compare` jobs of commit `a5db7e1` ([run 250](https://github.com/c4milo/connect-zig/actions/runs/45111071415)) timed them on
colibri v0.19.2 and Ubuntu 26.04, on an Intel Xeon Platinum 8573C core and on an Arm Neoverse-N2
core. The
charts draw a speed in multiples of connect-go's, and connect-zig's bar also gives its time
for one call, in a table of one route.

The small message's call also runs in tables of 16 and 256 routes: 4 and 16 services of as many
methods, with the call's route among them. colibri finds a route by a binary search over each path
segment, 8 octets at a time since colibri v0.19.0, connect-rust by a hash map of the path, and
Go's `ServeMux` by a tree of maps. So connect-zig's call grows with the table, where the other two
stay within 3%. On CI's judge it takes 4,237 instructions with one route and 4,460 with 256, 5%
more. In time it grew 18% on arm64 and 11% on x86-64 in this run. The time of the small Connect
call, in nanoseconds:

| Router | 1 route | 16 routes | 256 routes |
| --- | ---: | ---: | ---: |
| connect-zig, arm64 | 332 | 349 | 394 |
| connect-rust, arm64 | 1,896 | 1,885 | 1,906 |
| connect-go, arm64 | 7,464 | 7,422 | 7,494 |
| connect-zig, x86-64 | 314 | 322 | 348 |
| connect-rust, x86-64 | 1,588 | 1,594 | 1,623 |
| connect-go, x86-64 | 6,681 | 6,558 | 6,591 |

## Whole servers on a socket

From CI's [run 250](https://github.com/c4milo/connect-zig/actions/runs/45111071415), on an Arm Neoverse-N2 core; the x86-64 chart is under it. An OTLP receiver on one core, over TLS and h2, takes the traffic of one gateway
core for 33,000 servers. connect-zig holds 7.9 times connect-go's spans a second and 2.8 times
connect-rust's, in 352 MiB that it takes at start.

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, and lines of p99 as the rate climbs, on arm64: connect-zig holds 765,400 spans a second, 7.9 times connect-go's 96,746, 2.8 times connect-rust's 269,250, 3.6 times the OpenTelemetry Collector's 211,372 and 11.2 times Vector's 68,430](images/fullstack-arm64.svg)

<details>
<summary>On x86-64, connect-zig holds 6.8 times connect-go's spans a second, 2.1 times connect-rust's, 3.4 times the Collector's and 12.6 times Vector's.</summary>

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, and lines of p99 as the rate climbs, on x86-64: connect-zig holds 1,103,536 spans a second, 6.8 times connect-go's 162,416, 2.1 times connect-rust's 520,650, 3.4 times the OpenTelemetry Collector's 320,416 and 12.6 times Vector's 87,860](images/fullstack.svg)

</details>

`tools/fullstack_check.sh` loads whole servers on real sockets over HTTP/2, each with the same
OTLP exports. The servers:

- connect-zig's OTLP receiver, `tools/otlp_sink`.
- The [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) v0.165.0, the server
  most companies run to take OpenTelemetry's traces, with its OTLP receiver and its `nop`
  exporter.
- [Vector](https://vector.dev/) v0.62.0, in Rust, with its `opentelemetry` source and its
  `blackhole` sink. The source converts each span into Vector's own event, its default. Its
  `otlp` codec keeps OTLP's form, but answered fewer than half the calls a second.
- [Rotel](https://github.com/streamfold/rotel) v0.2.7, the OpenTelemetry collector in Rust, with
  its OTLP receiver and its `blackhole` exporter. Its receiver has no TLS.
- Receivers on the other Connect libraries:
  [connect-go](https://github.com/connectrpc/connect-go) v1.18.1 on `net/http`, and
  [connect-rust](https://github.com/connectrpc/connect-rust) v0.9.1 on hyper and rustls
  (`tools/fullstack/connect-go` and `tools/fullstack/connect-rust`). Each counts the spans of
  each export and drops it, as connect-zig's receiver does.

Each server decodes and checks every span, counts it and drops it. Each runs on one core, the
Collector and connect-go with `GOMAXPROCS=1`, Vector with one thread, and connect-rust with one
tokio worker. The load runs on two other cores. Each run checks every span.

The production model stands for one core of a 64-core gateway that 33,000 servers send their traces
to. Each server holds 516 connections. 70%, 25% and 5% of them send gzip exports of 16, 128 and 512
spans. [oha](https://github.com/hatoo/oha) sends at fixed rates, and its latency holds the time a
call waits in a queue. Each step lasts 10 s, and its measure leaves out the first 2 s, where its TLS
handshakes run. The rate climbs until p99 passes 100 ms, a call is refused, or the server takes
less than 95% of the spans sent. Then five more steps halve the gap to the last step that passed,
so each rate is known within 1/64 of it. CI's two `fullstack` jobs of commit `a5db7e1` ([run
250](https://github.com/c4milo/connect-zig/actions/runs/45111071415)) ran it on colibri v0.19.2 and
Ubuntu 26.04, on an Arm Neoverse-N2 core and on an AMD EPYC 9V45 core. The charts show the climb
over TLS 1.3: one core of connect-zig held 7.9 times connect-go's spans a second on arm64 and 6.8
times on x86-64, 2.8 and 2.1 times connect-rust's, 3.6 and 3.4 times the Collector's, and
11.2 and 12.6 times Vector's.

Rotel has no TLS on its receiver, so a second climb runs in cleartext h2 for connect-zig, the
Collector and Rotel. There one core of connect-zig holds 3.5 times Rotel's spans a second and 4.2
times the Collector's, on both machines.

<details>
<summary>The climb in cleartext h2, on arm64 and on x86-64.</summary>

![Bars of the spans a second one core holds with p99 under 100 ms over cleartext h2, and lines of p99 as the rate climbs, on arm64: connect-zig holds 800,936 spans a second, 3.5 times Rotel's 231,400 and 4.2 times the OpenTelemetry Collector's 189,136](images/fullstack-cleartext-arm64.svg)

![Bars of the spans a second one core holds with p99 under 100 ms over cleartext h2, and lines of p99 as the rate climbs, on x86-64: connect-zig holds 1,121,464 spans a second, 3.5 times Rotel's 322,658 and 4.2 times the OpenTelemetry Collector's 264,784](images/fullstack-cleartext.svg)

</details>

The CPU time a span, at each server's highest step, in µs. A span costs less CPU as the rate
rises, since each wake of the core serves more calls. So the table favours a server whose highest
step is higher. The sections on protovalidate and compression below compare at a common rate:

| Server | arm64, TLS | x86-64, TLS | arm64, cleartext | x86-64, cleartext |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 1.31 | 0.92 | 1.26 | 0.90 |
| connect-rust | 3.69 | 1.88 | | |
| connect-go | 9.74 | 5.92 | | |
| Collector | 4.61 | 3.05 | 5.30 | 3.60 |
| Vector | 12.95 | 7.76 | | |
| Rotel | | | 4.32 | 2.95 |

connect-zig takes all its memory when it starts: 352 MiB, for 528 connections and 64 calls at
once, each call with 1 MiB to decode its export into. colibri v0.19.2's `Router.init` starts the
router in place; a router set to `.{}` copied its default value from the program's image, and the
sink grew to 500 MiB in run 248. Over TLS on arm64, connect-rust grew to 55 MiB, connect-go to
151 MiB, the Collector to 706 MiB and Vector to 629 MiB; in cleartext, Rotel grew to
328 MiB. Over TLS on both machines and in cleartext on arm64, connect-zig's climb ended when p99
passed 100 ms, with its core busy all the time. In cleartext on x86-64 it ended on a refused call,
with all 64 of its slots for calls in flight taken. Every other server's climb ended when p99
passed 100 ms. A runner's CPU model changes from run to run on x86-64, so its rates move
between runs; the arm64 runner has been a Neoverse-N2 in each run.

Vector's and Rotel's p99 stays near 40 ms from a low rate. Neither sets `TCP_NODELAY` on the
sockets it accepts, so Nagle's algorithm waits for Linux's delayed ACK. With `TCP_NODELAY` set
from outside, their p99 fell to about 5 ms, but neither held a higher rate. So the climb runs them
as they ship. connect-rust's server sets it.

The same jobs also load each server over TLS as fast as it answers, with exports of 16 and of 512
spans, not compressed, on 16 connections of 4 streams. The calls a second:

| Server | 16 spans, arm64 | 512 spans, arm64 | 16 spans, x86-64 | 512 spans, x86-64 |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 41,592 | 1,605 | 65,655 | 2,400 |
| connect-rust | 16,519 | 1,082 | 30,074 | 1,551 |
| connect-go | 5,201 | 384 | 9,024 | 607 |
| Collector | 13,417 | 794 | 22,740 | 1,186 |
| Vector | 4,403 | 251 | 12,031 | 364 |

### With protovalidate

From the same run, on an Arm Neoverse-N2 core over TLS; the x86-64 chart is under it. Each
Connect receiver runs a second time, and checks every span of each export against OTLP's span
rules before it counts it. With validation, one core of connect-zig keeps 86% of its
spans a second, connect-rust 90% and connect-go 61%. So connect-zig with protovalidate holds 2.7
times connect-rust's spans a second with protovalidate-buffa, and 11.2 times connect-go's with
protovalidate-go.

![Bars of the spans a second one core holds over TLS with p99 under 100 ms, for each Connect receiver without and with protovalidate, and lines of p99 as the rate climbs, on arm64: connect-zig keeps 86% of its rate with protovalidate, 658,600 spans a second, connect-rust with protovalidate-buffa 90%, 242,522, and connect-go with protovalidate-go 61%, 58,926](images/fullstack-validate-arm64.svg)

<details>
<summary>On x86-64, connect-zig keeps 90% of its spans a second with validation, connect-rust 87% and connect-go 63%.</summary>

![Bars of the spans a second one core holds over TLS with p99 under 100 ms, for each Connect receiver without and with protovalidate, and lines of p99 as the rate climbs, on x86-64: connect-zig keeps 90% of its rate with protovalidate, 996,384 spans a second, connect-rust with protovalidate-buffa 87%, 453,884, and connect-go with protovalidate-go 63%, 102,348](images/fullstack-validate.svg)

</details>

The three validating receivers:

- connect-zig's sink with `protovalidate.Interceptor`, which `zig build otlp-sink-validate`
  builds.
- connect-go's receiver with [protovalidate-go](https://github.com/bufbuild/protovalidate-go)
  v1.4.1.
- connect-rust's receiver with
  [protovalidate-buffa](https://github.com/mathematic-inc/protovalidate-buffa) 0.8.0.

OpenTelemetry's schema holds no rules. So `tools/fullstack/validate` holds a copy of its trace
schema, with the rules that the OTLP specification states for a span: a `trace_id` of 16 octets,
a `span_id` of 8, a `parent_span_id` empty or of 8, a name, a defined kind and status code, an end
time not before the start time, and an attribute key that is not empty. Two of the rules are CEL.
No span of the load breaks a rule. Before each server's climb, the check sends it an export whose
`trace_id` holds 3 octets, and fails when a validating receiver takes it.

The rate each core holds over TLS, and what validation costs it:

| Receiver | arm64, rate kept | arm64, CPU a span | x86-64, rate kept | x86-64, CPU a span |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 86% | +11% | 90% | +1% |
| connect-rust | 90% | +10% | 87% | +11% |
| connect-go | 61% | +50% | 63% | +47% |

The CPU a span compares each receiver with its twin at the highest rate both climbs held, since a
span costs less CPU as the rate rises. On arm64 that rate was 569,600 spans a second for
connect-zig, 213,600 for connect-rust and 53,400 for connect-go, and on x86-64 it was 996,800,
427,200 and 71,200. At 996,800 connect-zig's core was nearly full. There its CPU a span rose 1%,
and its rate kept fell 10%: near a full core, a small cost moves p99 a lot, and the climb ends on
p99.

At the peak, with one export sent again and again, validation costs connect-zig 3.2 µs a call of
16 spans and 92.5 µs a call of 512 spans on arm64: 0.18 to 0.20 µs a span. It costs connect-rust 8.0
and 92.5 µs, 0.18 to 0.50 µs a span, and connect-go 120 and 2,763 µs, 5.4 to 7.5 µs a span.

connect-zig decodes each export into storage that its route owns, 1 MiB a call in the sink
(decision 37). A list that does not fit is parsed again by each read, and validation reads every
list. With 256 KiB, a 512-span export did not fit, and protovalidate cost the sink 0.96 µs a span;
with 1 MiB it costs 0.16 µs (`zig build otlp-validate-cost`). So a route's storage now defaults to
4 times its `message_bytes`, and a context field `messages_past_storage` counts the requests that
did not fit. The check fails when the sink counts one.

### With compression

From the same run, on an Arm Neoverse-N2 core over TLS; the other three charts are under it.
connect-zig, connect-go and connect-rust each take the production model's exports uncompressed and
in gzip, zstd and brotli. Over TLS, one core of connect-zig holds 36% more spans a second in gzip
than uncompressed, 37% more in zstd and 17% more in brotli. connect-go holds 15% to 22% fewer, and
connect-rust 2% to 11% fewer.

![Bars of the spans a second each Connect receiver holds over TLS with exports in gzip, zstd and brotli, as a share of the same receiver with uncompressed exports, and of its calls a second at peak, on arm64: connect-zig holds 136%, 137% and 117%, connect-go 78%, 85% and 82%, and connect-rust 94%, 98% and 89%](images/fullstack-compression-arm64.svg)

<details>
<summary>In cleartext h2 on arm64, connect-zig holds 102%, 104% and 88% of its uncompressed rate, connect-go 72%, 80% and 77%, and connect-rust 86%, 93% and 81%.</summary>

![Bars of the spans a second each Connect receiver holds over cleartext h2 with exports in gzip, zstd and brotli, as a share of the same receiver with uncompressed exports, and of its calls a second at peak, on arm64: connect-zig holds 102%, 104% and 88%, connect-go 72%, 80% and 77%, and connect-rust 86%, 93% and 81%](images/fullstack-compression-cleartext-arm64.svg)

</details>

<details>
<summary>Over TLS on x86-64, connect-zig holds 114%, 114% and 102% of its uncompressed rate, connect-go 77%, 84% and 80%, and connect-rust 88%, 91% and 84%.</summary>

![Bars of the spans a second each Connect receiver holds over TLS with exports in gzip, zstd and brotli, as a share of the same receiver with uncompressed exports, and of its calls a second at peak, on x86-64: connect-zig holds 114%, 114% and 102%, connect-go 77%, 84% and 80%, and connect-rust 88%, 91% and 84%](images/fullstack-compression.svg)

</details>

<details>
<summary>In cleartext h2 on x86-64, connect-zig holds 165%, 165% and 148% of its uncompressed rate, which its 64 call slots limited, connect-go 78%, 86% and 75%, and connect-rust 85%, 88% and 80%.</summary>

![Bars of the spans a second each Connect receiver holds over cleartext h2 with exports in gzip, zstd and brotli, as a share of the same receiver with uncompressed exports, and of its calls a second at peak, on x86-64: connect-zig holds 165%, 165% and 148%, connect-go 78%, 86% and 75%, and connect-rust 85%, 88% and 80%](images/fullstack-compression-cleartext.svg)

</details>

`tools/fullstack/compression.sh` runs the climb and the peak of the production model on the three
Connect receivers, once for each coding. stdx's encoders write each export as a connect-zig client
does: gzip at stdx's default level, and zstd and brotli at level 1. Each receiver decodes with its
library's own decoders, at their defaults: connect-zig with stdx's, connect-go with compress/gzip,
klauspost/compress and andybalholm/brotli, and connect-rust with flate2, zstd and brotli. Every
span is checked. The octets of each export:

| Export | Uncompressed | gzip | zstd | brotli |
| --- | ---: | ---: | ---: | ---: |
| 16 spans | 7,984 | 2,454 (3.3×) | 2,527 (3.2×) | 2,500 (3.2×) |
| 128 spans | 61,353 | 9,332 (6.6×) | 9,646 (6.4×) | 9,228 (6.6×) |
| 512 spans | 233,192 | 30,976 (7.5×) | 31,101 (7.5×) | 29,933 (7.8×) |

Each bar is a receiver's rate as a share of the same receiver's rate with uncompressed exports. So
a bar shows what a coding costs one library, and the bars of two libraries do not compare: the
charts above compare the libraries. A coding costs the time of its decoder. It also saves the TLS
and the HTTP/2 work on the octets it removes, and each share holds both.

The CPU a span, at the highest rate that a receiver's four climbs all held, against uncompressed:

| Receiver | Coding | arm64, TLS | x86-64, TLS | arm64, cleartext | x86-64, cleartext |
| --- | --- | ---: | ---: | ---: | ---: |
| connect-zig | gzip | -8% | -7% | +5% | +3% |
| connect-zig | zstd | -10% | -9% | +1% | +1% |
| connect-zig | brotli | +3% | +4% | +20% | +19% |
| connect-go | gzip | +23% | +22% | +26% | +23% |
| connect-go | zstd | +13% | +11% | +17% | +15% |
| connect-go | brotli | +23% | +17% | +20% | +29% |
| connect-rust | gzip | +7% | +8% | +15% | +5% |
| connect-rust | zstd | +4% | +7% | +15% | -1% |
| connect-rust | brotli | +11% | +19% | +24% | +11% |

Over TLS, gzip and zstd save connect-zig more CPU than its decoders spend: a span of a gzip export
costs it 8% less CPU than an uncompressed one on arm64. In cleartext there is no TLS to save, and
gzip and zstd cost it 1% to 5% more. Each coding costs connect-go 11% to 29% more CPU a span, and
connect-rust 1% less to 24% more.

Read the charts with four limits:

- connect-zig refuses a call when its 64 slots for calls in flight are all taken. An uncompressed
  export holds its slot longer while its octets arrive, so its climb can end on the slots before
  the core is busy. connect-zig's uncompressed climbs ended so on both machines, and the charts
  mark each such climb "slots full". So a rate share can overstate what a coding saves
  connect-zig. The CPU a span at a common rate does not.
- In cleartext on x86-64, connect-zig's gzip and zstd climbs passed every step, up to 32 exports a
  connection a second. Each rate is then at least 1,139,048 spans a second, and the chart marks it
  "≥".
- The x86-64 jobs over TLS and in cleartext ran on two CPU models, an AMD EPYC 7763 and an AMD EPYC
  9V45. Compare the shares within one chart.
- No OpenTelemetry exporter sends brotli.

At the peak, with one export sent again and again, an export of 16 spans costs each receiver more
in every coding: connect-zig answers 78% to 89% of its uncompressed calls a second over TLS on
arm64. An
export of 512 spans saves connect-zig more than it costs over TLS: it answers 120% and 122% in
gzip and zstd on arm64. The run's summary holds every table.

## Validation

One decode of a request message and one validation of it against the rules of
its schema, beside protovalidate-go, protovalidate-es on Node.js, protovalidate-buffa and
prost-protovalidate. From CI's [run 242](https://github.com/c4milo/connect-zig/actions/runs/45085140006), on an AMD EPYC 9V74 core: connect-zig is 12 to 58
times as fast as protovalidate-go, and the fastest of the five in all six cases. On a Neoverse-N2
core it is 14 to 68 times as fast, and the fastest in all six too.

![Bars of the speed of a decode with a validation through connect-zig, protovalidate-buffa, prost-protovalidate and protovalidate-es, in multiples of protovalidate-go's, on x86-64: connect-zig is 12 to 58 times as fast as protovalidate-go and the fastest in 6 of 6 cases](images/validate-vs-go.svg)

![Bars of the speed of a decode with a validation through connect-zig, protovalidate-buffa, prost-protovalidate and protovalidate-es, in multiples of protovalidate-go's, on arm64: connect-zig is 14 to 68 times as fast as protovalidate-go and the fastest in 6 of 6 cases](images/validate-vs-go-arm64.svg)

`tools/validate_compare_check.sh` times five implementations of protovalidate on one schema,
`bench/validate/proto`, and requires each to give each message the same verdict:

| Implementation | Language | How it checks a rule | Messages |
| --- | --- | --- | --- |
| connect-zig's `protovalidate` | Zig | Code the compiler makes from each rule, CEL included (decision 47) | the plugin's |
| [protovalidate-go](https://github.com/bufbuild/protovalidate-go) v1.4.1 | Go | Rules read from descriptors once, CEL run by cel-go | protoc-gen-go's |
| [protovalidate-es](https://github.com/bufbuild/protovalidate-es) 1.3.0 | TypeScript on Node.js | Rules read from descriptors once, CEL run by its own interpreter | protobuf-es 2.17.0 |
| [protovalidate-buffa](https://github.com/mathematic-inc/protovalidate-buffa) 0.8.0 | Rust | Rust code its plugin writes from each rule, CEL included | Buffa 0.9.2, connect-rust's codec |
| [prost-protovalidate](https://github.com/zs-dima/prost-protovalidate) 0.6.1 | Rust | Rules read through prost-reflect once, CEL run by an interpreter | prost 0.14 |

The first three are Buf's own. protovalidate-buffa and prost-protovalidate are the two Rust
crates most downloaded in November 2026, about 535,000 and 314,000 times; Buf publishes no Rust
library yet.

The schema holds three messages. `Small` has three fields of one standard rule each. `Medium` is a
typical request of an API: a standard rule of each kind, among them `uuid`, `email`, `uri`,
`hostname`, `ip`, a repeated field with `unique`, a map, a required message, bytes and a
duration, and two CEL rules of the message. `Rules` holds CEL rules alone, over lists, a map
and two fields. `bench/validate/cases` holds a valid and an invalid message of each as JSON, and
`buf convert` encodes them. Since step 35, `Medium`'s name takes a `pattern`, which its invalid
message breaks.

Each program keeps one validator for every call, as a server does, and times as
bench/measure.zig does: the median of 11 batches of about 20 ms. It times two things for each
message:

- the decode of its octets and one validation of what the decode gives, which a server runs for
  each request, and which the chart draws;
- one validation of the message decoded before, which the second table holds.

The first is the one to compare. connect-zig decodes with `decode_into`, as `connect_colibri`'s
route decodes a request: it reads each repeated field and map once, into storage that the
program owns (decision 37). So validation reads each list and each map as a slice, as the other
implementations read the lists their decode built. protovalidate-es reads the schema's
descriptors from a FileDescriptorSet, as code that protoc-gen-es writes builds them from an
embedded descriptor.

Each verdict is "valid", or "invalid:" and the rule ids of the violations in order. The check
fails when two implementations give one message different verdicts.

CI's [run 242](https://github.com/c4milo/connect-zig/actions/runs/45085140006) ran the check at commit 48bb3e1, on an AMD EPYC 9V74, x86-64, and on a
Neoverse-N2, arm64. Each of the five gave each message the same verdict on both. The nanoseconds of
one decode and one validation on x86-64, which the chart draws:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 39.9 | 671.7 | 1,081.9 | 98.9 | 655.2 |
| `Small`, invalid | 68.2 | 2,008.6 | 3,990.0 | 123.5 | 2,312.0 |
| `Medium`, valid | 523.5 | 6,495.1 | 30,773.4 | 885.6 | 28,618.3 |
| `Medium`, invalid | 451.0 | 11,658.9 | 34,090.2 | 1,171.8 | 37,633.1 |
| `Rules`, valid | 157.2 | 8,182.2 | 20,634.6 | 286.1 | 18,952.3 |
| `Rules`, invalid | 153.3 | 8,964.3 | 21,588.4 | 364.0 | 17,716.5 |

The nanoseconds of one validation of a message decoded before, on x86-64:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 17.1 | 415.9 | 452.6 | 36.9 | 586.4 |
| `Small`, invalid | 32.6 | 1,761.9 | 3,912.2 | 84.1 | 2,156.9 |
| `Medium`, valid | 314.8 | 4,572.9 | 30,209.9 | 318.9 | 27,118.5 |
| `Medium`, invalid | 306.2 | 9,949.8 | 31,440.5 | 666.0 | 35,702.5 |
| `Rules`, valid | 41.7 | 6,808.9 | 21,125.0 | 31.2 | 18,204.1 |
| `Rules`, invalid | 54.9 | 7,692.9 | 20,448.8 | 132.9 | 17,407.4 |

The same two on arm64:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 41.1 | 761.5 | 1,298.3 | 102.8 | 861.2 |
| `Small`, invalid | 44.9 | 2,717.0 | 4,432.7 | 151.3 | 2,645.5 |
| `Medium`, valid | 550.5 | 7,875.3 | 41,931.4 | 842.7 | 32,559.3 |
| `Medium`, invalid | 475.2 | 15,697.8 | 51,034.5 | 1,195.1 | 41,965.5 |
| `Rules`, valid | 160.8 | 10,376.3 | 23,241.8 | 278.9 | 21,946.6 |
| `Rules`, invalid | 167.1 | 11,338.0 | 24,959.0 | 376.1 | 20,261.3 |

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 18.3 | 512.9 | 747.5 | 46.7 | 798.1 |
| `Small`, invalid | 24.8 | 2,502.1 | 4,726.3 | 109.4 | 2,452.6 |
| `Medium`, valid | 313.5 | 5,408.9 | 35,384.4 | 343.6 | 30,927.7 |
| `Medium`, invalid | 284.9 | 13,748.3 | 44,322.1 | 755.3 | 40,389.1 |
| `Rules`, valid | 38.7 | 8,451.3 | 21,859.1 | 43.4 | 21,347.7 |
| `Rules`, invalid | 67.3 | 10,072.0 | 22,939.5 | 179.3 | 19,781.7 |

protovalidate-buffa validates one message faster, on x86-64 alone: the valid `Rules`, 31.2 ns to
41.7. Its plugin writes Rust code for each rule, as connect-zig's compiler does. Before 48bb3e1,
each element of a macro in that message waited for its result to reach the cache on x86-64, and
connect-zig took 55.4 ns to protovalidate-buffa's 26.2 in run 240 (docs/performance.md, "The
pitfalls").
