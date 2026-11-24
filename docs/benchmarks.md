# Benchmarks

How connect-zig's published numbers are measured, with the charts and tables behind them. Each
number comes from one named CI run, as [performance.md](performance.md) asks. A time compares only
with times of the same job on the same machine. Each run's summary holds every table.

## The codec

CI's [run 265](https://github.com/c4milo/connect-zig/actions/runs/45231244610), commit `a69e377`,
Ubuntu 26.04, on an Arm Neoverse-N2 core.

![Bars of the speed of connect-zig and of Buffa, connect-rust's codec, in multiples of Go's protobuf runtime, connect-go's codec, on arm64: connect-zig is 3.2 to 18.9 times faster than Go's protobuf runtime, and 1.1 to 2.2 times faster than Buffa](images/speed-vs-go-arm64.svg)

`zig build bench` times binary and JSON encoding and decoding of eight messages.
`tools/bench_check.sh` runs the same inputs through Go's `google.golang.org/protobuf` v1.36.12 and
Buffa, and checks that each writes the same bytes. It runs three rounds in a rotated order, and
each cell is the median round. A bar is a speed in multiples of Go's, so a longer bar is faster.

Each decode the chart draws reads every field. Go and Buffa build the whole message, while
connect-zig parses a repeated field when it is read, so connect-zig reads with `decode_into`
(decision 37).

| Machine | Chart's 16 cells, vs Go | All 48 cells, vs Go | vs Buffa, cells won | Buffa wins |
| --- | ---: | ---: | ---: | ---: |
| arm64, Neoverse-N2 | 3.2–18.9× | 2.3–40.2× | 43, up to 3.83× | 4, up to 1.47× |
| x86-64, Xeon Platinum 8573C | 4.5–21.7× | 2.2–36.9× | 45, up to 3.35× | 3, up to 1.22× |

Buffa wins no cell the chart draws. Its wins are JSON cells and, on arm64, varints binary decode.
On arm64 one more cell, varints JSON decode, is a tie within 0.3%.

## Request routing

Run 265, on an Arm Neoverse-N2 core, with colibri v0.19.2.

![Bars of the speed of a routed unary call through connect-zig and connect-rust, in multiples of connect-go's, on arm64: connect-zig is 9.6 to 12.4 times as fast as connect-go, and 3.3 to 5.6 times as fast as connect-rust](images/call-vs-go-arm64.svg)

`bench/call.zig` runs one unary call in memory through each library's router, route, protocol,
and codec, with no socket, TLS, or HTTP/2 framing. Each program builds its request once and times
the calls alone. connect-go's router is an `http.ServeMux`.

| Machine | vs connect-go | vs connect-rust |
| --- | ---: | ---: |
| arm64 | 9.6–12.4× | 3.3–5.6× |
| x86-64 | 9.4–11.6× | 2.9–5.0× |

The small message's call also runs in tables of 16 and 256 routes. colibri searches each path
segment, so connect-zig's call grows with the table: from 4,237 to 4,460 instructions on CI's
judge. The time of the small Connect call, in nanoseconds:

| Router | 1 route | 16 routes | 256 routes |
| --- | ---: | ---: | ---: |
| connect-zig, arm64 | 337 | 351 | 391 |
| connect-rust, arm64 | 1,766 | 1,767 | 1,788 |
| connect-go, arm64 | 3,221 | 3,209 | 3,261 |
| connect-zig, x86-64 | 314 | 320 | 348 |
| connect-rust, x86-64 | 1,505 | 1,533 | 1,522 |
| connect-go, x86-64 | 2,938 | 2,912 | 2,925 |

## OpenTelemetry trace ingestion

CI's [run 266](https://github.com/c4milo/connect-zig/actions/runs/45246119951), on an Arm
Neoverse-N2 core. An OTLP receiver on one core, over TLS and h2, takes the traffic of one gateway
core for 33,000 servers.

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, the median of three rounds with their range, and lines of p99 as the rate climbs, on arm64: connect-zig holds 711,570 spans a second, 7.0 times connect-go's 101,213, 2.7 times connect-rust's 263,440, 3.3 times the OpenTelemetry Collector's 215,818, and 8.6 times Vector's 82,310](images/fullstack-arm64.svg)

<details>
<summary>On x86-64, connect-zig holds 6.2 times connect-go's spans a second, 2.1 times connect-rust's, 3.0 times the Collector's, and 7.5 times Vector's.</summary>

![Bars of the spans a second one core holds with p99 under 100 ms over TLS, the median of three rounds with their range, and lines of p99 as the rate climbs, on x86-64: connect-zig holds 990,541 spans a second, 6.2 times connect-go's 160,510, 2.1 times connect-rust's 476,179, 3.0 times the OpenTelemetry Collector's 327,675, and 7.5 times Vector's 132,786](images/fullstack.svg)

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

The spans a second each core holds over TLS, the median of three rounds, with the range:

| Server | arm64 | arm64 range | x86-64 | x86-64 range |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 711,570 | 711,570–729,800 | 990,541 | 943,400–1,037,747 |
| connect-rust | 263,440 | 263,440–284,800 | 476,179 | 464,264–476,179 |
| Collector | 215,818 | 215,818–215,818 | 327,675 | 304,818–335,312 |
| connect-go | 101,213 | 98,715–101,213 | 160,510 | 144,053–164,672 |
| Vector | 82,310 | 80,261–82,310 | 132,786 | 86,782–137,462 |

The highest rate each server held with p99 at or under 10 ms, in spans a second, from the first
round:

| Server | arm64 | x86-64 |
| --- | ---: | ---: |
| connect-zig | 569,600 | 569,600 |
| connect-rust | 284,800 | 284,800 |
| Collector | 71,200 | 142,400 |
| connect-go | 53,400 | 71,200 |
| Vector | 71,200 | 71,200 |

The CPU time a span at each server's median rate, and its peak memory. A span costs less CPU at a
higher rate, so this table favours the faster server:

| Server | arm64, µs | x86-64, µs | arm64, MiB | x86-64, MiB |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 1.41 | 1.01 | 321 | 322 |
| connect-rust | 3.81 | 2.08 | 54 | 52 |
| Collector | 4.64 | 2.95 | 484 | 482 |
| connect-go | 9.83 | 5.69 | 190 | 192 |
| Vector | 12.16 | 6.32 | 1,484 | 1,479 |

In this run connect-zig took all its memory at start. Since [decision 48](decisions.md) it starts
in 6 MiB and grows as it writes pages.

In cleartext h2 on x86-64 (`fullstack-cleartext`), connect-zig held 820,142 spans a second, 4.14
times the Collector's 198,018 and 3.41 times Rotel's 240,307.

`fullstack-peak` loads each server over TLS as fast as it answers, on x86-64, with uncompressed
exports on 16 connections of 4 streams. The calls a second, the median of three rounds, on an
Intel Xeon 6975P-C core:

| Server | 16 spans | 512 spans | Peak MiB |
| --- | ---: | ---: | ---: |
| connect-zig | 60,294 | 2,104 | 322 |
| connect-zig, generic CPU | 56,558 | 1,974 | 322 |
| connect-rust | 34,493 | 1,731 | 18 |
| Collector | 21,410 | 1,117 | 160 |
| Vector | 10,050 | 357 | 306 |
| connect-go | 8,132 | 529 | 53 |
| connect-go, 320 MiB | 9,765 | 647 | 315 |

"connect-go, 320 MiB" runs with `GOGC=off` and `GOMEMLIMIT=320MiB`, about connect-zig's memory.

The limits of these numbers:

- Every server and the load run on one machine, over its loopback device.
- An x86-64 runner's CPU model changes from job to job. Compare a number only with the numbers of
  its own table.
- On x86-64 the server's CPU shares its physical core with the CPU that runs the scripts.
- A rate held lasts 10 s. In a 60 s step at its median rate, the Collector and Vector failed on
  arm64, and Vector and connect-rust with protovalidate-buffa failed on x86-64.
- connect-zig's sink holds 64 calls at once and answers 503 past them. More connections or exports
  over 256 KiB need larger limits.
- Vector and Rotel do not set `TCP_NODELAY`, so their p99 stays near 40 ms at low rates. The climb
  runs them as they ship.

### Validating every span

Run 266, on an Arm Neoverse-N2 core over TLS. Each Connect receiver runs again and checks every
span against OTLP's span rules, in `tools/fullstack/validate`, two of them CEL.

![Bars of the spans a second one core holds over TLS with p99 under 100 ms, for each Connect receiver without and with protovalidate, the median of three rounds, and lines of p99 as the rate climbs, on arm64: connect-zig keeps 87% of its rate with protovalidate, 618,528 spans a second, connect-rust with protovalidate-buffa 94%, 246,982, and connect-go with protovalidate-go 62%, 62,858](images/fullstack-validate-arm64.svg)

connect-zig uses `protovalidate.Interceptor` (`zig build otlp-sink-validate`), connect-go
[protovalidate-go](https://github.com/bufbuild/protovalidate-go) v1.4.1, and connect-rust
[protovalidate-buffa](https://github.com/mathematic-inc/protovalidate-buffa) 0.8.0. Before each
climb, the check sends an export that breaks a rule, and fails when a validating receiver takes it.

The rate each core keeps, the median with the range of the rounds, and the CPU a span validation
adds at the highest rate both first rounds held:

| Receiver | arm64, rate kept | arm64, CPU a span | x86-64, rate kept | x86-64, CPU a span |
| --- | ---: | ---: | ---: | ---: |
| connect-zig | 87% (85% to 87%) | +12% | 91% (87% to 93%) | +4% |
| connect-rust | 94% (87% to 94%) | +9% | 94% (89% to 96%) | +6% |
| connect-go | 62% (62% to 64%) | +53% | 59% (53% to 74%) | +60% |

At the peak on x86-64, validation costs connect-zig 0.11 to 0.12 µs a span, connect-rust 0.07 to
0.09 µs, and connect-go 3.6 to 3.9 µs.

### With compression

Run 266, on an Arm Neoverse-N2 core over TLS. The three Connect receivers take the production
model's exports uncompressed and in gzip, zstd, and brotli.

![Bars of the spans a second each Connect receiver holds over TLS with exports in gzip, zstd, and brotli, as a share of the same receiver with uncompressed exports in the same round, and of its calls a second at peak, on arm64: connect-zig holds 107%, 110%, and 92%, connect-go 76%, 82%, and 78%, and connect-rust 86%, 91%, and 79%](images/fullstack-compression-arm64.svg)

`tools/fullstack/compression.sh` runs three rounds of each coding. stdx writes gzip at its default
level, and zstd and brotli at level 1. Each receiver decodes with its library's own decoders. A
bar is a share of the same receiver uncompressed in the same round, so bars of two libraries do
not compare. The octets of each class's first export:

| Export | Uncompressed | gzip | zstd | brotli |
| --- | ---: | ---: | ---: | ---: |
| 16 spans | 7,984 | 2,454 (3.3×) | 2,527 (3.2×) | 2,500 (3.2×) |
| 128 spans | 61,353 | 9,332 (6.6×) | 9,646 (6.4×) | 9,228 (6.6×) |
| 512 spans | 233,192 | 30,976 (7.5×) | 31,101 (7.5×) | 29,933 (7.8×) |

The rate kept against uncompressed, and the CPU a span against uncompressed, the median of the
rounds:

| Receiver | Coding | Rate, arm64 TLS | Rate, x86-64 TLS | Rate, x86-64 cleartext | CPU, arm64 TLS | CPU, x86-64 TLS | CPU, x86-64 cleartext |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| connect-zig | gzip | 107% | 105% | 93% | -5% | -2% | +9% |
| connect-zig | zstd | 110% | 110% | 100% | -5% | -6% | +7% |
| connect-zig | brotli | 92% | 87% | 79% | +13% | +13% | +25% |
| connect-go | gzip | 76% | 77% | 76% | +22% | +18% | +22% |
| connect-go | zstd | 82% | 85% | 81% | +16% | +8% | +17% |
| connect-go | brotli | 78% | 79% | 76% | +21% | +15% | +24% |
| connect-rust | gzip | 86% | 79% | 70% | +4% | +13% | +30% |
| connect-rust | zstd | 91% | 98% | 89% | +5% | +1% | +16% |
| connect-rust | brotli | 79% | 83% | 72% | +13% | +9% | +24% |

Over TLS, gzip and zstd cost connect-zig less CPU than no coding. The decoder's cost about equals
what the smaller export saves in decryption, HTTP/2, and copies, and the kernel moves 7.5 times
fewer octets. In cleartext there is no decryption to save, so each coding costs more.

The limits of these numbers:

- The x86-64 compression jobs ran on AMD EPYC 7763 cores. Compare a share only within its table.
- No OpenTelemetry exporter sends brotli.
- connect-rust's zstd and uncompressed climbs overlap over the rounds, as do connect-zig's in
  cleartext.

## Validation

Run 265, on an Arm Neoverse-N2 core. One decode of a request message and one validation of it:
connect-zig is 15 to 65 times as fast as protovalidate-go, and the fastest of five in all six
cases. On an AMD EPYC 9V74 core it is 13 to 57 times as fast, and the fastest in all six too.

![Bars of the speed of a decode with a validation through connect-zig, protovalidate-buffa, prost-protovalidate, and protovalidate-es, in multiples of protovalidate-go's, on arm64: connect-zig is 15 to 65 times as fast as protovalidate-go and the fastest in 6 of 6 cases](images/validate-vs-go-arm64.svg)

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

The nanoseconds of one decode and one validation, which the chart draws, on arm64:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 40.4 | 803.2 | 1,272.1 | 105.5 | 892.8 |
| `Small`, invalid | 44.4 | 2,658.9 | 4,417.2 | 145.7 | 2,676.9 |
| `Medium`, valid | 543.8 | 8,008.0 | 41,656.8 | 869.6 | 32,386.1 |
| `Medium`, invalid | 457.0 | 15,683.5 | 53,551.2 | 1,215.3 | 42,165.5 |
| `Rules`, valid | 163.7 | 10,539.2 | 23,272.4 | 283.0 | 21,555.7 |
| `Rules`, invalid | 174.9 | 11,419.3 | 24,849.2 | 395.6 | 19,970.5 |

The same on x86-64:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 49.9 | 835.3 | 1,393.3 | 141.3 | 883.4 |
| `Small`, invalid | 64.8 | 2,704.8 | 5,171.3 | 156.9 | 2,899.2 |
| `Medium`, valid | 624.8 | 8,398.6 | 43,887.6 | 1,165.0 | 37,535.5 |
| `Medium`, invalid | 535.6 | 15,580.9 | 45,959.9 | 1,423.4 | 49,045.6 |
| `Rules`, valid | 210.0 | 10,967.5 | 26,706.5 | 354.0 | 25,703.2 |
| `Rules`, invalid | 207.0 | 11,770.3 | 27,607.3 | 450.3 | 23,695.8 |

The nanoseconds of one validation of a message decoded before, on arm64:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 18.2 | 508.9 | 692.1 | 45.3 | 816.3 |
| `Small`, invalid | 23.2 | 2,410.1 | 4,092.9 | 103.2 | 2,504.4 |
| `Medium`, valid | 323.0 | 5,490.4 | 34,641.7 | 357.4 | 31,029.0 |
| `Medium`, invalid | 284.2 | 13,410.1 | 43,027.5 | 744.4 | 40,356.2 |
| `Rules`, valid | 38.8 | 8,750.7 | 22,090.7 | 41.1 | 20,865.3 |
| `Rules`, invalid | 66.4 | 9,870.5 | 22,944.9 | 164.4 | 19,461.3 |

The same on x86-64:

| Message | connect-zig | protovalidate-go | protovalidate-es | protovalidate-buffa | prost-protovalidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Small`, valid | 23.3 | 541.5 | 569.8 | 51.4 | 782.3 |
| `Small`, invalid | 26.3 | 2,429.9 | 4,298.6 | 102.3 | 2,658.2 |
| `Medium`, valid | 407.9 | 5,768.5 | 48,798.8 | 366.2 | 35,453.1 |
| `Medium`, invalid | 379.4 | 13,220.4 | 43,751.1 | 764.4 | 46,062.0 |
| `Rules`, valid | 51.2 | 9,073.6 | 25,761.3 | 37.0 | 24,226.3 |
| `Rules`, invalid | 72.7 | 10,356.4 | 25,293.8 | 163.1 | 23,084.8 |

On x86-64, protovalidate-buffa validates the valid `Rules` and the valid `Medium` faster than
connect-zig when the message is already decoded. With the decode, connect-zig is faster in all six
cases on both machines.
