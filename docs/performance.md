# Performance work in connect-zig

Every performance change follows pepegrillo's method in `docs/performance/`, starting at
`performance.md`. `zig build guide` installs it to `zig-out/docs/performance/`, at the commit
`build.zig.zon` pins. Read it first. This appendix holds what the method leaves to the project:
connect-zig's instruments, its admission rule, its baselines, its costs and the pitfalls it has
paid for.

## The instruments

- **The judge is the instruction count.** `tools/perf_check.sh` builds the benchmark for
  x86-64-v3 and counts each operation's instructions under callgrind. The count is for one run of
  the operation, averaged over 16 runs. It compares each count with `bench/instructions.txt`. The
  `perf` job of CI runs it on each push and pull request (decision 30). A count repeats exactly
  on one build, so a shared runner judges as a quiet machine would.
- **Time is a filter.** `zig build bench` times each operation in ReleaseFast.
  `tools/bench_check.sh` runs Go's `google.golang.org/protobuf` and Rust's Buffa on the same
  inputs beside it, and checks that each writes the same octets and the same walk sum as Zig. A
  time orders candidates and never lands in a document unless every program ran in the same job
  on the same machine. CI's `bench-compare` job runs it and adds the table to the job's summary;
  it fails only when the octets differ, never on a time. The README's table comes from one named
  run of that job.
- **The full stack is a time too.** `tools/fullstack_check.sh` loads whole servers over TLS and
  h2 on a socket: connect-zig's OTLP sink and OpenTelemetry's Collector, each on one core, with
  the load on two others (decision 44). Its peak part reports calls a second, latency, CPU time
  a call and peak memory under h2load. Its production part gives the span rate one gateway core
  holds for 33,000 servers, under oha at climbing rates, with p99 at most 100 ms. It fails only
  when a server answered an export wrongly or did not take every span. CI's `fullstack` job
  runs it on x86-64 and on arm64, and adds both tables to each job's summary.
- **The smoke run.** `zig build bench -- --quick` runs every operation on every message in a few
  short batches. CI's `bench` job runs it, so a broken operation fails before anyone times it.
- **A profile shows where the cost goes, and is never a measurement.** Run callgrind on
  `zig-out/bin/bench --instructions`, then read it with `callgrind_annotate`, by function and by
  line. A change takes its price from the counts, never from a profile.

## The units of work

The benchmark has eight messages in `bench/inputs.zig`. Four have the shapes services send:
Small (40 B), Medium (1 KB), Large (180 KB, with a 6 KB string) and Deep (50 nested levels). Four
hold one kind of field each, so their counts give the cost of that kind per field:

- Varints (90 B): each varint kind, at each length from 1 to 10 bytes.
- Strings (242 B): ASCII strings on each side of 8, 16 and 32 octets, and two short strings
  with Latin and CJK characters.
- Tree (684 B): 341 nodes that hold only their children, four to a node.
- Packed (975 B): 64 elements in each of four packed fields.

It runs six operations on each: binary encode, binary decode, binary decode with every field
read, and the same three in JSON. A binary decode alone takes `decode`, and a binary decode
with every field read takes `decode_into`, as a program that reads every field does (decision
37).
`bench/instructions.txt` holds the count of each pair. The benchmark builds stdx's modules in
ReleaseFast too, so no count includes a safety check.

Four more operations are routed calls (`bench/call.zig`): one unary call of the small and of the
medium message, in Connect and in gRPC, through `connect_colibri`'s route on colibri's
`server.Router`. The route takes the default options, as a program that names none does. The
program hands the router an engine's events: the request's head, its body with its end, and the
request's end. A stand-in engine takes each octet at once. So a count holds the router, the
route, the protocol and the codec, and no framing, TLS or socket. They are a program of their
own, `bench-call` (`bench/call_main.zig`), which `zig build bench` runs after the codec's and
`tools/perf_check.sh` counts beside it. The build makes `connect`, `connect_colibri` and colibri's
modules in ReleaseFast for it.

bench/go and bench/rust make the same calls in memory: connect-go's handler through `ServeHTTP`,
and connect-rust's `ConnectRpcService`, which encodes with Buffa, as a tower service. Each
handler answers the message with itself, and `tools/bench_check.sh` checks that each reply's
octets equal Zig's. Go builds a `net/http` request and Rust an `http::Request` for each call, so
the three do close to the same work, not the same work.

## The admission rule

- **A regression fails past 2%** of the baseline count for any operation. The margin covers what
  another build of the compiler may reorder.
- **A win lands with a new baseline.** `tools/perf_check.sh --write` writes the counts, and the
  commit that pays for the change explains it, with the operations that moved and by how much.
- **A claim of speed names its count.** A commit or a document that says a change is faster gives
  the instructions before and after, from the judge. A time from a laptop alone is not a claim.

## The baselines

- **Go's `google.golang.org/protobuf`**, at the version `bench/go/go.mod` pins, on the same
  inputs. It is the runtime most Connect services use. The comparison reads only its output and
  its time, never its source.
- **Rust's Buffa**, the protobuf runtime of connect-rust, at the version `bench/rust/Cargo.lock`
  pins, on the same inputs. `bench/rust` builds with link-time optimization and for the
  machine's CPU, as `zig build bench` does. A map field is a `BTreeMap`, so Buffa writes map
  entries in key order, as Go's deterministic marshaling does. Binary decoding builds Buffa's
  zero-copy view, whose strings point into the input, as connect-zig's do. JSON decoding builds
  the owned message, the only form Buffa's serde code decodes JSON to. The bench reads only its
  output and its time, never its source. `tools/bench_check.sh` runs it when `cargo` is on the
  path, and leaves its columns `absent` otherwise.
- **upb**, through Python's protobuf pinned in `tools/upb_requirements.txt`, checks closed enums
  and unchecked strings for correctness. It is not a speed baseline.

## The costs

The method prices a claim against the costs of a first-level cache hit, a main-memory read, a
branch mispredict, a copy and a system call, each measured on the judge. `zig build costs` times
them with `bench/costs.zig`, in ReleaseFast, and prints each median of five runs with its
spread. CI's `costs` job runs it through `tools/ci.sh --only costs` and adds the table to the
job's summary. It reports and never fails CI: a shared runner can time any row badly, and a row
below the floor a real measurement gives, such as a mispredict under 1 ns, is marked suspect and
raises a warning. The table below holds one CI run: the `costs` job of commit `dc3f24a`, on
GitHub's `ubuntu-24.04` runner, a Zen 4 core (`znver4`), in ReleaseFast. Each median is of five
runs. The mispredict's spread is wide, so a claim that turns on it measures it again.

| Cost | Median | Spread | Run |
| --- | ---: | ---: | --- |
| First-level cache hit, ns per load | 1.37 | 0.6% | [42546253012](https://github.com/c4milo/connect-zig/actions/runs/42546253012) |
| Main-memory read, ns per load | 152.73 | 0.8% | [42546253012](https://github.com/c4milo/connect-zig/actions/runs/42546253012) |
| Branch mispredict, ns | 3.18 | 16.4% | [42546253012](https://github.com/c4milo/connect-zig/actions/runs/42546253012) |
| Copy of 64 KiB, ns | 1148.59 | 0.6% | [42546253012](https://github.com/c4milo/connect-zig/actions/runs/42546253012) |
| System call (`getpid`), ns | 144.39 | 0.4% | [42546253012](https://github.com/c4milo/connect-zig/actions/runs/42546253012) |

## The fast paths the judge guards

A fast path that is switched off gives the same octets as its reference, so no test sees it: the
proof harness checks that the two agree, not that the fast one runs. The judge sees it. Each fast
path below was switched off on purpose once its baseline was written, and `tools/perf_check.sh`
failed (the owner's ruling of 2026-11-09). A new fast path joins this list the same way.

| Fast path | Where | What the judge reported when it was off |
| --- | --- | --- |
| A program's repeated items, without the iterator (binary and JSON) | `encode.zig`, `json_encode.zig` | failed; the commit of each names the operations |
| The child's length guess | `encode.zig` | failed; its commit names the operations |
| The ASCII word check | `scalar.zig` | failed; its commit names the operations |
| One- and two-octet varint write | `wire.zig`, `Writer.varint` | deep binary encode +67.89%, deep JSON decode +8.57% |
| One- and two-octet varint read | `wire.zig`, `Reader.varint` | deep binary decode +28.98%, deep binary decode+walk +28.65% |
| The packed element inline | `repeated.zig` | failed; its commit names the operations |
| A `Lazy` child through its pointer | `encode.zig` | failed; its commit names the operations |
| A JSON member name against comptime names | `json_decode.zig`, `name_is` | deep JSON decode +11.09%, large JSON decode +4.71% |
| A JSON integer of up to 19 decimal digits | `json_scalar.zig`, `parse_decimal` | packed JSON decode +8.66%, varints JSON decode +8.67%, medium JSON decode +7.10% |
| A JSON float equal to a short decimal | `json_float.zig`, `exact_text` | packed JSON encode +44.66%, small JSON encode +15.15%, large JSON encode +7.68% |
| A JSON float text read as one exact quotient | `json_float.zig`, `parse_exact` | packed JSON decode +4.63%, small JSON decode +2.47% |
| A flat child measured before it is written | `encode.zig`, `is_flat` | medium binary encode +7.35%, local x86-64-v2 |
| A field's stored items read in place | `repeated.zig`, `RepeatedIterator.next` | packed binary decode+walk +86.22%, large +26.59%, medium +22.66%, local x86-64-v2 |
| The binary writer's length in a register | `wire.zig`, `Writer.varint` and `varint_long` | varints binary encode +29.06%, packed +18.97%, small +14.54%, strings +10.74%, medium +7.84% |
| A packed record's varints read with a local position | `decode_run.zig`, `read_packed_varints` | packed binary decode+walk +18.69%, medium +9.92% |
| A varint of three or four octets written inline | `wire.zig`, `Writer.varint_wide` | medium binary encode +27.48%, varints +11.41%, large +5.03% |
| The end of a field's stored items with no call | `repeated.zig`, `RepeatedIterator.next` | packed binary decode+walk +25.50%, large +7.17%, medium +5.66% |
| Each `TextWriter` call inline in the JSON encoder | `json_encode.zig` and `json_scalar.zig` | deep JSON encode +30.03%, small +25.20%, varints +21.74%, tree +19.71%, strings +18.24% |
| A run of messages counted with no call | `decode_run.zig`, `run_count` | tree binary decode+walk +11.38%, large +3.32%, local x86-64-v2 |
| A message given in place by its iterator | `repeated.zig`, `next_message` | tree binary decode+walk +27.11%, large +4.09%, local x86-64-v2 |
| The transcoder's binary decoded one level | `protobuf.zig`, `decode_transcoded` | tree JSON decode +30.31%, deep +20.58%, large +16.20%, medium +8.94%, local x86-64-v2 |
| A JSON array of a packed field written as one record | `json_decode.zig`, `read_packed_array` | packed JSON decode+walk +38.06%, packed JSON decode +21.31%, medium JSON decode+walk +12.15%, large +11.14%, local x86-64-v2 |
| A `Lazy` child's object opened with its member's name | `json_encode.zig`, `write_lazy` | deep JSON encode +9.47%, local x86-64-v2 |
| A message with no member written as `{}` in one call | `json_encode.zig`, `writes_none` | tree JSON encode +36.33%, local x86-64-v2 |

## The pitfalls

| Symptom | Cause | Rule |
| --- | --- | --- |
| callgrind stops at an illegal instruction. | valgrind runs no AVX-512, and a native build uses it. | The judge builds for x86-64-v3 (`-Dcpu=x86_64_v3`). |
| The same tree timed 2x apart on two CI runs. | Shared runners share cores and caches. | Gate on instructions; compare times only within one job (decision 30). |
| A short string decoded slower with stdx's vector UTF-8 check. | The vector loop's setup costs more than a short scalar walk. | The vector check starts at `constants.limits.utf8_vector_len_min`, 32 octets. |
| A long JSON string failed to decode in the benchmark. | The JSON token buffer was shorter than the string. | The benchmark's token buffer holds 16 KB; size it from the longest token a caller expects. |
| Large binary decode took 5.4% more instructions when the benchmark gained four messages. | More instances of the generic decoder made LLVM call `decode.read_repeated` instead of inlining it. | A new benchmark message writes a new baseline in its own commit, before any change it measures. |
| Small binary encode took 21% more instructions once `Writer.varint` was inlined whole. | The inlined loop made its callers too large for LLVM to inline in turn. | A fast path inlines its common case alone; the rest is a `noinline` function. |
| tree binary decode+walk took 4.4% more instructions when the iterator's items check moved inline. | The out-of-line rest takes the iterator's address, so each inline check reloads its fields. | One inline check per call; measure each caller's shape before adding a second. The items check is inline since decision 37: on an M1, stored walks took 8% to 46% fewer instructions, and tree's JSON decode+walk 3.5% more. |
| `decode` took 39% more instructions on tree once `decode_run`'s fallbacks also called `decode.read_repeated`. | LLVM called it out of line from `read_field` too. | A path other code shares is inlined with `@call(.always_inline, ...)` where the hot caller calls it. |
| A mutation that turned a fast path off passed every test. | The reference path gives the same output, and the old baseline already holds the slow count. | Write the new baseline first; then `tools/perf_check.sh` fails such a mutation. |
| callgrind in an x86-64 container on an Apple Mac stops at an AVX instruction. | Rosetta's x86-64 reports no AVX, and valgrind refuses it. | A local count builds for x86-64-v2; its counts track the judge's within 1% where no code is vectorized. |
| Large binary encode took 11% more time on an EPYC 7763 with 4.79% fewer instructions. | The judge counts instructions. It does not count a missed branch or a load that waits for a store, and an M1 hides both. | Before a number is published, compare the times of two `bench-compare` runs on the same CPU. |
| Tree's decode with every field read took 10.0 µs, and 4.5 µs once its walk read each node in place. | `next` returned each message by value, and its caller copied a 56-octet node three times through memory. | An iterator gives a message as a pointer; pass a message by its address from there on. |
| Small binary encode took 9% more instructions, and small JSON encode 2.6%, when the routed calls joined the benchmark program. | The compiler lays out and inlines a program as a whole, and the calls' modules changed its choices for the codec's code. No library code changed. | A unit of work that links other modules is a program of its own, so each program's counts move only with its own code. |
| Medium binary encode took 20% more time with `writer.len += n` after each inline write. | A store through the buffer, a `[]u8`, may be the length, so the compiler reads the length again from memory, and each write waits for the one before it. | A write reads the length once, stores its octets, then stores the length. Time such a change on x86: an M1 hides the wait. |
| `tools/bench_check.sh` printed no row of the small message but its JSON decode+walk, from CI's run 141 to run 159. | `zig build bench` runs two programs into one file, and Zig 0.16's `File.writer` writes a file from its start, so `bench-call`'s table overwrote the codec table's first lines. | Each program writes standard output with `writerStreaming`, and `tools/bench_check.sh` fails when a message or a routed call lacks a row. |

A pitfall that belongs to Zig and not to connect-zig moves to pepegrillo's
`performance_zig.md`.

## The commands

```sh
zig build guide                  # install pepegrillo's method to zig-out/docs
tools/perf_check.sh              # the judge: instructions of each operation against the baseline
tools/perf_check.sh --write      # write a new baseline, in the commit that pays for it
zig build bench                  # time every operation, ReleaseFast
zig build bench -- --quick       # the smoke run CI runs
zig build costs                  # time the costs table on this machine
tools/bench_check.sh             # time connect-zig beside Go's and Rust's runtimes, compare octets
tools/fullstack_check.sh         # load the OTLP sink and the Collector over TLS and h2, on Linux
tools/fullstack_check.sh production  # the production model alone
zig build install-bench -Dcpu=x86_64_v3
valgrind --tool=callgrind --collect-atstart=no zig-out/bin/bench --instructions
callgrind_annotate callgrind.out.<pid>   # the profile, by function and by line
```
