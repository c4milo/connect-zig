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
  `tools/bench_check.sh` runs Go's `google.golang.org/protobuf` on the same inputs beside it, and
  checks that both write the same octets. A time orders candidates and never lands in a document
  unless both programs ran in the same job on the same machine. The README's table is such a run.
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
read, and the same three in JSON. `bench/instructions.txt` holds the count of each pair. The
benchmark builds stdx's modules in ReleaseFast too, so no count includes a safety check.

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
- **upb**, through Python's protobuf pinned in `tools/upb_requirements.txt`, checks closed enums
  and unchecked strings for correctness. It is not a speed baseline.

## The costs

The method prices a claim against the costs of a first-level cache hit, a main-memory read, a
branch mispredict, a copy and a system call, each measured on the judge. connect-zig has not
measured them yet. The first change whose claim needs a price measures it, and records the run
here.

## The pitfalls

| Symptom | Cause | Rule |
| --- | --- | --- |
| callgrind stops at an illegal instruction. | valgrind runs no AVX-512, and a native build uses it. | The judge builds for x86-64-v3 (`-Dcpu=x86_64_v3`). |
| The same tree timed 2x apart on two CI runs. | Shared runners share cores and caches. | Gate on instructions; compare times only within one job (decision 30). |
| A short string decoded slower with stdx's vector UTF-8 check. | The vector loop's setup costs more than a short scalar walk. | The vector check starts at `constants.limits.utf8_vector_len_min`, 32 octets. |
| A long JSON string failed to decode in the benchmark. | The JSON token buffer was shorter than the string. | The benchmark's token buffer holds 16 KB; size it from the longest token a caller expects. |
| Large binary decode took 5.4% more instructions when the benchmark gained four messages. | More instances of the generic decoder made LLVM call `decode.read_repeated` instead of inlining it. | A new benchmark message writes a new baseline in its own commit, before any change it measures. |
| Small binary encode took 21% more instructions once `Writer.varint` was inlined whole. | The inlined loop made its callers too large for LLVM to inline in turn. | A fast path inlines its common case alone; the rest is a `noinline` function. |
| tree binary decode+walk took 4.4% more instructions when the iterator's items check moved inline. | The out-of-line rest takes the iterator's address, so each inline check reloads its fields. | One inline check per call; measure each caller's shape before adding a second. |
| A mutation that turned a fast path off passed every test. | The reference path gives the same output, and the old baseline already holds the slow count. | Write the new baseline first; then `tools/perf_check.sh` fails such a mutation. |

A pitfall that belongs to Zig and not to connect-zig moves to pepegrillo's
`performance_zig.md`.

## The commands

```sh
zig build guide                  # install pepegrillo's method to zig-out/docs
tools/perf_check.sh              # the judge: instructions of each operation against the baseline
tools/perf_check.sh --write      # write a new baseline, in the commit that pays for it
zig build bench                  # time every operation, ReleaseFast
zig build bench -- --quick       # the smoke run CI runs
tools/bench_check.sh             # time connect-zig beside Go's runtime, and compare the octets
zig build install-bench -Dcpu=x86_64_v3
valgrind --tool=callgrind --collect-atstart=no zig-out/bin/bench --instructions
callgrind_annotate callgrind.out.<pid>   # the profile, by function and by line
```
