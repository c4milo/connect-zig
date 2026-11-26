# Performance work in connect-zig

Every performance change follows pepegrillo's method in `docs/performance/`, starting at
`performance.md`. `zig build guide` installs it to `zig-out/docs/performance/`, at the commit
`build.zig.zon` pins. Read it first. This appendix holds what the method leaves to the project:
connect-zig's instruments, its admission rule, its baselines, its costs, and the pitfalls it has
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
  on the same machine. CI's `bench-compare` job runs it on each tag and adds the table to the
  job's summary; it fails only when the octets differ, never on a time. The chart
  `speed-vs-go-arm64.svg` comes from the tag's run of that job.
- **The full stack is a time too.** `tools/fullstack_check.sh` loads whole servers on a socket:
  connect-zig's OTLP sink, OpenTelemetry's Collector, Vector and Rotel in Rust, and receivers on
  connect-go and connect-rust, each on one core, with the load on two others (decisions 44 and
  46). Its peak part reports calls a second,
  latency, CPU time a call, and peak memory under h2load, over TLS. Its production part gives the
  span rate one gateway core holds for 33,000 servers, under `tools/fullstack/load` at climbing rates, with p99 at
  most 100 ms: over TLS beside Vector, and in cleartext beside Rotel. After the first step that
  fails, it halves the gap to the last step that passed five times, so a rate is known within
  1/64 of it (decision 44 as amended). It fails only when a server
  answered an export wrongly or did not take every span. On each tag, CI's `fullstack` job runs it
  on x86-64 and on arm64, and adds its tables to each job's summary.
- **Each tag draws the charts.** CI runs the benchmarks on a tag alone. Their jobs draw the charts
  from their own output, and CI keeps them with the run as `charts-<check>-<arch>`. Once every
  benchmark of the tag passed, the job `charts` attaches each chart to the tag's GitHub release
  and writes them to the branch `charts` (`tools/charts_release.sh`, decision 44 as amended). The
  README and `docs/benchmarks.md` show the latest tag's charts from that branch and quote no
  measured number, so no text goes stale; the run's
  summary holds every table. Each chart marks what changed since the previous tag by 5% or more,
  and the release's notes list it (`tools/chart_change.py`, `tools/charts_compare.py`).
- **The smoke run.** `zig build bench -- --quick` runs every operation on every message in a few
  short batches. CI's `bench` job runs it, so a broken operation fails before anyone times it.
- **Cycles and branch misses are a filter too.** `zig build bench-validate -- --counters <dir>`
  counts each validation's cycles, instructions, branches, and branch misses for one call, through
  Linux's hardware counters (`bench/counters.zig`). `tools/validate_compare_check.sh` prints the
  table last, and CI's `validate-compare` job, on each tag, lets the process count its own events. GitHub's
  x86-64 runners expose no counters: run 240's printed `NOENT` on an Intel Xeon 6973P-C. So the
  job runs on arm64 too, whose runners give them. A host with no counters prints a line that
  says so. A count
  shows where a time goes that the instruction count does not explain, and orders candidates
  as a time does.
- **A profile shows where the cost goes, and is never a measurement.** Run callgrind on
  `zig-out/bin/bench --instructions`, then read it with `callgrind_annotate`, by function and by
  line. A change takes its price from the counts, never from a profile.

## The units of work

The benchmark has eight messages in `bench/inputs.zig`. Four have the shapes services send:
Small (40 B), Medium (1 KB), Large (180 KB, with a 6 KB string), and Deep (50 nested levels). Four
hold one kind of field each, so their counts give the cost of that kind per field:

- Varints (90 B): each varint kind, at each length from 1 to 10 bytes.
- Strings (242 B): ASCII strings on each side of 8, 16, and 32 octets, and two short strings
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
route, the protocol, and the codec, and no framing, TLS, or socket. They are a program of their
own, `bench-call` (`bench/call_main.zig`), which `zig build bench` runs after the codec's and
`tools/perf_check.sh` counts beside it. The build makes `connect`, `connect_colibri`, and colibri's
modules in ReleaseFast for it.

A third program, `bench-validate` (`bench/validate_main.zig`), counts `protovalidate` on the
six messages of `bench/validate/cases`: "validate <case>" validates a message decoded before, and
"decode and validate <case>" decodes its octets with `decode_into`, as `connect_colibri`'s route
does, and validates what it gives. With `--instructions` it reads no file: it holds each case's
JSON and encodes it itself, so the judge needs no buf.

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
branch mispredict, a copy, and a system call, each measured on the judge. `zig build costs` times
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
| A stored list's size, with no element read | `cel_list.zig`, `count` | validate rules valid +69.92%, rules invalid +46.33%, decode and validate rules valid +32.30% |
| A stored list's element read at its place | `cel_list.zig`, `at` | validate rules valid +18.16%, rules invalid +10.20%, decode and validate rules valid +8.39% |
| A string's octet looked up in a table the compiler builds | `octet_class.zig`, `has` | validate medium valid +112.30%, small valid +100.88%, decode and validate medium valid +68.20% |
| A string's characters counted only until `min_len` or `max_len` is settled | `rule_string.zig`, `has_characters` | validate small valid +80.17%, medium valid +59.76%, medium invalid +32.72% |
| An octet found eight at a time in a string shorter than a vector | `octet_search.zig`, `index_of` | validate medium valid +21.40%, medium invalid +13.46%, small invalid +6.84% |
| Hexadecimal digits and a hostname label's octets looked up in a table | `format_name.zig`, `all_hexadecimal` and `is_label` | validate small valid +20.11%, medium valid +7.80%, medium invalid +2.82% |
| A stored list's and map's elements walked in their slice, and a stored map's key looked up from its last entry back | `cel_list.zig`, `Iterator`, `KeyIterator`, and `stored_value_at` | validate rules valid +12.41%, rules invalid +6.11%, decode and validate rules valid +5.91% |
| A pattern's searcher kept on its thread, made ready once | `pattern.zig`, `Searcher` | decode and validate medium valid +93.07%, medium invalid +55.62% |
| A map's entry value bound beside its key in a macro whose expression reads the map at the key | `cel_entry.zig`, `bound_name` and `place_of` | validate rules valid +15.23%, rules invalid +10.64%, decode and validate rules valid +6.18% |
| A short ASCII string's size read from its length | `cel_function.zig`, `size` | validate rules valid +5.65%, decode and validate rules valid +2.29%, validate rules invalid +2.06% |
| A stored list's element read inline, a view's in a call of its own | `cel_list.zig`, `List.Iterator.next` | validate rules valid +22.58%, decode and validate rules valid +6.68%, validate rules invalid +5.28% |
| A stored list's size inline, a read list's in a call of its own | `cel_list.zig`, `count` | validate rules valid +11.36%, rules invalid +9.06%, decode and validate rules invalid +3.41% |
| A stored list's index inline, a read list's in a call of its own | `cel_list.zig`, `at` | validate rules valid +3.19%, rules invalid +2.98% |
| Two ints, or two uints, compared with no order made first | `cel_eval.zig`, `compare` | validate rules valid +14.54%, rules invalid +6.19%, decode and validate rules valid +4.30% |
| A map's later entries searched for a key only when its result would end or fail `all` or `exists` | `cel_collection.zig`, `every` | validate rules valid +24.48%, decode and validate rules valid +6.18%, validate rules invalid +4.93% |
| The right side of `&&` and `\|\|` unwrapped with `try`, so no load reads two stores of its result | `cel_eval.zig`, `eval_logic` | validate rules valid +3.39%; its time, 43.6 ns to 68.7 in turns on this tree's x86-64 machine |

## The compiler's time

`protovalidate` compiles each CEL rule of a schema while the compiler builds the program (decision
47), so a rule costs the compiler time, and a schema of thousands of rules costs it seconds.
pepegrillo's `performance_zig_comptime.md`, which `zig build guide` installs, holds the items
that belong to Zig; this section holds connect-zig's numbers and checks. Zig
0.16 runs comptime code in an interpreter. One step of it costs microseconds, where the same step
of a built program costs under a nanosecond. Each number below is from Zig 0.16.0 in Debug, on a
4-core 2.1 GHz Xeon.

| Work at comptime | Cost |
| --- | --- |
| One turn of a loop | 3.5 µs |
| One call of a function | 3 µs to 5 µs |
| One slice of a slice | 5 µs |
| One read of a comptime table | 4 µs |
| `std.mem.eql` of two short texts | 20 µs |
| `@hasField` or `@field` of an enum, by a name | one step, whatever the enum's size |
| One function the compiler makes from a generic one | about 0.17 ms |

The rules that follow from it:

- **Find a name in the compiler's own table.** `@hasField(E, name)` and `@field(E, name)` find an
  enum's member in one step. A loop of `std.mem.eql` over each name takes a call of 20 µs for each.
  `cel_node.Function.of` finds a function so, and `table.place_of_name` finds a message's field
  through an enum that the compiler builds once for the message.
- **Raise the branch quota in a constant's value, and nowhere under a function that must be
  answered once.** The compiler keeps the answer of a comptime call, and gives it again for the
  same arguments. It keeps no answer of a function that calls `@setEvalBranchQuota`, and none of a
  function that calls such a function. One raise under the typing made the compiler type each part
  of an expression again for each question about it. So a function that needs a raised quota is
  the value of a constant: `fn Kept(args) type { return struct { const value = compute(args); }; }`.
  The compiler computes `Kept(args).value` once, under the quota `compute` raises, and answers
  `Kept(args)` from memory.
- **An answer from memory still counts.** The compiler adds the branches of a call's first run to
  the caller's count each time it gives the answer again. So one evaluation takes the same count of
  branches in each build, whatever the compiler computed before it, and a test states a cost as a
  quota.
- **Classify a text once, where it is read.** The tokens' reader names each operator and each
  keyword as an enum's member, and the grammar compares no text.
- **Make one function for one part.** A function that the compiler makes from a generic one costs
  as much as 50 comptime calls. A helper with one caller is `inline`.
- **A function that loops over a message's fields raises its own quota.** `inline for` counts each
  field against the quota of the function that holds it, and the default quota stops at about 500
  fields.

What a CEL rule costs, measured on a schema of 690 rules of about 40 octets each
(`tools/compile_time_check.sh`):

| Stage | Before | Now |
| --- | --- | --- |
| The compiler reads the expression's text | 6.5 ms | 4.1 ms |
| The compiler types the expression | 1.9 ms | 1.2 ms |
| The compiler makes the rule's code | 3.4 ms | 2.2 ms |
| One rule | 11.8 ms | 7.5 ms |

A check written by hand as a Zig function costs the compiler 0.17 ms, and that is the floor: a
rule cannot cost less while the compiler makes its code. The compiler reads a tree that is written
as a Zig literal in 0.04 ms, where it reads the same tree from the expression's text in 4.1 ms. So
a plugin that wrote each expression's tree beside its text would end the first row. It is not
built: decision 47 rules that the table holds the text, and the owner has not ruled on the tree.

Three checks hold the cost:

- `cel_parse.zig` reads six reference expressions under `read_branches_max`, and
  `cel_cost_test.zig` types twelve under `typing_branches_max`. Each constant is the count
  measured when it was written, and 2% more, so the tests do not build when the reader or the
  typing takes more. `python3 tools/branch_budget.py <file> <constant>` finds the least value
  that builds. The commit that pays for a higher cost raises the constant and says why.
- `cel_cost_test.zig` requires that no file on the typing's path names `@setEvalBranchQuota`,
  the table's searches among them. The table's three functions that raise the quota are in
  `table_once.zig`, and each is a constant's value.
- `tools/compile_time_check.sh` builds the schema of 690 rules, and the same schema with no CEL
  rule, five times each, in turns. It compares the least time of one with the least time of the
  other, since a time depends on the machine and their ratio does not. It fails when the ratio
  passes `bench/compile_time.txt` by more than 12%; two runs on one machine differ by 2%. It
  holds what no count states, such as the code of each rule. A quota raise that was put back
  under a search of the table on purpose raised the ratio by 10.6%, under the tolerance: the
  test of the second point is what fails for it.

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
| `tools/compile_time_check.sh` failed from `7e69611` on, at a ratio of 4.88 to 5.13 against a baseline of 4.12, and no rule cost more. | The check divides by the build without the rules, and that build got 10% cheaper when the tree moved to one stdx at 0.3.0 and a newer colibri. On one machine, a rule cost 5.94 to 6.04 ms before, and 5.79 to 6.10 ms after in seven runs of nine. | When the ratio moves, run the check at both commits on one machine, and read the two times it prints. A cheaper build without the rules asks for a new baseline: it is no cost of the rules. Eight runs on a shared machine of 4 cores gave 4.89 to 5.19, and a ninth gave 5.42, so record the median of several runs. |
| A schema of 2,300 CEL rules built in 27.7 s, and in 19.7 s with the same rules. | The reader compared each identifier's text with 21 words, and a function under the typing raised the compiler's branch quota, so the compiler kept no answer and typed each part again for each question. | The compiler's time: an enum names each word once, and a constant's value raises the quota. |
| A message of 2,000 fields stopped building once the quota was raised elsewhere. | `message.check` loops over the fields at comptime under its own quota, which a function it called had raised before. | A function that loops over a message's fields raises its own quota. `tools/wide` has 1,200 fields, more than the default quota. |
| Valid `Rules` validated in 55.4 ns on an Intel Xeon 6973P-C, where protovalidate-buffa took 26.2, and in 49.4 on a Neoverse-N2, where it took 43.7. 20% fewer instructions took 4% off its time, and 7% fewer none. | `eval_logic` passed the right side's `Error!bool` on with `return eval_side(...)`. The comparison under it wrote its error and its bool as a 16-bit store and an 8-bit store, and the reader loaded the four octets at once. x86-64 forwards no load from two stores, so the load waited for both to reach the cache, once for each element of a macro. | Unwrap an error union where a function returns one it was given: `return try f()`. Look for `movw $0x0` and `set..` to the stack followed by one wider load in the disassembly, and time the change in turns: the judge counts no such wait. |
| `duration('-3s')` stopped the build with a compiler error, and each test of the duration's reader passed. | The tests ran the reader as a program. At comptime a slice of known bounds is a pointer to an array, so `var rest = if (signed) text[1..] else text` took an array's type, which no shorter rest fits. | A function the compiler runs has a test that runs it at comptime, and a variable that holds slices of several lengths states `[]const u8`. |
| Packed binary decode+walk took 9.6% more instructions, and seven other decodes 2.0% to 2.8% more, when stdx gained `crypto`. No code the decoder runs changed. | The benchmark asked stdx for `.crypto = true` for every program. stdx's root then links chapulin's objects, so each program linked libc, and Zig compiled it as position-independent code: 20 `lea` of a table's address and a relative jump table in `decode_into`. | A benchmark program builds the way its kind of program does: the codec's and the validation's take a stdx without `crypto`, as a program without colibri does (decision 52), and `bench-call` alone takes colibri's. `file zig-out/bin/bench` says `statically linked`. |
| Small JSON decode took 7.75% more instructions at stdx `9dd95be`, and no encode moved. | stdx's `TextReader.init` returns the reader by value, and the reader held a copy of `CpuFeatures`, which grew from 13 bytes to 30. LLVM then copied the reader's 1.5 KiB queue through a memcpy call. | stdx's reader keeps no copy of the features (stdx's docs/performance.md). After a type that many values hold grows, count every decode row. |

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
zig build bench-validate -- --counters <dir>   # cycles and branch misses of each validation, on Linux
tools/compile_time_check.sh      # what a schema's CEL rules cost the compiler, against its baseline
tools/compile_time_check.sh --write   # record a new ratio, in the commit that pays for it
python3 tools/branch_budget.py src/protovalidate/cel/cel_parse.zig read_branches_max   # the least budget that builds
zig build install-bench -Dcpu=x86_64_v3
valgrind --tool=callgrind --collect-atstart=no zig-out/bin/bench --instructions
callgrind_annotate callgrind.out.<pid>   # the profile, by function and by line
```
