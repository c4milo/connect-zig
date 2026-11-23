# How connect-zig is checked

Each check below is a script or a build step that CI runs as a job of its own, on each push and
pull request. `tools/ci.sh` runs them all, as CI does, and writes a report.

- `zig build test` runs the lint, every module's tests, and the examples. Each check in the
  library was broken on purpose to prove a test catches it. The examples run a client against
  the server in memory over h11, h2, and h3.
- `tools/line_coverage_check.sh` runs each module's tests under kcov ([decision 43](decisions.md)). On CI's
  [run 160](https://github.com/c4milo/connect-zig/actions/runs/44007655863) they ran 97.7% of
  the library's 8604 lines. That run came before the `protovalidate` module.
- `tools/conformance_check.sh` runs the [connectrpc conformance
  suite](https://github.com/connectrpc/conformance) v1.0.7, as CI's
  [run 160](https://github.com/c4milo/connect-zig/actions/runs/44007655863) did on colibri v0.17.3.
  The server passes all 3714 cases, over h11 and h2. The client passes all 10711, over h11, h2,
  and h3, in cleartext and over TLS. No case is listed as known to fail or as flaky. Each half's
  job summary holds a table of its cases by HTTP version, protocol, TLS, and reference peer.
- `tools/protobuf_conformance_check.sh` runs [Google's protobuf conformance
  suite](https://github.com/protocolbuffers/protobuf/tree/main/conformance) in binary and JSON,
  for proto3, proto2, and edition 2023. 5707 cases pass, and
  `conformance/protobuf_known_failing.txt` lists each of the 35 that fail, with its reason.
- protovalidate's conformance suite, a Lean model of the CEL syntax, a comparison with cel-go on
  random rules, the compiler's time, and a fuzzer check the `protovalidate` module.
  [protovalidate.md](protovalidate.md), "How it is checked", says what each one does.
- `tools/coverage_check.sh` converts every protobuf type with connect-zig and with Go's runtime,
  between binary and JSON both ways, and requires the same message.
- `tools/interop_languages_check.sh` calls the server from [clients in Go, TypeScript, Python,
  and Rust](../interop), 758 calls. `tools/interop_servers_check.sh` calls their servers with
  connect-zig's client, 831 calls. Each covers every protocol, codec, stream shape, and error.
- `tools/interop_check.sh` calls the example server with `buf curl` and curl, and with
  OpenTelemetry's Go SDK, which exports spans to the example trace receiver.
- `tools/package_check.sh` builds `examples/quickstart` against connect-zig as `zig fetch` keeps
  it, and calls it over TLS on h11, h2, and h3.
- `tools/perf_check.sh` counts each benchmark operation's instructions under callgrind, and
  fails past 2% above `bench/instructions.txt`. Counts do not move with a shared runner's load.

Each job writes its results to its summary. The tests and the comparison with Go and Rust run a
second time on an arm64 runner.

## Run the checks

Each script names what it needs: buf, Go, Node.js, Python, cargo, or valgrind.

```sh
tools/ci.sh               # every check below, as CI runs them
zig build test            # the lint, every module's tests and the examples
tools/package_check.sh    # a project that fetches connect-zig builds against it
tools/generate_check.sh   # buf generate still writes each gen/
tools/interop_check.sh    # buf curl, curl and OpenTelemetry's SDK against the example server
tools/coverage_check.sh   # every protobuf type against Go's runtime
tools/conformance_check.sh  # the connectrpc conformance suite against the server and client
tools/protovalidate_conformance_check.sh  # protovalidate's conformance harness
tools/interop_languages_check.sh  # Go, TypeScript, Python and Rust clients against the server
tools/interop_servers_check.sh    # the client against Go, TypeScript, Python and Rust servers
tools/perf_check.sh       # instructions of each benchmark operation against the baseline
tools/bench_check.sh      # the benchmark beside Go's and Rust's
```
