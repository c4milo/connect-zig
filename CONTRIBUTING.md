# Contributing

connect-zig reads octets from strangers, so it holds a high bar. This page is the contributor's
summary. [CLAUDE.md](CLAUDE.md) holds the full rules, and a change follows them whoever writes it.

## Before you start

Read the two documents a change must not contradict:

- [`docs/design.md`](docs/design.md): the module graph, the formats, and the numbered build plan.
  Cite its sections by number, for example "§8 step 4".
- [`docs/decisions.md`](docs/decisions.md): every numbered decision, with what it beat. If a
  change would do something a decision rejected, raise it in an issue first.

Open work and what comes next are [GitHub issues](https://github.com/c4milo/connect-zig/issues).

## Setup

connect-zig needs Zig 0.16.0 to build and test. After cloning:

```sh
zig build hooks
zig build test
```

`zig build hooks` points git at `.githooks`, which checks commit messages. `zig build test` runs
the lint first, then every module's tests, the examples and the generated code. The first build
fetches the packages `build.zig.zon` pins: colibri and stdx, which the library links, and
pepegrillo and Rotor, which the tooling and the examples use.

Some checks need more, and each script in `tools/` names what it needs: buf for the generated
code and interop, Go for the coverage and benchmark comparisons, node, python3 and cargo for the
clients in `interop/`, and valgrind for the performance gate. `tools/ci.sh` runs every check, as
CI does.

## The rules a change keeps

- **No I/O, no heap, no clock in the library.** `src/` makes no system call, holds no
  `Allocator`, and reads no clock or random source. The caller owns every buffer and passes every
  instant. The lint refuses each of these.
- **Any event loop drives the library.** `src/` builds on colibri's protocol modules and never
  names Rotor (decision 32).
- **Every limit is named.** A limit lives in its module's `constants.zig`, never inline. Every
  loop is bounded.
- **Every spec rule is cited.** A check that exists because a spec requires it names the spec and
  the section in a comment on its line: the Connect protocol, gRPC's HTTP/2 and gRPC-Web
  documents, the protobuf encoding guide, and the proto3 JSON mapping.
- **Peer input fails closed.** A malformed octet, a short buffer or a limit reached returns an
  error value. Assertions are for programmer error.
- **Small pieces.** A function scores at most 15 on cognitive complexity, and a hand-written file
  stays at or under 500 lines, tests included. Split rather than raise a limit.
- **The public API is written first.** A new public name is a design change, recorded in
  `docs/design.md` §8, and each module root lists its names in a test.

## Tests are proved by mutation

A test must fail when the code it covers is broken. When you add or change a check, break it on
purpose and confirm a test fails. Report each mutation as `CAUGHT` or `NOT CAUGHT` in the commit
body. A `NOT CAUGHT` means a test is missing, so write it.

## Commits

Commits are [Conventional Commits](https://www.conventionalcommits.org/):
`type(scope): description`.

- The type is one of `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci` or `chore`.
- The scope is one of `protobuf`, `connect`, `connect-colibri`, `plugin`, `examples`, `build`,
  `ci` or `docs`.
- The description is imperative and lowercase, with no period, and the subject line fits in 72
  columns.
- The body says why, in at most 3 paragraphs and 100 words, with lines of at most 100 columns.

`zig build lint-commits` checks every commit since `origin/main`. Stage files by path, never with
`git add -A`.

## Asking first

Open an issue before you:

- change a named limit;
- add a dependency, or an edge to the module graph;
- weaken an assertion to make a test pass;
- build something `docs/decisions.md` says connect-zig does not build.

## Security

Do not report a vulnerability in an issue. [SECURITY.md](SECURITY.md) says where to send it.
