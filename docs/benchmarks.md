# Benchmarks

How connect-zig's published numbers are measured, and every table behind the README's charts.
Each number comes from one named CI run, as [performance.md](performance.md) asks, and each
time compares only within one job on one machine.

## The codec

`zig build bench` times binary and JSON encoding and decoding of eight messages, then a routed
unary call. `tools/bench_check.sh` runs the same inputs through Go's `google.golang.org/protobuf`
v1.36.12, connect-go's codec, and Buffa, connect-rust's codec. It checks that each writes the
same bytes as connect-zig. The numbers below come from CI's two `bench-compare` jobs of
commit `af0b01e` ([run 185](https://github.com/c4milo/connect-zig/actions/runs/44627403358)). One
ran on an Intel Xeon 6975P-C core (x86-64) and one on an Arm Neoverse-N2 core (arm64), each with
the three programs in one job. The run's summary holds every table.

Each chart of the README draws the speed of connect-zig and of Buffa in multiples of Go's. A
longer bar is faster, and Go is the line at 1. The charts time the codecs alone, with no code of
connect-go or connect-rust. A binary decode with every field read takes `decode_into`, which
reads each repeated field once (decision 37).

The README's charts draw 16 of the table's 48 cells. On arm64, Buffa is faster in none of them.
On x86-64 it is faster in 2: the medium message's binary decode with every field read, by 1.25
times, and the deep message's binary encode, by 1%.

In the table's 48 cells, connect-zig is 2.2 to 41.4 times faster than Go on arm64, and 2.1 to
31.7 times on x86-64. Against Buffa, connect-zig is faster in 43 of the 48 cells on arm64 and in
40 on x86-64, by up to 4.05 and 3.44 times. Buffa is faster in the other 5 and 8. Its widest win
is tree JSON encode on arm64, by 1.49 times. On x86-64 its widest are packed JSON decode with
every field read, by 1.27 times, the medium message's binary decode with every field read, by
1.25 times, and tree JSON decode with every field read, by 1.23 times. Its other wins are by 1.15
times or less.

## The routed call

The routed calls (`bench/call.zig`) run the same unary call in memory through connect-zig,
connect-go and connect-rust: the router, the route, the protocol and the codec, with no socket,
no TLS and no HTTP/2 framing. connect-go's router is an `http.ServeMux`, as a server's is. CI's
two `bench-compare` jobs of commit `af0b01e`
([run 185](https://github.com/c4milo/connect-zig/actions/runs/44627403358)) timed them on colibri
v0.19.0, on an Intel Xeon 6975P-C core and on an Arm Neoverse-N2 core. The README's charts draw a
speed in multiples of connect-go's, and connect-zig's bar also gives its time for one call, in a
table of one route.

The small message's call also runs in tables of 16 and 256 routes: 4 and 16 services of as many
methods, with the call's route among them. colibri finds a route by a binary search over each path
segment, 8 octets at a time since colibri v0.19.0, connect-rust by a hash map of the path, and
Go's `ServeMux` by a tree of maps. So connect-zig's call grows with the table, where the other two
stay within 3%. On CI's judge it takes 4,177 instructions with one route and 4,430 with 256, 6%
more. In time it grew 9% on x86-64 and 13% on arm64 in this run. The time of the small Connect
call, in nanoseconds:

| Router | 1 route | 16 routes | 256 routes |
| --- | ---: | ---: | ---: |
| connect-zig, arm64 | 333 | 365 | 378 |
| connect-rust, arm64 | 2,138 | 2,083 | 2,085 |
| connect-go, arm64 | 7,699 | 7,699 | 7,828 |
| connect-zig, x86-64 | 241 | 239 | 264 |
| connect-rust, x86-64 | 1,328 | 1,306 | 1,290 |
| connect-go, x86-64 | 5,716 | 5,721 | 5,641 |

## Whole servers on a socket

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

The production model stands for one core of a 64-core gateway that 33,000 servers send their
traces to. Each server holds 516 connections. 70%, 25% and 5% of them send gzip exports of 16, 128
and 512 spans. [oha](https://github.com/hatoo/oha) sends at fixed rates, and its latency holds the
time a call waits in a queue. The rate climbs until p99 passes 100 ms or a call is refused.
Then three more steps halve the gap to the last step that passed, so each rate is known within
1/16 of it. CI's two `fullstack` jobs of commit `af0b01e`
([run 185](https://github.com/c4milo/connect-zig/actions/runs/44627403358)) ran it on colibri
v0.19.0, on an Arm Neoverse-N2 core and on an AMD EPYC 7763 core. The README charts the climb
over TLS 1.3: one core of connect-zig held 7.1 times connect-go's spans a second on arm64 and 6.8
times on x86-64, 2.6 and 2.3 times connect-rust's, 3.4 and 3.4 times the Collector's, and 10.4
and 10.5 times Vector's.

Rotel has no TLS on its receiver, so a second climb runs in cleartext h2 for connect-zig, the
Collector and Rotel. There one core of connect-zig holds 3.6 times Rotel's spans a second on
arm64 and 2.6 times on x86-64, and 4.1 and 3.8 times the Collector's.

The CPU time a span, at each server's highest step, in µs:

| Server | arm64, TLS | x86-64, TLS | arm64, cleartext | x86-64, cleartext |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 1.44 | 1.64 | 1.31 | 1.56 |
| connect-rust | 3.69 | 3.86 | | |
| connect-go | 9.64 | 10.25 | | |
| Collector | 4.70 | 5.16 | 5.37 | 5.80 |
| Vector | 13.39 | 13.92 | | |
| Rotel | | | 4.70 | 4.00 |

connect-zig takes all its memory when it starts: 378 MiB, for 528 connections and 64 calls at
once, where colibri v0.18.1 took 483 MiB. Over TLS on arm64, connect-rust grew to 50 MiB,
connect-go to 125 MiB, the Collector to 689 MiB and Vector to 825 MiB; in cleartext, Rotel grew
to 324 MiB. connect-zig's climb ends when a
burst fills its 64 calls and a call is refused. The other servers' climbs end when a call waits
past 100 ms. A runner's CPU model changes from run to run on x86-64, so its rates move between
runs; the arm64 runner has been a Neoverse-N2 in each run.

Vector's and Rotel's p99 stays near 40 ms from a low rate. Neither sets `TCP_NODELAY` on the
sockets it accepts, so Nagle's algorithm waits for Linux's delayed ACK. With `TCP_NODELAY` set
from outside, their p99 fell to about 5 ms, but neither held a higher rate. So the climb runs them
as they ship. connect-rust's server sets it.

The same jobs also load each server over TLS as fast as it answers, with exports of 16 and of 512
spans, not compressed, on 16 connections of 4 streams. The calls a second:

| Server | 16 spans, arm64 | 512 spans, arm64 | 16 spans, x86-64 | 512 spans, x86-64 |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 41,947 | 1,497 | 37,630 | 1,403 |
| connect-rust | 15,766 | 1,061 | 14,286 | 953 |
| connect-go | 5,356 | 376 | 5,076 | 373 |
| Collector | 13,309 | 760 | 13,815 | 791 |
| Vector | 4,397 | 248 | 5,555 | 254 |
