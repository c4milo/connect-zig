# connect-zig rules

connect-zig is Connect RPC for Zig 0.16: a protobuf runtime, a protocol core for Connect, gRPC,
and gRPC-Web, `connect_colibri` over colibri, `oidc` for OpenID Connect bearer tokens,
`protovalidate` for the rules of a schema, and the protoc plugin `protoc-gen-connect-zig`.
Home: github.com/c4milo/connect-zig.

It follows the conventions of the libraries it builds on: colibri, stdx, and pepegrillo. Read their
`CLAUDE.md` before changing behaviour here.

## Read before changing behaviour

- `docs/design.md`: the module graph, the formats, and the numbered build plan (§8). Cite
  sections by number in commits and comments ("§8 step 4").
- `docs/decisions.md`: numbered decisions, each with what it beat.
- `docs/performance.md`, before a change to a hot path: the instruments, the admission rule, and
  the pitfalls, beside pepegrillo's method, which `zig build guide` installs to `zig-out/docs`.
- `docs/specs/`, before a change to the code that cites one of its files: each specification
  as its publisher wrote it, with its checksum. `docs/specs/cel/langdef.md` is the CEL language
  definition, which the CEL rules of `protovalidate` follow. Read the section, and cite it in
  the code that a new rule adds. `docs/specs/README.md` lists where the code follows cel-go
  and not the definition.

If you are about to do something a document rejected, say so and stop. Do not reverse it in
code. The same holds for colibri's and stdx's `docs/decisions.md`.

## Non-negotiables

1. **No I/O in the library.** No socket, no file, no syscall in `src/`, except the plugin in
   `src/protoc_gen/`, which is a program (decision 4). The `io` lint rule enforces it.
2. **No allocator in the library.** The caller owns every buffer. The plugin uses `init.arena`.
   The `heap` lint rule enforces it.
3. **Any event loop drives the library.** `src/` builds on colibri's protocol modules alone and
   never names Rotor or colibri's `colibri` module; Rotor reaches the examples only
   (decision 32). The `layering` lint rule enforces it.
4. **Time is a value.** No clock read and no randomness anywhere in `src/`. A deadline is an
   instant the caller passes. The `determinism` lint rule enforces it.
5. **TigerStyle.** Every loop bounded. Every limit a named constant in its module's
   `constants.zig`, with a doc comment. About two assertions per function, for programmer error
   only. Hostile input returns an error value and fails closed.
6. **Every spec rule cited, in the code.** A check that exists because a spec demands it names
   the spec and the section in a comment on the line that does the checking: the Connect
   protocol, gRPC's HTTP/2 and gRPC-Web documents, the protobuf encoding guide, the proto3
   JSON mapping, protovalidate's `validate.proto`, and the CEL language definition in
   `docs/specs/cel/langdef.md` (design §1).

## The public API is written first

- A module's root, `src/<module>/<module>.zig`, exports names, never files, except `constants`.
- Each root lists its exports in a test with `public_names.expect`, which fails when a name is
  added or missing. A new public name is a design change, recorded in design §8.

## Tests are proved by mutation

A test must fail when the code it covers is broken. When you add a check, break it on purpose and
confirm a test fails. Report `CAUGHT` or `NOT CAUGHT` per mutation in the commit body. A
`NOT CAUGHT` means a test is missing; write it.

## Conventions

- Zig 0.16. `pub fn main(init: std.process.Init) !void`; stdio through `std.Io.File.stdin()`
  and `stdout()` with `init.io`; `std.ArrayList` is unmanaged. A program writes standard output
  with `writerStreaming`: `writer` writes a file from its start, over what another program wrote
  there.
- Names spell words out. One-letter names only for loop indices. `_len` counts bytes.
- Functions stay at cognitive complexity 15 or less, `test` blocks included. Split the function;
  never raise the threshold.
- A file stays at or under 500 lines, its tests included. Generated `.pb.zig` code is one file per
  .proto file, whatever its length, and keeps every other limit, cognitive complexity included
  (decision 17).
- Every number beyond 0 and 1 has a name: a constant in its module's `constants.zig`, a `const`
  of its own, or a member of an enum such as a message's `FieldNumber`.
- Write prose in active voice with plain words: short sentences, one idea each, no metaphors.
- Use the serial comma, as Google's developer documentation style guide asks: "Connect, gRPC,
  and gRPC-Web". Where a series holds commas of its own, split the sentence instead.
- Every Markdown file renders on GitHub as written: real list markers, fenced code blocks with a
  language, pipes in a table cell escaped as `\|`.

### Commits

- A Conventional Commit: `type(scope)!: description`. Types: `feat`, `fix`, `docs`, `test`,
  `refactor`, `perf`, `build`, `ci`, `chore`. Scopes: `protobuf`, `connect`, `connect-colibri`,
  `oidc`, `protovalidate`, `plugin`, `examples`, `build`, `ci`, `docs`.
- The description is imperative, lowercase, with no final period, and the subject stays at or
  under 72 columns. The body says why, in at most 4 paragraphs and 150 words, lines at or under
  100 columns.
- Stage by explicit path. Never `git add -A` or `git add .`.
- A commit message and a pull request description name no AI tool. They carry no `Co-Authored-By`
  trailer for one, no `Claude-Session` trailer, and no "Generated with" line. The repository's
  owner ruled it on 2026-11-21, and the rule overrides a tool or a harness that asks for one.
- A comment, a review, a reply, or an issue that a session posts on GitHub names no AI tool either.
  The one exception is a cloud session whose harness ends each comment with such a line: that
  session posts its comment with the line.

## Commands

- Build: `zig build`. `-Drelease` builds ReleaseSafe.
- Test: `zig build test` runs the lint, every module's tests, the examples, and the check of the
  generated code. `zig build test-<module>` runs one module's tests alone.
- Lint: `zig build lint`: the cognitive-complexity score, then the rules of `tools/lint/main.zig`:
  heap, io, determinism, layering, unbounded-loop, file-length, markdown, relative-import,
  magic-numbers, global-state, static-alignment, defer-order, undefined-fill, unreleased-acquire, and
  denied-words, all from pepegrillo. The rule state-fill is this tree's own: a program takes its
  `State` from `rawAlloc` (decision 48). The rules read `conformance/` as they read `examples/`, and
  each `gen/` as generated code; `conformance/proto` holds connectrpc's copy and
  protobuf's test protos, which denied-words skips, as it skips protovalidate's schemas in
  `src/protovalidate/proto` and `conformance/protovalidate`. `zig build test` also requires `.githooks/pre-push` to equal pepegrillo's
  hook (`zig build hook-check`).
- Hooks: `zig build hooks` once after cloning points `core.hooksPath` at `.githooks`, whose
  pre-push hook runs the commit linter that `zig build install-commit-lint` installs. They read each `gen/` as they read hand-written code
  (decision 17).
- Commit messages: `zig build lint-commits` checks `origin/main..HEAD`.
- Examples: each folder of `examples/` is a Zig project of its own, with connect-zig as a path
  dependency, its own `proto/` and `gen/`, and one `State` per program (decisions 41 and 42).
  `zig build examples` runs `zig build test` in each, with the root's package folder and cache;
  `zig build example-<name>` runs one project's check; `examples/README.md` lists them. The
  in-memory checks (`eliza`, `streaming`, `interceptors`, `errors`, `github`, `oidc`,
  `validate`) run over `examples/harness`, whose h3 rounds use its test-only identity in
  `examples/harness/tls` (decision 25). `validate`'s schema takes validate.proto from the Buf
  Schema Registry, at the commit its `proto/buf.lock` pins. In a project's folder, run `zig
  build test --system ../../zig-pkg --cache-dir ../../.zig-cache`, never a plain `zig build`,
  which fetches 500 MB again. `zig build serve -- [port]` serves a project's service over TLS on
  h11, h2, and h3. `zig build run-eliza-server --
  [port]` serves every example's service on `colibri.Server` (`examples/socket_server`), and
  `zig build run-std-io-server -- [port]` serves ELIZA with no Rotor, on colibri's engine over
  `std.Io` (`examples/std_io`, decision 32); port 0 lets the kernel choose, and each server prints
  `listening on port <port>`. Every project that depends on another passes connect-zig the same
  options, or Zig builds a second `connect` module.
- Line coverage: `tools/line_coverage_check.sh` runs `zig build line-coverage`, pepegrillo's
  `coverage` tool under kcov 43, on Linux, in an ubuntu:26.04 container when the host has no kcov
  43, and prints each module's share of lines and the total (decision 43). The README's badge
  takes the total from a named CI run.
- Walkthroughs: `python3 tools/walkthrough/walkthrough.py [example...]` runs each example's README
  commands for real and renders the session with HyperFrames into `examples/<example>/
  walkthrough.gif`, which the README embeds. It needs Node 22 or later, FFmpeg, and Chrome.
- Generated code: `zig build test-generated` compiles the examples' generated code and runs its
  round trips, and those of `tools/wide`: one message of 1,200 fields with rules, more than
  the compiler's default branch quota, which holds the protobuf module, the plugin's table, and
  `protovalidate` to a wide message.
  `python3 tools/wide/wide_proto.py` writes its schema.
  `tools/gen` holds the checks' generated code, from `tools/proto` (decision 41).
  `tools/generate_check.sh` regenerates each `gen/` with `buf generate` and fails on a difference;
  `--write` rewrites it. It needs buf, or `BUF` naming it. It builds the plugin alone, with
  `zig build plugin`, so generated code that no longer compiles does not stop it. The root's
  `buf.yaml` is the buf workspace of the schemas that import validate.proto from this tree:
  `src/protovalidate/proto`, `conformance/protovalidate/proto`, `tools/wide/proto`, and
  `tools/fullstack/validate/proto`. Every other buf module stands alone.
- Interop: `tools/interop_check.sh` calls the socket server with `buf curl` in Connect, gRPC, and
  gRPC-Web, over h2 and h3, with curl over h11 and h2, and with OpenTelemetry's Go SDK, which
  exports spans to the OTLP receiver and reads them back (decision 40), all over TLS with the
  test CA, and checks that Chat answers full-duplex. It needs buf, curl, python3, and go.
- Benchmark: `zig build bench` times binary and JSON encode and decode, then, in a program of
  its own (`bench/call_main.zig`), a routed unary call of the small and the medium message in
  Connect and in gRPC, the small one also in tables of 16 and 256 routes, ReleaseFast;
  `tools/bench_check.sh` runs the Go benchmark in `bench/go` and, when cargo is on the path, the
  Rust one on Buffa in `bench/rust` beside it, with their calls through connect-go and
  connect-rust, and checks each writes the same bytes as Zig. The
  Rust build needs buf, or `BUF` naming it. `tools/ci.sh` runs `zig build bench -- --quick`, and
  its `bench-compare` check runs `tools/bench_check.sh`.
- Validation benchmark: `tools/validate_compare_check.sh [--quick]` times connect-zig's
  `protovalidate` (`zig build bench-validate -- <dir>`, `bench/validate_main.zig`),
  protovalidate-go (`bench/validate/go`), protovalidate-es on Node.js (`bench/validate/node`),
  and protovalidate-buffa and prost-protovalidate (`bench/validate/rust`) on the schema of
  `bench/validate/proto` and the messages of `bench/validate/cases`. It fails when two give one
  message different verdicts. Last it prints `zig build bench-validate -- --counters <dir>`: each
  validation's cycles, instructions, branches, and branch misses, through Linux's hardware
  counters (`bench/counters.zig`), where the kernel lets a process count its own events.
  `tools/validate_chart.py` draws the chart of `docs/benchmarks.md` from its
  output, and `tools/ci.sh` runs it as `validate-compare`. `tools/generate_check.sh` holds
  `bench/validate/gen`; `bench/validate/go/buf.gen.yaml` says how the Go code is written. It
  needs buf, go, node with npm, and cargo; prost-protovalidate's build runs protoc, which
  `PROTOC` names or the script downloads, pinned by SHA-256 (docs/benchmarks.md, "Validation").
- Coverage: `tools/coverage_check.sh` compares every protobuf type with Go's runtime through
  `buf convert`, over the JSON cases in `tools/testdata/`, and the binary cases with upb's,
  Python's protobuf pinned in `tools/upb_requirements.txt`, for closed enums and unchecked
  strings. It needs buf, jq, and python3 with venv.
- Conformance: `tools/conformance_check.sh` runs connectrpc's conformance runner v1.0.7 against
  `zig build conformance-server`, with the features of `conformance/config.yaml`, then in client
  mode against `zig build conformance-client`, with those of `conformance/client_config.yaml`.
  It downloads the runner pinned by SHA-256, unless `CONNECTCONFORMANCE` names one. A case that
  fails on purpose goes in `conformance/known_failing.txt` or `client_known_failing.txt`, with
  its reason; one that may fail goes in `client_known_flaky.txt`.
- Protobuf conformance: `tools/protobuf_conformance_check.sh` runs Google's protobuf conformance
  runner 37.0.0-rc1 against `zig build protobuf-testee`, in binary and JSON, for proto3, proto2,
  and edition 2023 (decision 38). It downloads the runner's npm package pinned by SHA-512,
  unless `PROTOBUF_CONFORMANCE` names a runner; the package holds one for x86-64 Linux and for
  macOS. A case that fails on purpose, or that does not pass yet, goes in
  `conformance/protobuf_known_failing.txt` under its reason.
- protovalidate: `zig build test-protovalidate` runs the `protovalidate` module's tests, and
  `zig build test-plugin` the tests of the tables the plugin writes (decision 47).
  `src/protovalidate/proto` holds validate.proto and the descriptor.proto it imports, as their
  releases wrote them, and `src/protovalidate/gen` their generated code, which the build gives
  as the modules `buf_validate_validate` and `google_protobuf_descriptor`.
  `tools/protovalidate_conformance_check.sh` runs protovalidate's conformance harness v1.2.2
  against `zig build protovalidate-executor`, with strict messages and strict errors. It builds
  the harness with go from protovalidate's repository at the release's commit, unless
  `PROTOVALIDATE_CONFORMANCE` names one, and requires the schemas of this tree to be that
  commit's. `conformance/protovalidate/gen` holds the suite's generated code, which
  `build/protovalidate.zig` reads module by module from each file's header. A case that fails on
  purpose goes in `conformance/protovalidate_known_failing.yaml` under its reason. It needs git
  and go.
- Models: `spec/lean/` holds the Lean models, one Lake package whose library is `ConnectZig`,
  and `spec/tla/<model>/` is where a TLA+ model goes, as in every project on pepegrillo.
  `zig build lean` builds the Lean package with lake, through pepegrillo's
  `lean` tool, and requires `src/protovalidate/cel/cel_vectors.txt` to be what the model gives;
  `zig build lean -- write` rewrites it. A unit test of `protovalidate` replays the file against
  the Zig grammar, with no Lean needed. `spec/lean/lean-toolchain` pins the release.
  `tools/lean_check.sh [seed...]` runs the step, and installs that release for x86-64 Linux,
  pinned by SHA-256, when no lake is on the path and `LAKE` names none. It then compares the
  model with the Zig grammar on random expressions: `lake exe vectors --random <seed> <count>`
  writes them, for each seed, the time in seconds when none is given, and
  `zig build cel-vectors-replay` builds the program that reads each with the grammar the
  compiler runs, through `src/protovalidate/cel_reader.zig`, a module root no package exports.
  `spec/README.md` says what the model holds and what it proves.
- Citations: `tools/citations_check.sh` requires each file of `docs/specs` to have the checksum
  of `docs/specs/SHA256SUMS`, and each citation `CEL language definition, "<section>"` in the
  code to name a heading of `docs/specs/cel/langdef.md`. It is the check `citations` of
  `tools/ci.sh`, and needs python3.
- Scripts: `tools/scripts_check.sh` runs ruff's lint and format check over each tracked Python
  file, under `ruff.toml`. It runs ShellCheck over each tracked shell script, under
  `.shellcheckrc`. It skips `docs/specs`, `conformance/`, `zig-pkg/`, and each `gen/`.
  `ruff format` rewrites a file that the format check refuses. A disabled check states its reason
  on its line. The script downloads ruff 0.17.6 and ShellCheck 0.11.0 for x86-64 and arm64
  Linux, each pinned by SHA-256, unless `RUFF` and `SHELLCHECK` name installed ones. It is the
  check `scripts` of `tools/ci.sh`, and needs curl, tar, xz, and git.
- CEL differential: `tools/cel_differential_check.sh [seed...]` writes a schema of random CEL
  rules and a file of random messages for each seed, 1 when none is given
  (`tools/cel_differential/generate.py`). It builds `zig build cel-differential-runner
  -Dcel-differential=<folder>` over the schema's generated code, and runs it beside
  `tools/cel_differential/reference`, which is protovalidate-go v1.4.1 on cel-go. It fails when
  a message's verdict under a rule differs: valid, invalid with its message, a failure as the
  rule runs, or a rule that does not compile. `tools/cel_differential/known.txt` holds the
  differences that pass, each with its reason. `CEL_DIFFERENTIAL_RULES` and
  `CEL_DIFFERENTIAL_MESSAGES` set a seed's size. It needs buf, python3, and go.
- CEL conformance: `tools/cel_conformance_check.sh` runs cel-spec's conformance suite at
  v0.25.3, the commit of `docs/specs/cel`, which it clones into a cache unless `CEL_SPEC` names
  a checkout. `tools/cel_conformance/generate.py` writes a case for each test that declares no
  variables and builds no message, and `zig build cel-conformance-runner
  -Dcel-conformance=<folder>` compiles each case's expression as a rule's expression compiles,
  over `src/protovalidate/cel_expression.zig`, a module root no package exports.
  `tools/cel_conformance/compare.py` fails on a result that differs from the suite's and that
  `tools/cel_conformance/known.txt` does not hold with its reason. It needs git, buf, and
  python3.
- Compile time: `tools/compile_time_check.sh` builds `zig build compile-time-subject
  -Dcompile-time=<folder>` over a schema of 690 CEL rules and over the same schema with none
  (`tools/compile_time/schema.py`), five times each in turns. It fails when the ratio of the two least
  times passes `bench/compile_time.txt` by more than 12%; `--write` records a new ratio, which
  the commit that pays for it explains. Two unit tests hold the compiler's reading and typing
  of reference expressions to a count of branches, `read_branches_max` and
  `typing_branches_max`, and `python3 tools/branch_budget.py <file> <constant>` finds the
  least count that builds (docs/performance.md, "The compiler's time"). It needs buf and
  python3.
- Fuzzer: `zig build test-<module> -Drelease --fuzz=<runs>` runs a module's fuzz properties
  under Zig's fuzzer; Zig 0.16.0's test runner compiles in fuzz mode in ReleaseSafe alone.
  `zig build test` runs each property over its corpus. `tools/ci.sh` does not run the fuzzer.
- Interop across languages: `tools/interop_languages_check.sh [client...]` runs the clients of
  `interop/` (Go, TypeScript, Python, and Rust's tonic and connect-rust) against the interop
  server of `tools/interop_server/`, which `zig build run-interop-server -- [port]` starts;
  `interop/README.md` holds their contract. It needs buf, go, node with npm, python3 with venv,
  and cargo.
- Interop servers: `tools/interop_servers_check.sh [server...]` starts the servers of `interop/`
  (connect-go, grpc-go, connect-node, grpcio, and connect-rust) and runs connect-zig's client,
  `zig build interop-client`, against each in every protocol it speaks; `interop/README.md`,
  "The server side", holds their contract. It needs buf, go, node with npm, python3 with venv,
  and cargo.
- Package: `tools/package_check.sh` builds a small project against connect-zig as `zig fetch`
  keeps it: the files `.paths` of `build.zig.zon` names, and no other. A new folder that
  `build.zig` imports joins that list. The project generates its code with the plugin, serves a
  method on colibri's exported modules over TLS, under the test identity, on h11, h2, and h3, and
  calls it with connect-zig's client and with curl (decision 39). It needs the network, buf, and
  curl.
- OIDC: `zig build test-oidc` runs the `oidc` module's tests. `build/chapulin.zig` asks for
  chapulin with colibri's own request, so a program links one chapulin object (decision 34); a
  colibri release that changes its request changes that file. `zig build example-oidc` runs a
  service behind the interceptor. `python3 tools/oidc_vectors.py` writes
  `src/oidc/rsa_vectors.zig` again: RS256 tokens that OpenSSL signs with new keys. It needs
  openssl.
- Guide: `zig build guide` installs pepegrillo's performance method and API guide to
  `zig-out/docs`, at the commit `build.zig.zon` pins.
- Full stack: `tools/fullstack_check.sh [peak] [production] [production-cleartext] [compression]
  [compression-cleartext]` loads connect-zig's OTLP sink, `zig build otlp-sink`, and
  OpenTelemetry's Collector v0.165.0 with the same OTLP exports over gRPC,
  TLS 1.3, and h2, each server on one core (decision 44). `peak` runs h2load as fast as each server
  answers. `production` runs `tools/fullstack/load`, which the check builds with cargo unless
  `FULLSTACK_LOAD` names it, as one gateway core of 33,000 servers takes traffic: 516
  connections that stay open across the climb and a mix of gzip exports, at rates that climb
  until p99 passes 100 ms. Each server climbs in three rounds, each on a new process, and the
  reports give the median and the range. Vector v0.62.0, in Rust, joins both over TLS, and Rotel
  v0.2.7, in Rust with no receiver TLS, joins the climbs in cleartext of `production-cleartext`.
  `tools/ci.sh` runs `production` as the check `fullstack`, `peak` as `fullstack-peak`, and
  `production-cleartext` as `fullstack-cleartext`. Receivers on connect-go and
  connect-rust, `tools/fullstack/connect-go` and `tools/fullstack/connect-rust`, join both over
  TLS (decision 46); the check builds them into the cache, unless `CONNECT_GO` and
  `CONNECT_RUST` name built ones. The three Connect receivers also join a second time, checking
  each export against the span rules of `tools/fullstack/validate`: `zig build
  otlp-sink-validate`, protovalidate-go, and protovalidate-buffa. `compression` and
  `compression-cleartext` run both loads on the three Connect receivers alone, over TLS or in
  cleartext h2, with exports in no coding and in gzip, zstd, and brotli, which `zig build
  otlp-compress` writes with stdx's encoders; `tools/ci.sh` runs each as a check of its own,
  `fullstack-compression` and `fullstack-compression-cleartext`, and `tools/compression_chart.py`
  draws the chart over TLS. `zig build otlp-validate-cost` times validation in the sink by the size of
  its route's storage (decision 37). It fails when a server answered an export wrongly or did not
  take every span, or when a validating one took an export that breaks a rule. It runs on Linux and needs
  h2load, buf, python3, curl, go, and cargo.
- Performance: `tools/perf_check.sh` counts each benchmark operation's instructions under
  callgrind against `bench/instructions.txt` and fails past 2%; `--write` records a new baseline,
  which the commit that pays for it explains. It needs valgrind.
- CI: `tools/ci.sh` runs every check and writes a report; `--only <check>` runs one and `--list`
  names them. `.github/workflows/main.yml` runs each check of `--list` as a job of its own on each
  push and pull request. A new check joins `tools/ci.sh`, never the workflow file. `test`,
  `bench-compare`, `fullstack`, `fullstack-compression`, and `validate-compare` run a second time
  on an arm64 runner: `test` because an aarch64 Linux link can fail where x86-64's passes, the
  next three for the arm64 charts, and `validate-compare` for its hardware counters, which
  GitHub's x86-64 runners do not expose. A `fullstack` check has 90 minutes, and every other
  check 60.
  The `fullstack` checks and `bench-compare` draw the charts of `docs/benchmarks.md` and the README into
  `ci-charts/`, which CI keeps with the run as `charts-<check>-<arch>`. To update them, copy a
  chosen run's charts to `docs/images` (decision 44).
