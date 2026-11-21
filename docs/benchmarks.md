# Benchmarks

How connect-zig's published numbers are measured, and every table behind the README's charts.
Each number comes from one named CI run, as [performance.md](performance.md) asks, and each
time compares only within one job on one machine.

## The codec

`zig build bench` times binary and JSON encoding and decoding of eight messages, then a routed unary
call. `tools/bench_check.sh` runs the same inputs through Go's `google.golang.org/protobuf`
v1.36.12, connect-go's codec, and Buffa, connect-rust's codec. It checks that each writes the same
bytes as connect-zig. The numbers below come from CI's two `bench-compare` jobs of commit `fa83b86`
([run 191](https://github.com/c4milo/connect-zig/actions/runs/44673102412)), on Ubuntu 26.04. One
ran on an AMD EPYC 9V74 core (x86-64) and one on an Arm Neoverse-N2 core (arm64), each with the
three programs in one job. Both jobs ran a second time: in the first attempt, some of connect-zig's
cells on arm64 took twice their time, with the same CPU and code, and the second attempt matched the
lab run on 26.04 (decision 44). The run's summary holds every table.

Each chart of the README draws the speed of connect-zig and of Buffa in multiples of Go's. A
longer bar is faster, and Go is the line at 1. The charts time the codecs alone, with no code of
connect-go or connect-rust. A binary decode with every field read takes `decode_into`, which
reads each repeated field once (decision 37).

The README's charts draw 16 of the table's 48 cells. On arm64, Buffa is faster in none of them.
On x86-64 it is faster in 1: the medium message's binary encode, by 1.45 times.

In the table's 48 cells, connect-zig is 2.3 to 38.5 times faster than Go on arm64, and 1.4 to
32.5 times on x86-64. Against Buffa, connect-zig is faster in 44 of the 48 cells on arm64 and in
42 on x86-64, by up to 3.79 and 3.72 times. Buffa is faster in the other 4 and 6. Its widest
wins are tree JSON encode, by 1.52 times on arm64 and 1.54 times on x86-64, and on x86-64 the
packed message's binary encode, by 1.82 times, the medium message's binary encode, by 1.45
times, and tree JSON decode with every field read, by 1.35 times. Its other wins are by 1.15
times or less.

## The routed call

The routed calls (`bench/call.zig`) run the same unary call in memory through connect-zig,
connect-go and connect-rust: the router, the route, the protocol and the codec, with no socket, no
TLS and no HTTP/2 framing. connect-go's router is an `http.ServeMux`, as a server's is. CI's two
`bench-compare` jobs of commit `fa83b86` ([run
191](https://github.com/c4milo/connect-zig/actions/runs/44673102412), second attempt) timed them on
colibri v0.19.0 and Ubuntu 26.04, on an AMD EPYC 9V74 core and on an Arm Neoverse-N2 core. The
README's charts draw a speed in multiples of connect-go's, and connect-zig's bar also gives its time
for one call, in a table of one route.

The small message's call also runs in tables of 16 and 256 routes: 4 and 16 services of as many
methods, with the call's route among them. colibri finds a route by a binary search over each path
segment, 8 octets at a time since colibri v0.19.0, connect-rust by a hash map of the path, and
Go's `ServeMux` by a tree of maps. So connect-zig's call grows with the table, where the other two
stay within 3%. On CI's judge it takes 4,177 instructions with one route and 4,430 with 256, 6%
more. In time it grew 14% on arm64 and 23% on x86-64 in this run. The time of the small Connect
call, in nanoseconds:

| Router | 1 route | 16 routes | 256 routes |
| --- | ---: | ---: | ---: |
| connect-zig, arm64 | 330 | 364 | 375 |
| connect-rust, arm64 | 1,889 | 1,879 | 1,902 |
| connect-go, arm64 | 7,410 | 7,409 | 7,441 |
| connect-zig, x86-64 | 307 | 318 | 378 |
| connect-rust, x86-64 | 1,530 | 1,505 | 1,554 |
| connect-go, x86-64 | 5,285 | 5,322 | 5,335 |

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

The production model stands for one core of a 64-core gateway that 33,000 servers send their traces
to. Each server holds 516 connections. 70%, 25% and 5% of them send gzip exports of 16, 128 and 512
spans. [oha](https://github.com/hatoo/oha) sends at fixed rates, and its latency holds the time a
call waits in a queue. The rate climbs until p99 passes 100 ms or a call is refused. Then three more
steps halve the gap to the last step that passed, so each rate is known within 1/16 of it. CI's two
`fullstack` jobs of commit `fa83b86` ([run
191](https://github.com/c4milo/connect-zig/actions/runs/44673102412)) ran it on colibri v0.19.0 and
Ubuntu 26.04, on an Arm Neoverse-N2 core and on an AMD EPYC 9V74 core. The README charts the climb
over TLS 1.3: one core of connect-zig held 8.0 times connect-go's spans a second on arm64 and 5.6
times on x86-64, 2.7 and 2.2 times connect-rust's, 3.5 and 2.7 times the Collector's, and 10.7 and
10.4 times Vector's.

Rotel has no TLS on its receiver, so a second climb runs in cleartext h2 for connect-zig, the
Collector and Rotel. There one core of connect-zig holds 3.6 times Rotel's spans a second on
arm64 and 2.8 times on x86-64, and 4.3 and 3.8 times the Collector's.

The CPU time a span, at each server's highest step, in µs:

| Server | arm64, TLS | x86-64, TLS | arm64, cleartext | x86-64, cleartext |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 1.40 | 1.40 | 1.32 | 1.20 |
| connect-rust | 3.72 | 3.05 | | |
| connect-go | 9.88 | 7.24 | | |
| Collector | 4.73 | 3.72 | 5.62 | 4.50 |
| Vector | 13.31 | 10.60 | | |
| Rotel | | | 4.71 | 3.27 |

connect-zig takes all its memory when it starts: 378 MiB, for 528 connections and 64 calls at once,
where colibri v0.18.1 took 483 MiB. Over TLS on arm64, connect-rust grew to 56 MiB, connect-go to
139 MiB, the Collector to 696 MiB and Vector to 781 MiB; in cleartext, Rotel grew to 326 MiB.
connect-zig's climb ends when a burst fills its 64 calls and a call is refused. The other servers'
climbs end when a call waits past 100 ms. A runner's CPU model changes from run to run on x86-64, so
its rates move between runs; the arm64 runner has been a Neoverse-N2 in each run.

Vector's and Rotel's p99 stays near 40 ms from a low rate. Neither sets `TCP_NODELAY` on the
sockets it accepts, so Nagle's algorithm waits for Linux's delayed ACK. With `TCP_NODELAY` set
from outside, their p99 fell to about 5 ms, but neither held a higher rate. So the climb runs them
as they ship. connect-rust's server sets it.

The same jobs also load each server over TLS as fast as it answers, with exports of 16 and of 512
spans, not compressed, on 16 connections of 4 streams. The calls a second:

| Server | 16 spans, arm64 | 512 spans, arm64 | 16 spans, x86-64 | 512 spans, x86-64 |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 41,836 | 1,511 | 48,871 | 1,800 |
| connect-rust | 16,714 | 1,059 | 21,075 | 1,090 |
| connect-go | 5,333 | 368 | 7,067 | 519 |
| Collector | 12,958 | 728 | 17,759 | 965 |
| Vector | 4,250 | 243 | 8,264 | 304 |

## Validation

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
`buf convert` encodes them. The schema holds no `pattern`, which connect-zig does not read yet.

Each program keeps one validator for every call, as a server does, and times as
bench/measure.zig does: the median of 11 batches of about 20 ms. It times two things for each
message:

- the decode of its octets and one validation of what the decode gives, which a server runs for
  each request, and which the chart draws;
- one validation of the message decoded before, which the second table holds.

The first is the one to compare. connect-zig's message reads a repeated field and a map from the
octets as validation runs, where the other implementations' decode built a list and a map
before it. So connect-zig's validation alone includes work that the others count in their
decode. protovalidate-es reads the schema's descriptors from a FileDescriptorSet, as code that
protoc-gen-es writes builds them from an embedded descriptor.

Each verdict is "valid", or "invalid:" and the rule ids of the violations in order. The check
fails when two implementations give one message different verdicts.
