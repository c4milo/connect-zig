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
router, protocol, and codec. connect-zig is 9.6 to 12.4 times as fast as connect-go, and 3.3 to 5.6
times as fast as connect-rust.

![Bars of the speed of a routed unary call through connect-zig and connect-rust, in multiples of connect-go's, on arm64: connect-zig is 9.6 to 12.4 times as fast as connect-go, and 3.3 to 5.6 times as fast as connect-rust](images/call-vs-go-arm64.svg)

The routed calls (`bench/call.zig`) run the same unary call in memory through connect-zig,
connect-go, and connect-rust: the router, the route, the protocol, and the codec, with no socket, no
TLS, and no HTTP/2 framing. connect-go's router is an `http.ServeMux`, as a server's is. Each program
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

From CI's [run 266](https://github.com/c4milo/connect-zig/actions/runs/45246119951), on an Arm Neoverse-N2 core; the x86-64 chart is under it. An OTLP receiver on one core, over TLS and h2, takes the traffic of one gateway
core for 33,000 servers. connect-zig holds 7.0 times connect-go's spans a second and 2.7 times
connect-rust's. In this run it took 321 MiB at start; it now starts in 6 MiB (decision 48).

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, the median of three rounds with their range, and lines of p99 as the rate climbs, on arm64: connect-zig holds 711,570 spans a second, 7.0 times connect-go's 101,213, 2.7 times connect-rust's 263,440, 3.3 times the OpenTelemetry Collector's 215,818, and 8.6 times Vector's 82,310](images/fullstack-arm64.svg)

<details>
<summary>On x86-64, connect-zig holds 6.2 times connect-go's spans a second, 2.1 times connect-rust's, 3.0 times the Collector's, and 7.5 times Vector's.</summary>

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, the median of three rounds with their range, and lines of p99 as the rate climbs, on x86-64: connect-zig holds 990,541 spans a second, 6.2 times connect-go's 160,510, 2.1 times connect-rust's 476,179, 3.0 times the OpenTelemetry Collector's 327,675, and 7.5 times Vector's 132,786](images/fullstack.svg)

</details>

`tools/fullstack_check.sh` loads whole servers on real sockets over HTTP/2, each with the same
OTLP exports. The servers:

- connect-zig's OTLP receiver, `tools/otlp_sink`.
- The [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) v0.165.0, the server
  most companies run to take OpenTelemetry's traces, with its OTLP receiver and its `nop`
  exporter.
- [Vector](https://vector.dev/) v0.62.0, in Rust, with its `opentelemetry` source and its
  `blackhole` sink. The source converts each span into Vector's own event, its default. Its
  `otlp` codec keeps OTLP's form, but answered fewer than half the calls a second. Its gRPC
  listener speaks TLS 1.2 alone.
- [Rotel](https://github.com/streamfold/rotel) v0.2.7, the OpenTelemetry collector in Rust, with
  its OTLP receiver and its `blackhole` exporter. Its receiver has no TLS.
- Receivers on the other Connect libraries:
  [connect-go](https://github.com/connectrpc/connect-go) v1.18.1 on `net/http`, and
  [connect-rust](https://github.com/connectrpc/connect-rust) v0.9.1 on hyper and rustls
  (`tools/fullstack/connect-go` and `tools/fullstack/connect-rust`). Each counts the spans of
  each export and drops it, as connect-zig's receiver does.

Each server decodes and checks every span, counts it, and drops it. Each runs on one core, the
Collector and connect-go with `GOMAXPROCS=1`, Vector with one thread, and connect-rust with one
tokio worker. connect-zig's sink is built for the machine's CPU, connect-go at the highest level
of the CPU that Go names, and connect-rust with LTO and `target-cpu=native`. The Collector, Vector,
and Rotel run their projects' release builds. Each run checks every span.

The production model stands for one core of a 64-core gateway that 33,000 servers send their traces
to. Each server holds 516 connections. 70%, 25%, and 5% of them send gzip exports of 16, 128, and 512
spans. The load, `tools/fullstack/load`, opens the 516 connections once and keeps them across the
climb, as the agents keep theirs. Each connection sends 32 versions of its class's export in turn,
so a decoder does not read the same octets on every call. It sends at fixed rates, each
connection on a schedule of its own, and counts each call's latency from the instant its schedule
set, so a call that waits in a queue counts its wait. It offers AES-128-GCM alone: every server
runs TLS_AES_128_GCM_SHA256, and Vector ECDHE-ECDSA-AES128-GCM-SHA256 in TLS 1.2. Each step lasts
10 s, and every call counts. The rate climbs until p99 passes 100 ms, a call is refused, or the
server takes less than 95% of the spans sent. Then five more steps halve the gap to the last step
that passed.

Each server runs three rounds, each on a new process. The first climbs from the lowest rate. Each
later round starts from a step at half the rate the first held, then brackets that rate and halves
the gap four times. Each round runs the servers in an order rotated by one. The chart's bar is the
median round, and its whisker spans the rates the three rounds held. A ratio of two servers is
also given round by round, since one round runs both near in time. The load runs on two CPUs of a
physical core of their own, and the server on a CPU of another core
(`tools/fullstack/placement.py`). The load's cores were 3% to 23% busy at the rates held, far
from the 90% at which a step ends as the load's.

The rate each core holds over TLS, the median of three rounds, with the range of the rounds:

| Server | arm64 | arm64 range | x86-64 | x86-64 range |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 711,570 | 711,570–729,800 | 990,541 | 943,400–1,037,747 |
| connect-rust | 263,440 | 263,440–284,800 | 476,179 | 464,264–476,179 |
| Collector | 215,818 | 215,818–215,818 | 327,675 | 304,818–335,312 |
| connect-go | 101,213 | 98,715–101,213 | 160,510 | 144,053–164,672 |
| Vector | 82,310 | 80,261–82,310 | 132,786 | 86,782–137,462 |

Round by round, connect-zig held 2.56 to 2.70 times connect-rust's spans a second on arm64 and
1.98 to 2.24 times on x86-64, 3.30 to 3.38 and 3.02 to 3.09 times the Collector's, 7.03 to 7.21
and 5.73 to 7.20 times connect-go's, and 8.65 to 8.87 and 7.46 to 10.87 times Vector's.

After its rounds, each server ran one step of 60 s at its median rate, on a new process. On
arm64, every Connect receiver held it, and the Collector and Vector did not: the Collector's p99
reached 102 ms, and Vector's 2.7 s. On x86-64, every server but two held it: Vector's p99 reached
10.5 s, and connect-rust with protovalidate-buffa's 273 ms. In run 265 on other runners, most
servers failed the long step on x86-64, connect-zig among them. Read a rate held as the edge of
what a core takes for 10 s, not as a rate to plan a fleet on.

The most spans a second a step of the first round held with p99 at most 10 ms, a latency an
interactive caller would accept:

| Server | arm64 | x86-64 |
| --- | ---: | ---: |
| connect-zig | 569,600 | 569,600 |
| connect-rust | 284,800 | 284,800 |
| Collector | 71,200 | 142,400 |
| connect-go | 53,400 | 71,200 |
| Vector | 71,200 | 71,200 |

The CPU time a span at each server's median rate, in µs, and its peak memory. A span costs less
CPU as the rate rises, since each wake of the core serves more calls, so the table favours a
server whose rate is higher. The sections on protovalidate and compression below compare at a
common rate:

| Server | arm64, µs | x86-64, µs | arm64, MiB | x86-64, MiB |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 1.41 | 1.01 | 321 | 322 |
| connect-rust | 3.81 | 2.08 | 54 | 52 |
| Collector | 4.64 | 2.95 | 484 | 482 |
| connect-go | 9.83 | 5.69 | 190 | 192 |
| Vector | 12.16 | 6.32 | 1,484 | 1,479 |

In this run connect-zig took all its memory when it started: 321 MiB, for 528 connections and 64
calls at once, each call with 1 MiB to decode its export into and 4 KiB for its reply (design §8
step 39). connect-rust held a sixth of it. Since [decision 48](decisions.md), a page of the sink's
memory is taken only when the sink first writes it: it starts in 6 MiB, and under the peak part's
64 calls of 512 spans it grew to 75 MiB on an x86-64 machine. Vector held twice the memory it held in run 256, when the load
sent one export again and again; no check here measures why.

Rotel has no TLS on its receiver, so a check of its own, `fullstack-cleartext`, climbs in
cleartext h2 for connect-zig, the Collector, and Rotel, on x86-64 alone. There connect-zig held
820,142 spans a second, 4.14 times the Collector's 198,018 and 3.41 times Rotel's 240,307, and 3.77
to 4.36 and 3.41 to 3.59 times round by round. All three held their rate for 60 s. Rotel grew to
327 MiB, and the Collector to 186 MiB.

Read these numbers with their limits:

- Every server and the load run on one machine, and talk over its loopback device: no network
  card, no second machine, no lost packet.
- Three rounds narrow the spread of one job, not of the runner: an x86-64 runner's CPU model
  changes from job to job, and this run's x86-64 jobs ran on AMD EPYC 9V45, AMD EPYC 7763, and
  Intel Xeon 6973P-C and 6975P-C cores. Compare a number only with the numbers of its own table.
  The arm64 runner has been a Neoverse-N2 in each run.
- On x86-64 the server's CPU shares its physical core with the CPU where the scripts run, which
  sleep while a step runs.
- connect-zig's sink holds 64 calls at once, and answers 503 past them. Its climbs end there when
  its core falls behind, where the other servers queue the call. The limit fits this load: h2load's
  16 connections of 4 streams fill it at the peak. A core with more connections, or with exports
  over 256 KiB, needs larger limits and more memory.

In earlier runs, Vector's and Rotel's p99 stayed near 40 ms from a low rate. Neither sets
`TCP_NODELAY` on the sockets it accepts, so Nagle's algorithm waits for Linux's delayed ACK. With
`TCP_NODELAY` set from outside, their p99 fell to about 5 ms, but neither held a higher rate. So
the climb runs them as they ship. connect-rust's server sets it.

The check `fullstack-peak` also loads each server over TLS as fast as it answers, with exports of
16 and of 512 spans, not compressed, on 16 connections of 4 streams, on x86-64 alone. It runs
connect-go a second time with `GOGC=off` and `GOMEMLIMIT=320MiB`, about the memory connect-zig's
sink takes, so Go's collector runs only as its heap nears that, and connect-zig a second time
built for the generic CPU. The calls a second, the median of three rounds, on an Intel Xeon
6975P-C core:

| Server | 16 spans | 512 spans | Peak MiB |
| --- | ---: | ---: | ---: |
| connect-zig | 60,294 | 2,104 | 322 |
| connect-zig, generic CPU | 56,558 | 1,974 | 322 |
| connect-rust | 34,493 | 1,731 | 18 |
| Collector | 21,410 | 1,117 | 160 |
| Vector | 10,050 | 357 | 306 |
| connect-go | 8,132 | 529 | 53 |
| connect-go, 320 MiB | 9,765 | 647 | 315 |

With connect-zig's memory, connect-go answers 20% to 22% more calls a second and spends 17% to 18%
less CPU a call. connect-zig still answers 6.2 times its calls of 16 spans and 3.3 times its calls
of 512. Built for the generic CPU, connect-zig answers 93.8% of the calls of its build for this
CPU.

### With protovalidate

From the same run, on an Arm Neoverse-N2 core over TLS. Each Connect receiver runs a second time,
and checks every span of each export against OTLP's span rules before it counts it. With
validation, one core of connect-zig keeps 87% of its spans a second, connect-rust 94%, and
connect-go 62%. So connect-zig with protovalidate holds 2.5 times connect-rust's spans a second
with protovalidate-buffa, and 9.8 times connect-go's with protovalidate-go.

![Bars of the spans a second one core holds over TLS with p99 under 100 ms, for each Connect receiver without and with protovalidate, the median of three rounds, and lines of p99 as the rate climbs, on arm64: connect-zig keeps 87% of its rate with protovalidate, 618,528 spans a second, connect-rust with protovalidate-buffa 94%, 246,982, and connect-go with protovalidate-go 62%, 62,858](images/fullstack-validate-arm64.svg)

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

The rate each core keeps over TLS, the median of the rounds with their range round by round, and
what validation costs it in CPU a span:

| Receiver | arm64, rate kept | arm64, CPU a span | x86-64, rate kept | x86-64, CPU a span |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 87% (85% to 87%) | +12% | 91% (87% to 93%) | +4% |
| connect-rust | 94% (87% to 94%) | +9% | 94% (89% to 96%) | +6% |
| connect-go | 62% (62% to 64%) | +53% | 59% (53% to 74%) | +60% |

The CPU a span compares each receiver with its twin at the highest rate both first rounds held,
since a span costs less CPU as the rate rises. On arm64 that rate was 569,600 spans a second for
connect-zig, 213,600 for connect-rust, and 53,400 for connect-go, and on x86-64 it was 854,400,
356,000, and 71,200. On x86-64, connect-zig's two rates overlap over the rounds, so the rounds
cannot tell its rate with validation from its rate without.

At the peak on x86-64, with one export sent again and again, validation costs connect-zig 1.8 µs a
call of 16 spans and 60.0 µs a call of 512 spans: 0.11 to 0.12 µs a span. It costs connect-rust 1.5
and 35.0 µs, 0.07 to 0.09 µs a span, and connect-go 61.8 and 1,840 µs, 3.6 to 3.9 µs a span.

connect-zig decodes each export into storage that its route owns, 1 MiB a call in the sink
(decision 37). A list that does not fit is parsed again by each read, and validation reads every
list. With 256 KiB, a 512-span export did not fit, and protovalidate cost the sink 0.96 µs a span;
with 1 MiB it costs 0.16 µs (`zig build otlp-validate-cost`). So a route's storage now defaults to
4 times its `message_bytes`, and a context field `messages_past_storage` counts the requests that
did not fit. The check fails when the sink counts one.

### With compression

From the same run, on an Arm Neoverse-N2 core over TLS. connect-zig, connect-go, and connect-rust
each take the production model's exports uncompressed and in gzip, zstd, and brotli. Over TLS, one
core of connect-zig holds 7% more spans a second in gzip than uncompressed, 10% more in zstd, and 8%
fewer in brotli. connect-go holds 18% to 24% fewer, and connect-rust 9% to 21% fewer.

![Bars of the spans a second each Connect receiver holds over TLS with exports in gzip, zstd, and brotli, as a share of the same receiver with uncompressed exports in the same round, and of its calls a second at peak, on arm64: connect-zig holds 107%, 110%, and 92%, connect-go 76%, 82%, and 78%, and connect-rust 86%, 91%, and 79%](images/fullstack-compression-arm64.svg)

`tools/fullstack/compression.sh` runs the climb and the peak of the production model on the three
Connect receivers, in three rounds of each coding. Each round gives each receiver its codings in
an order of its own, and a coding's share compares it with the receiver uncompressed in the same
round. stdx's encoders write each export as a connect-zig client does: gzip at stdx's default
level, and zstd and brotli at level 1. Each receiver decodes with its library's own decoders, at
their defaults: connect-zig with stdx's, connect-go with compress/gzip, klauspost/compress, and
andybalholm/brotli, and connect-rust with flate2, zstd, and brotli. Every span is checked. The
octets of each class's first export:

| Export | Uncompressed | gzip | zstd | brotli |
| --- | ---: | ---: | ---: | ---: |
| 16 spans | 7,984 | 2,454 (3.3×) | 2,527 (3.2×) | 2,500 (3.2×) |
| 128 spans | 61,353 | 9,332 (6.6×) | 9,646 (6.4×) | 9,228 (6.6×) |
| 512 spans | 233,192 | 30,976 (7.5×) | 31,101 (7.5×) | 29,933 (7.8×) |

Each bar is a receiver's rate as a share of the same receiver's rate with uncompressed exports. So
a bar shows what a coding costs one library, and the bars of two libraries do not compare: the
charts above compare the libraries. A coding costs the time of its decoder. It also saves the work
on the octets it removes, in the kernel, in TLS, and in HTTP/2, and each share holds both.

The compression parts run `otlp-sink-compression`, connect-zig's sink with room for 256 calls at
once, where the other parts' sink holds 64. An uncompressed export holds its call longer while its
octets arrive.

The rate kept against uncompressed, the median of the rounds, on arm64 over TLS and on x86-64 over
TLS and in cleartext h2:

| Receiver | Coding | arm64, TLS | x86-64, TLS | x86-64, cleartext |
| --- | --- | ---: | ---: | ---: |
| connect-zig | gzip | 107% | 105% | 93% |
| connect-zig | zstd | 110% | 110% | 100% |
| connect-zig | brotli | 92% | 87% | 79% |
| connect-go | gzip | 76% | 77% | 76% |
| connect-go | zstd | 82% | 85% | 81% |
| connect-go | brotli | 78% | 79% | 76% |
| connect-rust | gzip | 86% | 79% | 70% |
| connect-rust | zstd | 91% | 98% | 89% |
| connect-rust | brotli | 79% | 83% | 72% |

The CPU a span, at the highest rate that a receiver's first rounds all held, against
uncompressed:

| Receiver | Coding | arm64, TLS | x86-64, TLS | x86-64, cleartext |
| --- | --- | ---: | ---: | ---: |
| connect-zig | gzip | -5% | -2% | +9% |
| connect-zig | zstd | -5% | -6% | +7% |
| connect-zig | brotli | +13% | +13% | +25% |
| connect-go | gzip | +22% | +18% | +22% |
| connect-go | zstd | +16% | +8% | +17% |
| connect-go | brotli | +21% | +15% | +24% |
| connect-rust | gzip | +4% | +13% | +30% |
| connect-rust | zstd | +5% | +1% | +16% |
| connect-rust | brotli | +13% | +9% | +24% |

Over TLS, a span of a gzip or a zstd export costs connect-zig 2% to 6% less CPU than an
uncompressed one. The saving lies in the kernel, not in the sink's own code. Measured on one Intel
Xeon core at 2.10 GHz under Linux 6.18, outside CI, one call of the 512-span export took these
times of CPU, over three rounds of 2,000 calls through h2load on 4 connections:

| Export | Sink's own code | Kernel | Total |
| --- | ---: | ---: | ---: |
| Uncompressed, 233,192 octets | 665–685 µs | 70–80 µs | about 755 µs |
| gzip, 30,927 octets | 640–670 µs | 15–20 µs | about 675 µs |

The kernel moves 7.5 times fewer octets through the socket, so its share falls fourfold. In the
sink's own code, gzip costs what it saves. Under callgrind, 40 such calls took 249.3 million
instructions uncompressed and 250.9 million in gzip, on a sink built for x86-64-v3 with PCLMULQDQ
and AES-NI:

- Decompression adds 31.7 million: 27.0 million to inflate and 4.7 million for the CRC-32.
- The smaller export removes 30.2 million: decryption falls from 24.9 to 3.3 million, HTTP/2 and
  the router from 5.4 to 1.8 million, and copies from 6.4 to 3.4 million.
- The protobuf decode takes 196.1 million in both. The sink decodes and checks every octet of each
  export, whether it came compressed or not.

In cleartext there is no decryption to save, which was most of what the sink's own code saved, and
gzip and zstd cost it 7% to 9% more. Brotli costs it 13% to 25% more. Each coding costs connect-go
8% to 24% more CPU a span, and connect-rust 1% to 30% more: for them a decoder costs more than the
work a smaller export saves.

Read the charts with three limits:

- The x86-64 compression jobs ran on AMD EPYC 7763 cores, where the other x86-64 jobs of the run
  ran on other models. Compare a share only with the shares of its own table.
- No OpenTelemetry exporter sends brotli.
- connect-rust's zstd climbs and its uncompressed climbs overlap over the rounds on both machines,
  as do connect-zig's zstd and uncompressed climbs in cleartext: the rounds cannot tell those two
  rates apart.

At the peak, with one export sent again and again, an export of 16 spans costs each receiver more
in every coding: connect-zig answers 77% to 89% of its uncompressed calls a second over TLS on
arm64. An export of 512 spans saves connect-zig more than it costs over TLS: it answers 118% in
gzip and 120% in zstd on arm64. The run's summary holds every table.

## Validation

One decode of a request message and one validation of it against the rules of
its schema, beside protovalidate-go, protovalidate-es on Node.js, protovalidate-buffa, and
prost-protovalidate. From CI's [run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610), on an Arm Neoverse-N2 core: connect-zig is 15 to 65
times as fast as protovalidate-go, and the fastest of the five in all six cases. On an AMD EPYC
9V74 core it is 13 to 57 times as fast, and the fastest in all six too.

![Bars of the speed of a decode with a validation through connect-zig, protovalidate-buffa, prost-protovalidate, and protovalidate-es, in multiples of protovalidate-go's, on arm64: connect-zig is 15 to 65 times as fast as protovalidate-go and the fastest in 6 of 6 cases](images/validate-vs-go-arm64.svg)

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
typical request of an API: two CEL rules of the message, and a standard rule of each kind. Its
standard rules cover `uuid`, `email`, `uri`, `hostname`, `ip`, a repeated field with `unique`, a
map, a required message, bytes, and a duration. `Rules` holds CEL rules alone, over lists, a map,
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
