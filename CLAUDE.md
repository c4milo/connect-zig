# connect-zig rules

connect-zig is Connect RPC for Zig 0.16: a protobuf runtime, a protocol core for Connect, gRPC
and gRPC-Web, `connect_colibri` over colibri, `oidc` for OpenID Connect bearer tokens, and the
protoc plugin `protoc-gen-connect-zig`.
Home: github.com/c4milo/connect-zig.

It follows the conventions of the libraries it builds on: colibri, stdx and pepegrillo. Read their
`CLAUDE.md` before changing behaviour here.

## Read before changing behaviour

- `docs/design.md`: the module graph, the formats, and the numbered build plan (§8). Cite
  sections by number in commits and comments ("§8 step 4").
- `docs/decisions.md`: numbered decisions, each with what it beat.
- `docs/performance.md`, before a change to a hot path: the instruments, the admission rule and
  the pitfalls, beside pepegrillo's method, which `zig build guide` installs to `zig-out/docs`.

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
   protocol, gRPC's HTTP/2 and gRPC-Web documents, the protobuf encoding guide, and the proto3
   JSON mapping (design §1).

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
- Every Markdown file renders on GitHub as written: real list markers, fenced code blocks with a
  language, pipes in a table cell escaped as `\|`.

### Commits

- A Conventional Commit: `type(scope)!: description`. Types: `feat`, `fix`, `docs`, `test`,
  `refactor`, `perf`, `build`, `ci`, `chore`. Scopes: `protobuf`, `connect`, `connect-colibri`,
  `oidc`, `plugin`, `examples`, `build`, `ci`, `docs`.
- The description is imperative, lowercase, with no final period, and the subject stays at or
  under 72 columns. The body says why, in at most 4 paragraphs and 150 words, lines at or under
  100 columns.
- Stage by explicit path. Never `git add -A` or `git add .`.

## Commands

- Build: `zig build`. `-Drelease` builds ReleaseSafe.
- Test: `zig build test` runs the lint, every module's tests, the examples and the check of the
  generated code. `zig build test-<module>` runs one module's tests alone.
- Lint: `zig build lint`: the cognitive-complexity score, then the rules of `tools/lint/main.zig`:
  heap, io, determinism, layering, unbounded-loop, file-length, markdown, relative-import,
  magic-numbers, global-state, static-alignment, defer-order, undefined-fill, unreleased-acquire and
  denied-words, all from pepegrillo. The rules read `conformance/` as they read `examples/`, and
  each `gen/` as generated code; `conformance/proto` holds connectrpc's copy and
  protobuf's test protos, which denied-words skips. `zig build test` also requires `.githooks/pre-push` to equal pepegrillo's
  hook (`zig build hook-check`).
- Hooks: `zig build hooks` once after cloning points `core.hooksPath` at `.githooks`, whose
  pre-push hook runs the commit linter that `zig build install-commit-lint` installs. They read each `gen/` as they read hand-written code
  (decision 17).
- Commit messages: `zig build lint-commits` checks `origin/main..HEAD`.
- Examples: each folder of `examples/` is a Zig project of its own, with connect-zig as a path
  dependency, its own `proto/` and `gen/`, and one `State` per program (decisions 41 and 42).
  `zig build examples` runs `zig build test` in each, with the root's package folder and cache;
  `zig build example-<name>` runs one project's check; `examples/README.md` lists them. The
  in-memory checks (`eliza`, `streaming`, `interceptors`, `errors`, `github`, `oidc`) run over
  `examples/harness`, whose h3 rounds use its test-only identity in `examples/harness/tls`
  (decision 25). In a project's folder, run `zig build test --system ../../zig-pkg --cache-dir
  ../../.zig-cache`, never a plain `zig build`, which fetches 500 MB again. `zig build serve --
  [port]` serves a project's service over TLS on h11, h2 and h3. `zig build run-eliza-server --
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
  walkthrough.gif`, which the README embeds. It needs Node 22 or later, FFmpeg and Chrome.
- Generated code: `zig build test-generated` compiles the examples' generated code and runs its
  round trips.
  `tools/gen` holds the checks' generated code, from `tools/proto` (decision 41).
  `tools/generate_check.sh` regenerates each `gen/` with `buf generate` and fails on a difference;
  `--write` rewrites it. It needs buf, or `BUF` naming it. It builds the plugin alone, with
  `zig build plugin`, so generated code that no longer compiles does not stop it.
- Interop: `tools/interop_check.sh` calls the socket server with `buf curl` in Connect, gRPC and
  gRPC-Web, over h2 and h3, with curl over h11 and h2, and with OpenTelemetry's Go SDK, which
  exports spans to the OTLP receiver and reads them back (decision 40), all over TLS with the
  test CA, and checks that Chat answers full-duplex. It needs buf, curl, python3 and go.
- Benchmark: `zig build bench` times binary and JSON encode and decode, then, in a program of
  its own (`bench/call_main.zig`), a routed unary call of the small and the medium message in
  Connect and in gRPC, the small one also in tables of 16 and 225 routes, ReleaseFast;
  `tools/bench_check.sh` runs the Go benchmark in `bench/go` and, when cargo is on the path, the
  Rust one on Buffa in `bench/rust` beside it, with their calls through connect-go and
  connect-rust, and checks each writes the same bytes as Zig. The
  Rust build needs buf, or `BUF` naming it. `tools/ci.sh` runs `zig build bench -- --quick`, and
  its `bench-compare` check runs `tools/bench_check.sh`.
- Coverage: `tools/coverage_check.sh` compares every protobuf type with Go's runtime through
  `buf convert`, over the JSON cases in `tools/testdata/`, and the binary cases with upb's,
  Python's protobuf pinned in `tools/upb_requirements.txt`, for closed enums and unchecked
  strings. It needs buf, jq and python3 with venv.
- Conformance: `tools/conformance_check.sh` runs connectrpc's conformance runner v1.0.7 against
  `zig build conformance-server`, with the features of `conformance/config.yaml`, then in client
  mode against `zig build conformance-client`, with those of `conformance/client_config.yaml`.
  It downloads the runner pinned by SHA-256, unless `CONNECTCONFORMANCE` names one. A case that
  fails on purpose goes in `conformance/known_failing.txt` or `client_known_failing.txt`, with
  its reason; one that may fail goes in `client_known_flaky.txt`.
- Protobuf conformance: `tools/protobuf_conformance_check.sh` runs Google's protobuf conformance
  runner 37.0.0-rc1 against `zig build protobuf-testee`, in binary and JSON, for proto3, proto2
  and edition 2023 (decision 38). It downloads the runner's npm package pinned by SHA-512,
  unless `PROTOBUF_CONFORMANCE` names a runner; the package holds one for x86-64 Linux and for
  macOS. A case that fails on purpose, or that does not pass yet, goes in
  `conformance/protobuf_known_failing.txt` under its reason.
- Interop across languages: `tools/interop_languages_check.sh [client...]` runs the clients of
  `interop/` (Go, TypeScript, Python, and Rust's tonic and connect-rust) against the interop
  server of `tools/interop_server/`, which `zig build run-interop-server -- [port]` starts;
  `interop/README.md` holds their contract. It needs buf, go, node with npm, python3 with venv,
  and cargo.
- Interop servers: `tools/interop_servers_check.sh [server...]` starts the servers of `interop/`
  (connect-go, grpc-go, connect-node, grpcio and connect-rust) and runs connect-zig's client,
  `zig build interop-client`, against each in every protocol it speaks; `interop/README.md`,
  "The server side", holds their contract. It needs buf, go, node with npm, python3 with venv,
  and cargo.
- Package: `tools/package_check.sh` builds a small project against connect-zig as `zig fetch`
  keeps it: the files `.paths` of `build.zig.zon` names, and no other. A new folder that
  `build.zig` imports joins that list. The project generates its code with the plugin, serves a
  method on colibri's exported modules over TLS, under the test identity, on h11, h2 and h3, and
  calls it with connect-zig's client and with curl (decision 39). It needs the network, buf and
  curl.
- OIDC: `zig build test-oidc` runs the `oidc` module's tests. `build/chapulin.zig` asks for
  chapulin with colibri's own request, so a program links one chapulin object (decision 34); a
  colibri release that changes its request changes that file. `zig build example-oidc` runs a
  service behind the interceptor. `python3 tools/oidc_vectors.py` writes
  `src/oidc/rsa_vectors.zig` again: RS256 tokens that OpenSSL signs with new keys. It needs
  openssl.
- Guide: `zig build guide` installs pepegrillo's performance method and API guide to
  `zig-out/docs`, at the commit `build.zig.zon` pins.
- Full stack: `tools/fullstack_check.sh [peak] [production]` loads connect-zig's OTLP sink, `zig
  build otlp-sink`, and OpenTelemetry's Collector v0.165.0 with the same OTLP exports over gRPC,
  TLS 1.3 and h2, each server on one core (decision 44). `peak` runs h2load as fast as each server
  answers. `production` runs oha, pinned by SHA-256 as the Collector is, as one gateway core of
  33,000 servers takes traffic: 516 connections and a mix of gzip exports, at rates that climb
  until p99 passes 100 ms. It fails when a server answered an export wrongly or did not take
  every span. It runs on Linux and needs h2load, buf, python3 and curl.
- Performance: `tools/perf_check.sh` counts each benchmark operation's instructions under
  callgrind against `bench/instructions.txt` and fails past 2%; `--write` records a new baseline,
  which the commit that pays for it explains. It needs valgrind.
- CI: `tools/ci.sh` runs every check and writes a report; `--only <check>` runs one and `--list`
  names them. `.github/workflows/main.yml` runs each check of `--list` as a job of its own on each
  push and pull request. A new check joins `tools/ci.sh`, never the workflow file. `test` and
  `bench-compare` run a second time on an arm64 runner: `test` because an aarch64 Linux link can
  fail where x86-64's passes, and `bench-compare` for the README's arm64 chart.
