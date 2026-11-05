# connect-zig rules

connect-zig is Connect RPC for Zig 0.16: a protobuf runtime, a protocol core for Connect, gRPC
and gRPC-Web, an adapter over colibri, and the protoc plugin `protoc-gen-connect-zig`. Home:
github.com/c4milo/connect-zig.

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
  global-state and static-alignment. They read `examples/gen` as they read hand-written code
  (decision 17).
- Commit messages: `zig build lint-commits` checks `origin/main..HEAD`.
- Examples: `zig build examples` runs every program in `examples/` that checks itself: the ELIZA
  client against the ELIZA server over colibri's h2 and h11, in memory. `zig build
  run-eliza-server -- [port]` serves ELIZA on a TCP socket; port 0 lets the kernel choose, and the
  server prints `listening on port <port>`.
- Generated code: `zig build test-generated` compiles `examples/gen` and runs its round trips.
  `tools/generate_check.sh` regenerates it with `buf generate` and fails on a difference;
  `--write` rewrites it. It needs buf, or `BUF` naming it.
- Interop: `tools/interop_check.sh` calls the socket server with `buf curl` in Connect, gRPC and
  gRPC-Web, and with curl over h11 and h2. It needs buf and curl.
- CI: `tools/ci.sh` runs every check, and `.github/workflows/main.yml` runs it on each push. A new
  check joins `tools/ci.sh`, never the workflow file.
