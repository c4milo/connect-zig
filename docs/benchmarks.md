# Benchmarks

How connect-zig's published numbers are measured, with every chart and every table behind them.
Each number comes from one named CI run, as [performance.md](performance.md) asks, and each
time compares only within one job on one machine.

## The codec

From CI's [run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610), on an Arm Neoverse-N2 core. Binary and JSON encoding and decoding of eight
messages, against Go's protobuf runtime and Buffa, connect-rust's codec. In the 16 cells the chart
draws, connect-zig is 3.2 to 18.9 times faster than Go and 1.1 to 2.2 times faster than Buffa.

![Bars of the speed of connect-zig and of Buffa, connect-rust's codec, in multiples of Go's protobuf runtime, connect-go's codec, on arm64: connect-zig is 3.2 to 18.9 times faster than Go's protobuf runtime, and 1.1 to 2.2 times faster than Buffa](images/speed-vs-go-arm64.svg)

`zig build bench` times binary and JSON encoding and decoding of eight messages, then a routed unary
call. `tools/bench_check.sh` runs the same inputs through Go's `google.golang.org/protobuf`
v1.36.12, connect-go's codec, and Buffa, connect-rust's codec. It checks that each writes the same
bytes as connect-zig. It runs the three programs in three rounds, each in an order rotated by one,
so a runner that slows over the job does not always slow the same language. Each cell is the
round whose time is the median. CI's two `bench-compare` jobs of commit `a69e377` ([run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610)) ran it
on Ubuntu 26.04: one on an Arm Neoverse-N2 core, which the chart draws, and one on an Intel Xeon
Platinum 8573C core (x86-64). There the same 16 cells give 4.5 to 21.7 times Go and 1.0 to 2.0
times Buffa. An x86-64 runner's CPU model changes from run to run. The run's summary holds every
table.

The chart draws the speed of connect-zig and of Buffa in multiples of Go's. A
longer bar is faster, and Go is the line at 1. The charts time the codecs alone, with no code of
connect-go or connect-rust. Each decode they draw reads every field. Go's and Buffa's decodes
build the whole message, and connect-zig's leaves a repeated field to be parsed when it is read,
so a decode alone would time less work on connect-zig's side. A binary decode with every field
read takes `decode_into`, which reads each repeated field once (decision 37). The table also gives
each decode alone.

The chart draws 16 of the table's 48 cells. Buffa is faster in none of them, on either machine.

In the table's 48 cells, connect-zig is 2.3 to 40.2 times faster than Go on arm64, and 2.2 to
36.9 times on x86-64. Against Buffa, connect-zig is faster in 43 of the 48 cells on arm64 and in
45 on x86-64, by up to 3.83 and 3.35 times. The two tie within 0.3% in one cell on arm64, varints
JSON decode. Buffa is faster in the other 4 on arm64 and 3 on x86-64. On arm64 it wins tree JSON
encode by 1.47 times, strings JSON encode by 1.15 times, packed JSON decode with every field read
by 1.10 times, and varints binary decode by 1.02 times. On x86-64 it wins packed JSON decode with
every field read by 1.22 times, tree JSON decode with every field read by 1.16 times, and packed
JSON decode by 1.09 times.

## The routed call

From CI's [run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610), on an Arm Neoverse-N2 core. One unary call in memory through each library's
router, protocol and codec. connect-zig is 9.6 to 12.4 times as fast as connect-go, and 3.3 to 5.6
times as fast as connect-rust.

![Bars of the speed of a routed unary call through connect-zig and connect-rust, in multiples of connect-go's, on arm64: connect-zig is 9.6 to 12.4 times as fast as connect-go, and 3.3 to 5.6 times as fast as connect-rust](images/call-vs-go-arm64.svg)

The routed calls (`bench/call.zig`) run the same unary call in memory through connect-zig,
connect-go and connect-rust: the router, the route, the protocol and the codec, with no socket, no
TLS and no HTTP/2 framing. connect-go's router is an `http.ServeMux`, as a server's is. Each program
builds its request once and times the calls alone. connect-zig replays a request head that colibri
has already parsed. connect-go copies a request that `httptest` built once, and writes into one
response writer that each call clears. connect-rust clones a head that `http::Request::builder`
made once, since its service takes each request by value. Before run 265, connect-go built an
`httptest` request and recorder in each timed call, and connect-rust a request: connect-zig was then
14.9 to 22.9 times as fast as connect-go on arm64, and 3.4 to 6.5 times connect-rust. CI's two
`bench-compare` jobs of commit `a69e377` ([run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610)) timed them on colibri v0.19.2 and Ubuntu 26.04,
on an Arm Neoverse-N2 core and on an Intel Xeon Platinum 8573C core. On x86-64, connect-zig is 9.4
to 11.6 times as fast as connect-go and 2.9 to 5.0 times connect-rust. The chart's bars give a speed
in multiples of connect-go's, and connect-zig's bar also gives its time for one call, in a table of
one route.

The small message's call also runs in tables of 16 and 256 routes: 4 and 16 services of as many
methods, with the call's route among them. colibri finds a route by a binary search over each path
segment, 8 octets at a time since colibri v0.19.0, connect-rust by a hash map of the path, and
Go's `ServeMux` by a tree of maps. So connect-zig's call grows with the table, where the other two
stay within 2%. On CI's judge it takes 4,237 instructions with one route and 4,460 with 256, 5%
more. In time it grew 16% on arm64 and 11% on x86-64 in this run. The time of the small Connect
call, in nanoseconds:

| Router | 1 route | 16 routes | 256 routes |
| --- | ---: | ---: | ---: |
| connect-zig, arm64 | 337 | 351 | 391 |
| connect-rust, arm64 | 1,766 | 1,767 | 1,788 |
| connect-go, arm64 | 3,221 | 3,209 | 3,261 |
| connect-zig, x86-64 | 314 | 320 | 348 |
| connect-rust, x86-64 | 1,505 | 1,533 | 1,522 |
| connect-go, x86-64 | 2,938 | 2,912 | 2,925 |

## Whole servers on a socket

From CI's [run 256](https://github.com/c4milo/connect-zig/actions/runs/45171587471), on an Arm Neoverse-N2 core; the x86-64 chart is under it. An OTLP receiver on one core, over TLS and h2, takes the traffic of one gateway
core for 33,000 servers. connect-zig holds 8.0 times connect-go's spans a second and 2.8 times
connect-rust's, in 321 MiB that it takes at start.

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, and lines of p99 as the rate climbs, on arm64: connect-zig holds 760,998 spans a second, 8.0 times connect-go's 95,668, 2.8 times connect-rust's 275,894, 3.6 times the OpenTelemetry Collector's 213,600 and 11.4 times Vector's 66,748](images/fullstack-arm64.svg)

<details>
<summary>On x86-64, connect-zig passed every step of the climb, so it holds at least 6.1 times connect-go's spans a second, 2.3 times connect-rust's, 3.4 times the Collector's and 10.8 times Vector's.</summary>

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, and lines of p99 as the rate climbs, on x86-64: connect-zig passed every step, to at least 1,139,240 spans a second, at least 6.1 times connect-go's 186,900, 2.3 times connect-rust's 493,950, 3.4 times the OpenTelemetry Collector's 335,886 and 10.8 times Vector's 105,646](images/fullstack.svg)

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
less than 95% of the spans sent. Then five more steps halve the gap to the last step that passed.
A bar's whisker reaches the step that failed: it gives the climb's step, not the spread of the rate
between runs, which the limits below give. oha runs on two CPUs of its own, and the server on a
CPU that shares no physical core with them (`tools/fullstack/placement.py`). A step that fails while oha's two cores were 90% busy or more ends the
climb on the load, not on the server: oha corrects its latency for each call it sends late, so a
load that falls behind would show as the server's p99. The rate held is then a floor. The share
counts all the work on oha's cores, the kernel's for the traffic oha sends included. CI's two
`fullstack` jobs of commit `57ec581` ([run
256](https://github.com/c4milo/connect-zig/actions/runs/45171587471)) ran it on
colibri v0.19.2 and Ubuntu 26.04, on an Arm Neoverse-N2 core and on an AMD EPYC 9V45 core. The charts show the climb
over TLS 1.3: one core of connect-zig held 8.0 times connect-go's spans a second on arm64 and at
least 6.1 times on x86-64, 2.8 and 2.3 times connect-rust's, 3.6 and 3.4 times the Collector's,
and 11.4 and 10.8 times Vector's.

Rotel has no TLS on its receiver, so a second climb runs in cleartext h2 for connect-zig, the
Collector and Rotel. There one core of connect-zig holds 3.6 times Rotel's spans a second and 4.2
times the Collector's on arm64, and at least 2.6 and 3.5 times on x86-64.

<details>
<summary>The climb in cleartext h2, on arm64 and on x86-64.</summary>

![Bars of the spans a second one core holds with p99 under 100 ms over cleartext h2, and lines of p99 as the rate climbs, on arm64: connect-zig holds 800,952 spans a second, 3.6 times Rotel's 224,802 and 4.2 times the OpenTelemetry Collector's 191,334](images/fullstack-cleartext-arm64.svg)

![Bars of the spans a second one core holds with p99 under 100 ms over cleartext h2, and lines of p99 as the rate climbs, on x86-64: connect-zig passed every step, to at least 1,139,264 spans a second, at least 2.6 times Rotel's 445,000 and 3.5 times the OpenTelemetry Collector's 327,098](images/fullstack-cleartext.svg)

</details>

The CPU time a span, at each server's highest step, in µs. A span costs less CPU as the rate
rises: each step's 516 TLS handshakes, and each wake of the core, are shared among more spans. So
the table favours a server whose highest step is higher. The sections on protovalidate and compression below compare at a common rate:

| Server | arm64, TLS | x86-64, TLS | arm64, cleartext | x86-64, cleartext |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 1.31 | 0.88 | 1.26 | 0.88 |
| connect-rust | 3.64 | 1.78 | | |
| connect-go | 9.80 | 5.09 | | |
| Collector | 4.56 | 2.76 | 5.25 | 3.06 |
| Vector | 13.34 | 6.41 | | |
| Rotel | | | 4.46 | 2.16 |

connect-zig takes all its memory when it starts: 321 MiB, for 528 connections and 64 calls at
once, each call with 1 MiB to decode its export into. Its route's `reply_bytes` of 4 KiB took
31 MiB off the 352 MiB of run 250 (design §8 step 39). colibri v0.19.2's `Router.init` starts the
router in place; a router set to `.{}` copied its default value from the program's image, and the
sink grew to 500 MiB in run 248. Over TLS on arm64, connect-rust grew to 52 MiB, connect-go to
146 MiB, the Collector to 755 MiB and Vector to 743 MiB; in cleartext, Rotel grew to 324 MiB.

On arm64, connect-zig's climbs ended when p99 passed 100 ms, with its core busy all the time. On
x86-64 they passed every step, up to 1,139,200 spans a second sent, the top of run 256's climb.
There its rate is a floor, and each ratio over it is at least its value. The climb now reaches 48
exports a connection a second, 1,708,800 spans a second. Every other server's climb ended
when p99 passed 100 ms. A runner's CPU model changes from run to run on x86-64, so its rates move
between runs; the arm64 runner has been a Neoverse-N2 in each run.

Read these numbers with their limits:

- Every server and oha run on one machine, and talk over its loopback device: no network card, no
  second machine, no lost packet.
- Each server climbs once in each job. Between runs 250 and 256, on the same AMD EPYC 9V45, the same
  competitors' rates moved by up to 38% on x86-64. On arm64 the plain servers moved by 3% or less,
  and connect-rust with protovalidate-buffa by 8%. Read an x86-64 number as one sample, and a
  difference of a few percent as no difference.
- Each step opens its 516 connections again, and its measure leaves out the first 2 s, where their
  TLS handshakes run. Only connect-zig's sink refuses a call there: past its 64 calls at once it
  answers 503, where the other servers queue the call. In the step it held over TLS on arm64, it
  refused 88 calls in those 2 s, and none after. The 2 s window came after run 248, whose climbs of
  connect-zig ended on such refusals. A load that kept its connections open across steps would need
  no such window.
- Run 256 ran before the check of oha's cores, so its steps did not measure them. It also pinned
  the server to CPU 1 and oha to CPUs 2 and 3 without reading which CPUs share a physical core. An
  x86-64 runner with two threads a core may have run the server and a thread of oha on one core.
  From the next run the pins follow Linux's CPU topology, and the machine line gives the threads of
  a core.
- oha can pin no TLS suite, and Go's server cannot be told one, so each server chose its own from
  oha's offer. Go's servers likely chose AES-128-GCM, and connect-zig's sink and rustls's
  AES-256-GCM. From the next run each report names the suite each server chose.
- In run 256, connect-zig's sink was built for the machine's own CPU, and connect-go,
  connect-rust and the other servers for their architecture's generic CPU. From the next run,
  connect-go and connect-rust are built for the machine's CPU too: Go at the highest level of the
  CPU that it names, and Rust with LTO and `target-cpu=native` (`tools/host_cpu.sh`). The
  Collector, Vector and Rotel stay their projects' release builds. The peak part also runs
  connect-zig built for the generic CPU, which shows what the build for the host's CPU gives it.
- The sink's limits fit this load: 528 connections for its 516, and 64 calls at once, which h2load's
  16 connections of 4 streams fill at the peak. A core with more connections, or with exports over
  256 KiB, needs larger limits and more memory.
- Each class sends one export again and again, so a decoder reads the same octets each time.

Vector's and Rotel's p99 stays near 40 ms from a low rate. Neither sets `TCP_NODELAY` on the
sockets it accepts, so Nagle's algorithm waits for Linux's delayed ACK. With `TCP_NODELAY` set
from outside, their p99 fell to about 5 ms, but neither held a higher rate. So the climb runs them
as they ship. connect-rust's server sets it.

The same jobs also load each server over TLS as fast as it answers, with exports of 16 and of 512
spans, not compressed, on 16 connections of 4 streams. The calls a second:

| Server | 16 spans, arm64 | 512 spans, arm64 | 16 spans, x86-64 | 512 spans, x86-64 |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 41,871 | 1,613 | 67,235 | 2,663 |
| connect-rust | 17,789 | 1,076 | 33,039 | 1,857 |
| connect-go | 5,273 | 363 | 9,652 | 717 |
| Collector | 13,629 | 757 | 27,020 | 1,442 |
| Vector | 4,427 | 248 | 13,180 | 395 |

### With protovalidate

From the same run, on an Arm Neoverse-N2 core over TLS; the x86-64 chart is under it. Each
Connect receiver runs a second time, and checks every span of each export against OTLP's span
rules before it counts it. With validation, one core of connect-zig keeps 86% of its
spans a second, connect-rust 95% and connect-go 61%. So connect-zig with protovalidate holds 2.5
times connect-rust's spans a second with protovalidate-buffa, and 11.2 times connect-go's with
protovalidate-go.

![Bars of the spans a second one core holds over TLS with p99 under 100 ms, for each Connect receiver without and with protovalidate, and lines of p99 as the rate climbs, on arm64: connect-zig keeps 86% of its rate with protovalidate, 654,086 spans a second, connect-rust with protovalidate-buffa 95%, 262,530, and connect-go with protovalidate-go 61%, 58,386](images/fullstack-validate-arm64.svg)

<details>
<summary>On x86-64, connect-zig keeps at most 95% of its spans a second with validation, connect-go 63%, and connect-rust's validating climb held more than its plain one.</summary>

![Bars of the spans a second one core holds over TLS with p99 under 100 ms, for each Connect receiver without and with protovalidate, and lines of p99 as the rate climbs, on x86-64: connect-zig keeps at most 95% of its rate with protovalidate, 1,085,778 spans a second, connect-rust with protovalidate-buffa 107%, 529,582, and connect-go with protovalidate-go 63%, 116,840](images/fullstack-validate.svg)

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
| connect-zig | 86% | +11% | ≤95% | +6% |
| connect-rust | 95% | +6% | 107% | +3% |
| connect-go | 61% | +53% | 63% | +54% |

The CPU a span compares each receiver with its twin at the highest rate both climbs held, since a
span costs less CPU as the rate rises. On arm64 that rate was 569,600 spans a second for
connect-zig, 249,200 for connect-rust and 53,400 for connect-go, and on x86-64 it was 854,400,
427,200 and 71,200. It is the measure to read: the rate kept moves with one step of a climb. On
x86-64, connect-zig's plain climb passed every step, so it kept at most 95%. connect-rust's plain
climb failed at 498,400 spans a second with a p99 of 597 ms, a step its validating twin passed
with a p99 of 2.66 ms.

At the peak, with one export sent again and again, validation costs connect-zig 3.0 µs a call of
16 spans and 90.0 µs a call of 512 spans on arm64: 0.18 to 0.19 µs a span. It costs connect-rust 7.0
and 90.0 µs, 0.18 to 0.44 µs a span, and connect-go 127 and 2,708 µs, 5.3 to 7.9 µs a span.

connect-zig decodes each export into storage that its route owns, 1 MiB a call in the sink
(decision 37). A list that does not fit is parsed again by each read, and validation reads every
list. With 256 KiB, a 512-span export did not fit, and protovalidate cost the sink 0.96 µs a span;
with 1 MiB it costs 0.16 µs (`zig build otlp-validate-cost`). So a route's storage now defaults to
4 times its `message_bytes`, and a context field `messages_past_storage` counts the requests that
did not fit. The check fails when the sink counts one.

### With compression

From the same run, on an Arm Neoverse-N2 core over TLS; the other three charts are under it.
connect-zig, connect-go and connect-rust each take the production model's exports uncompressed and
in gzip, zstd and brotli. Over TLS, one core of connect-zig holds 15% more spans a second in gzip
than uncompressed, 18% more in zstd and 2% more in brotli. connect-go holds 19% to 24% fewer, and
connect-rust between 10% fewer and 1% more.

![Bars of the spans a second each Connect receiver holds over TLS with exports in gzip, zstd and brotli, as a share of the same receiver with uncompressed exports, and of its calls a second at peak, on arm64: connect-zig holds 115%, 118% and 102%, connect-go 76%, 81% and 80%, and connect-rust 95%, 101% and 90%](images/fullstack-compression-arm64.svg)

<details>
<summary>In cleartext h2 on arm64, connect-zig holds 110%, 112% and 95% of its uncompressed rate, connect-go 73%, 84% and 77%, and connect-rust 86%, 90% and 81%.</summary>

![Bars of the spans a second each Connect receiver holds over cleartext h2 with exports in gzip, zstd and brotli, as a share of the same receiver with uncompressed exports, and of its calls a second at peak, on arm64: connect-zig holds 110%, 112% and 95%, connect-go 73%, 84% and 77%, and connect-rust 86%, 90% and 81%](images/fullstack-compression-cleartext-arm64.svg)

</details>

<details>
<summary>Over TLS on x86-64, connect-zig holds 121%, 125% and 98% of its uncompressed rate, connect-go 81%, 93% and 87%, and connect-rust 85%, 92% and 79%.</summary>

![Bars of the spans a second each Connect receiver holds over TLS with exports in gzip, zstd and brotli, as a share of the same receiver with uncompressed exports, and of its calls a second at peak, on x86-64: connect-zig holds 121%, 125% and 98%, connect-go 81%, 93% and 87%, and connect-rust 85%, 92% and 79%](images/fullstack-compression.svg)

</details>

<details>
<summary>In cleartext h2 on x86-64, connect-zig holds 101%, 104% and 85% of its uncompressed rate, connect-go 70%, 83% and 74%, and connect-rust 70%, 89% and 75%.</summary>

![Bars of the spans a second each Connect receiver holds over cleartext h2 with exports in gzip, zstd and brotli, as a share of the same receiver with uncompressed exports, and of its calls a second at peak, on x86-64: connect-zig holds 101%, 104% and 85%, connect-go 70%, 83% and 74%, and connect-rust 70%, 89% and 75%](images/fullstack-compression-cleartext.svg)

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

The compression parts run `otlp-sink-compression`, connect-zig's sink with room for 256 calls at
once, where the other parts' sink holds 64. An uncompressed export holds its call longer while its
octets arrive. In run 250, with 64 calls, each uncompressed climb of connect-zig ended on a refused
call while its p99 stayed near 3 ms. With 256, each ended when p99 passed 100 ms, with its core
busy, as every other climb here did. The 256 calls take the sink to about 666 MiB.

The CPU a span, at the highest rate that a receiver's four climbs all held, against uncompressed:

| Receiver | Coding | arm64, TLS | x86-64, TLS | arm64, cleartext | x86-64, cleartext |
| --- | --- | ---: | ---: | ---: | ---: |
| connect-zig | gzip | -7% | -7% | +2% | +8% |
| connect-zig | zstd | -8% | -12% | +0% | +3% |
| connect-zig | brotli | +3% | +10% | +15% | +28% |
| connect-go | gzip | +25% | +26% | +31% | +33% |
| connect-go | zstd | +16% | +5% | +18% | +16% |
| connect-go | brotli | +21% | +15% | +22% | +27% |
| connect-rust | gzip | +4% | +17% | +15% | +16% |
| connect-rust | zstd | +3% | +17% | +12% | +13% |
| connect-rust | brotli | +13% | +27% | +23% | +30% |

Over TLS, gzip and zstd save connect-zig more CPU than its decoders spend: a span of a gzip export
costs it 7% less CPU than an uncompressed one, and of a zstd export 8% to 12% less. In cleartext
there is no TLS to save, and gzip and zstd cost it 0% to 8% more. Brotli costs it 3% to 28% more.
Each coding costs connect-go 5% to 33% more CPU a span, and connect-rust 3% to 30% more.

Read the charts with three limits:

- The two x86-64 jobs ran on an Intel Xeon 6975P-C, where the other x86-64 jobs of the run ran on
  AMD EPYC cores. Compare a share only with the shares of its own chart.
- No OpenTelemetry exporter sends brotli.
- A receiver's own climb can move by a step between codings, as connect-rust's zstd climb over TLS
  on arm64 shows: 101% of its uncompressed rate, at 3% more CPU a span. The CPU a span at a common
  rate does not move so.

At the peak, with one export sent again and again, an export of 16 spans costs each receiver more
in every coding: connect-zig answers 78% to 88% of its uncompressed calls a second over TLS on
arm64. An export of 512 spans saves connect-zig more than it costs over TLS: it answers 121% in
gzip and in zstd on arm64. The run's summary holds every table.

## Validation

One decode of a request message and one validation of it against the rules of
its schema, beside protovalidate-go, protovalidate-es on Node.js, protovalidate-buffa and
prost-protovalidate. From CI's [run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610), on an Arm Neoverse-N2 core: connect-zig is 15 to 65
times as fast as protovalidate-go, and the fastest of the five in all six cases. On an AMD EPYC
9V74 core it is 13 to 57 times as fast, and the fastest in all six too.

![Bars of the speed of a decode with a validation through connect-zig, protovalidate-buffa, prost-protovalidate and protovalidate-es, in multiples of protovalidate-go's, on arm64: connect-zig is 15 to 65 times as fast as protovalidate-go and the fastest in 6 of 6 cases](images/validate-vs-go-arm64.svg)

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

CI's [run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610) ran the check at commit a69e377, on a Neoverse-N2, arm64, which the chart draws, and on
an AMD EPYC 9V74, x86-64. Each of the five gave each message the same verdict on both. The
nanoseconds of one decode and one validation on arm64, which the chart draws:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 40.4 | 803.2 | 1,272.1 | 105.5 | 892.8 |
| `Small`, invalid | 44.4 | 2,658.9 | 4,417.2 | 145.7 | 2,676.9 |
| `Medium`, valid | 543.8 | 8,008.0 | 41,656.8 | 869.6 | 32,386.1 |
| `Medium`, invalid | 457.0 | 15,683.5 | 53,551.2 | 1,215.3 | 42,165.5 |
| `Rules`, valid | 163.7 | 10,539.2 | 23,272.4 | 283.0 | 21,555.7 |
| `Rules`, invalid | 174.9 | 11,419.3 | 24,849.2 | 395.6 | 19,970.5 |

The nanoseconds of one validation of a message decoded before, on arm64:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 18.2 | 508.9 | 692.1 | 45.3 | 816.3 |
| `Small`, invalid | 23.2 | 2,410.1 | 4,092.9 | 103.2 | 2,504.4 |
| `Medium`, valid | 323.0 | 5,490.4 | 34,641.7 | 357.4 | 31,029.0 |
| `Medium`, invalid | 284.2 | 13,410.1 | 43,027.5 | 744.4 | 40,356.2 |
| `Rules`, valid | 38.8 | 8,750.7 | 22,090.7 | 41.1 | 20,865.3 |
| `Rules`, invalid | 66.4 | 9,870.5 | 22,944.9 | 164.4 | 19,461.3 |

The same two on x86-64:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 49.9 | 835.3 | 1,393.3 | 141.3 | 883.4 |
| `Small`, invalid | 64.8 | 2,704.8 | 5,171.3 | 156.9 | 2,899.2 |
| `Medium`, valid | 624.8 | 8,398.6 | 43,887.6 | 1,165.0 | 37,535.5 |
| `Medium`, invalid | 535.6 | 15,580.9 | 45,959.9 | 1,423.4 | 49,045.6 |
| `Rules`, valid | 210.0 | 10,967.5 | 26,706.5 | 354.0 | 25,703.2 |
| `Rules`, invalid | 207.0 | 11,770.3 | 27,607.3 | 450.3 | 23,695.8 |

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 23.3 | 541.5 | 569.8 | 51.4 | 782.3 |
| `Small`, invalid | 26.3 | 2,429.9 | 4,298.6 | 102.3 | 2,658.2 |
| `Medium`, valid | 407.9 | 5,768.5 | 48,798.8 | 366.2 | 35,453.1 |
| `Medium`, invalid | 379.4 | 13,220.4 | 43,751.1 | 764.4 | 46,062.0 |
| `Rules`, valid | 51.2 | 9,073.6 | 25,761.3 | 37.0 | 24,226.3 |
| `Rules`, invalid | 72.7 | 10,356.4 | 25,293.8 | 163.1 | 23,084.8 |

On x86-64, protovalidate-buffa validates two messages decoded before faster than connect-zig: the
valid `Rules`, 37.0 ns to 51.2, and the valid `Medium`, 366.2 ns to 407.9. Its plugin writes Rust
code for each rule, as connect-zig's compiler does. A decode and a validation together, which a
server runs for each request, take connect-zig less time in all six cases on both machines. Before
48bb3e1, each element of a macro in the `Rules` message waited for its result to reach the cache
on x86-64, and connect-zig took 55.4 ns to protovalidate-buffa's 26.2 in run 240
(docs/performance.md, "The pitfalls").
