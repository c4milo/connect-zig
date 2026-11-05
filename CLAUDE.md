# connect-zig rules

connect-zig is Connect RPC for Zig 0.16: a protobuf runtime, a protocol core for Connect, gRPC
and gRPC-Web, `connect_colibri` over colibri, and the protoc plugin `protoc-gen-connect-zig`.
Home: github.com/c4milo/connect-zig.

It follows the conventions of the libraries it builds on: colibri, stdx and pepegrillo. Read their
`CLAUDE.md` before changing behaviour here.

## Read before changing behaviour

- `docs/design.md`: the module graph, the formats, and the numbered build plan (§8). Cite
  sections by number in commits and comments ("§8 step 4").
- `docs/decisions.md`: numbered decisions, each with what it beat.

If you are about to do something a document rejected, say so and stop. Do not reverse it in
code. The same holds for colibri's and stdx's `docs/decisions.md`.

## Non-negotiables

1. **No I/O in the library.** No socket, no file, no syscall in `src/`, except the plugin in
   `src/protoc_gen/`, which is a program (decision 4). The `io` lint rule enforces it.
2. **No allocator in the library.** The caller owns every buffer. The plugin uses `init.arena`.
   The `heap` lint rule enforces it.
3. **Time is a value.** No clock read and no randomness anywhere in `src/`. A deadline is an
   instant the caller passes. The `determinism` lint rule enforces it.
4. **TigerStyle.** Every loop bounded. Every limit a named constant in its module's
   `constants.zig`, with a doc comment. About two assertions per function, for programmer error
   only. Hostile input returns an error value and fails closed.
5. **Every spec rule cited, in the code.** A check that exists because a spec demands it names
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
  and `stdout()` with `init.io`; `std.ArrayList` is unmanaged.
- Names spell words out. One-letter names only for loop indices. `_len` counts bytes.
- Functions stay at cognitive complexity 15 or less, `test` blocks included. Split the function;
  never raise the threshold.
- A file stays at or under 500 lines, its tests included. The plugin splits a longer output
  (decision 17).
- Every number beyond 0 and 1 has a name: a constant in its module's `constants.zig`, a `const`
  of its own, or a member of an enum such as a message's `FieldNumber`.
- Write prose in active voice with plain words: short sentences, one idea each, no metaphors.
- Every Markdown file renders on GitHub as written: real list markers, fenced code blocks with a
  language, pipes in a table cell escaped as `\|`.

### Commits

- A Conventional Commit: `type(scope)!: description`. Types: `feat`, `fix`, `docs`, `test`,
  `refactor`, `perf`, `build`, `ci`, `chore`. Scopes: `protobuf`, `connect`, `connect-colibri`,
  `plugin`, `examples`, `build`, `ci`, `docs`.
- The description is imperative, lowercase, with no final period, and the subject stays at or
  under 72 columns. The body says why, in at most 3 paragraphs and 100 words, lines at or under
  100 columns.
- Stage by explicit path. Never `git add -A` or `git add .`.

## Commands

- Build: `zig build`. `-Drelease` builds ReleaseSafe.
- Test: `zig build test` runs the lint, every module's tests, the examples and the check of the
  generated code. `zig build test-<module>` runs one module's tests alone.
- Lint: `zig build lint`: the cognitive-complexity score, then the rules of `tools/lint/main.zig`:
  heap, io, determinism, unbounded-loop, file-length, markdown, relative-import, magic-numbers,
  global-state, static-alignment, defer-order, undefined-fill, unreleased-acquire and
  denied-words, all from pepegrillo. `zig build test` also requires `.githooks/pre-push` to equal
  pepegrillo's hook (`zig build hook-check`).
- Hooks: `zig build hooks` once after cloning points `core.hooksPath` at `.githooks`, whose
  pre-push hook runs the commit linter that `zig build install-commit-lint` installs. They read `examples/gen` as they read hand-written code
  (decision 17).
- Commit messages: `zig build lint-commits` checks `origin/main..HEAD`.
- Examples: `zig build examples` runs every program in `examples/` that checks itself:
  `protobuf_messages`, `sans_io_call`, and `eliza`, `streaming`, `interceptors`, `errors` and
  `github`, which run a client against the server of `examples/services/` over colibri's h11, h2
  and h3, in memory; the h3 rounds use the test-only identity of `examples/testdata/tls` (decision 25).
  `zig build example-<name>` runs one; `examples/README.md` lists them. `zig build
  run-eliza-server -- [port]` serves the ELIZA and demo services on a TCP socket, and over h3 on
  the UDP socket of the same port under the test identity; port 0 lets the kernel choose, and the
  server prints `listening on port <port>`.
- Generated code: `zig build test-generated` compiles `examples/gen` and runs its round trips.
  `tools/generate_check.sh` regenerates it with `buf generate` and fails on a difference;
  `--write` rewrites it. It needs buf, or `BUF` naming it.
- Interop: `tools/interop_check.sh` calls the socket server with `buf curl` in Connect, gRPC and
  gRPC-Web, over h2 and h3, and with curl over h11 and h2, and checks that Chat answers
  full-duplex. It needs buf and curl.
- Benchmark: `zig build bench` times binary and JSON encode and decode, ReleaseFast;
  `tools/bench_check.sh` runs the Go benchmark in `bench/go` beside it and checks both write the
  same bytes. `tools/ci.sh` runs `zig build bench -- --quick`.
- Coverage: `tools/coverage_check.sh` compares every protobuf type with Go's runtime through
  `buf convert`, over the JSON cases in `examples/testdata/`, and the binary cases with upb's,
  Python's protobuf pinned in `tools/upb_requirements.txt`, for closed enums and unchecked
  strings. It needs buf, jq and python3 with venv.
- Conformance: `tools/conformance_check.sh` runs connectrpc's conformance runner v1.0.4 against
  `zig build conformance-server`, with the features of `conformance/config.yaml`. It downloads
  the runner pinned by SHA-256, unless `CONNECTCONFORMANCE` names one. A case that fails on
  purpose goes in `conformance/known_failing.txt`, with its reason.
- Interop across languages: `tools/interop_languages_check.sh [client...]` runs the clients of
  `interop/` (Go, TypeScript, Python, Rust) against the socket server; `interop/README.md` holds
  their contract. It needs buf, go, node with npm, python3 with venv, and cargo.
- Performance: `tools/perf_check.sh` counts each benchmark operation's instructions under
  callgrind against `bench/instructions.txt` and fails past 2%; `--write` records a new baseline,
  which the commit that pays for it explains. It needs valgrind.
- CI: `tools/ci.sh` runs every check and writes a report; `--only <check>` runs one and `--list`
  names them. `.github/workflows/main.yml` runs each check of `--list` as a job of its own on each
  push and pull request. A new check joins `tools/ci.sh`, never the workflow file.
