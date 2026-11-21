# connect-zig design

connect-zig is [Connect RPC](https://connectrpc.com/docs/protocol/) for Zig 0.16: a protobuf
runtime, a protocol core, `connect_colibri` over [colibri](https://github.com/c4milo/colibri),
and the protoc plugin `protoc-gen-connect-zig`. This document holds the module graph, the
formats, and the numbered build plan. Decisions are numbered in [decisions.md](decisions.md).

## 1. Sources

Each rule in the code cites the document that states it:

- The Connect protocol: <https://connectrpc.com/docs/protocol/>.
- gRPC over HTTP/2: <https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md>.
- gRPC-Web: <https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md>.
- The protobuf encoding: <https://protobuf.dev/programming-guides/encoding/>.
- The proto3 JSON mapping: <https://protobuf.dev/programming-guides/json/>.
- The gRPC status codes: <https://grpc.github.io/grpc/core/md_doc_statuscodes.html>.
- For `oidc`: RFC 7515 (JWS), RFC 7517 (JWK), RFC 7518 (JWA), RFC 7519 (JWT), RFC 8037
  (EdDSA in JOSE), RFC 8725 (JWT best practices), RFC 6750 (bearer tokens) and OpenID Connect
  Core 1.0: <https://openid.net/specs/openid-connect-core-1_0.html>.
- For `protovalidate`: `buf/validate/validate.proto` of protovalidate v1.2.2,
  <https://github.com/bufbuild/protovalidate>, whose comments state each rule and whose
  `(buf.validate.predefined).cel` options define it. The code cites a rule by its message and
  its field: "validate.proto, StringRules.min_len".

## 2. Rules

The library owns no I/O, reads no clock and holds no allocator (decisions 3 and 4). Every loop
is bounded, and every bound is a constant in its module's `constants.zig`. Assertions stay on in
production and cover programmer error alone. Hostile input returns an error value.

## 3. Module graph

```text
protobuf          <- stdx json, stdx codec
connect           <- protobuf, stdx json, codec, gzip, zstd, brotli
connect_colibri   <- connect, protobuf, colibri server, client, http
oidc              <- connect, stdx json, codec, chapulin
protovalidate     <- protobuf, buf_validate_validate, google_protobuf_descriptor
buf_validate_validate (generated)      <- protobuf, google_protobuf_descriptor
google_protobuf_descriptor (generated) <- protobuf
protoc-gen-connect-zig (executable) <- protobuf
```

`connect` imports no HTTP library (decision 2). Only `connect_colibri` imports colibri. `oidc`
imports chapulin for its `jws` calls, and no colibri module (decision 34). `protovalidate`
imports no `connect` module (decision 47). Its two generated modules are the plugin's code for
`buf/validate/validate.proto` and `google/protobuf/descriptor.proto`, in
`src/protovalidate/gen`, from the copies in `src/protovalidate/proto`.

## 4. The protobuf runtime

A generated message is a struct. Its `pub const protobuf: proto.Descriptor` names each field:
the Zig name, the number, the kind, the JSON name, the .proto name, and the oneof that holds it.
`encode`, `decode` and `encoded_len` read the table at comptime (decisions 6 and 7).

- `decode` copies nothing. Strings and bytes are slices of the input. `Repeated` fields are views,
  read by an iterator that accepts packed and unpacked elements.
- `decode` checks every element when it reads the message: wire types, UTF-8 and nested
  messages. An iterator over a decoded view therefore reads only checked bytes.
- Merge follows "Last One Wins": scalars keep the last value, messages merge, a oneof keeps the
  member read last. A merge that a view cannot hold fails closed (decision 6).
- Unknown fields are kept in a generated message's `_unknown` and written back (decision 24);
  groups nest at most `depth_max` deep.
- `encode` writes fields in number order. Implicit scalars at their default are left off, and
  packable repeated fields are packed unless the field says otherwise.

## 5. Proto3 JSON

`encode_json` writes a message with stdx's `json.TextWriter`. `decode_json` transcodes JSON into
the binary encoding in a caller scratch buffer and then calls `decode` (decision 9). Well-known
types live in `proto.wkt` and have their own JSON forms: Timestamp, Duration, the wrappers,
Empty, FieldMask, Struct, Value, ListValue and Any. An Any names its type from a comptime list
(decision 21).

## 6. The protocol core

`connect` holds each rule of the three protocols as a function over values:

- `code`: the 16 error codes and `ok`, their names, the Connect HTTP status of each, and the
  code a client reads from an HTTP status when the body is not a Connect error.
- `envelope`: the 5-byte prefix of a streamed message. Flag 0x01 is compressed, 0x02 is Connect's
  end-stream message, and 0x80 is gRPC-Web's trailers frame.
- `protocol`: the content types of each protocol and codec, and the request's protocol.
- `timeout`: `Connect-Timeout-Ms` (at most 10 digits) and `grpc-timeout` (at most 8 digits and a
  unit of H, M, S, m, u or n), as nanoseconds.
- `error_json`: the Connect error body `{code, message, details[{type, value}]}`, where `value`
  is unpadded base64.
- `end_stream`: the end-stream message `{error, metadata}`.
- `trailers`: `grpc-status`, a percent-encoded `grpc-message`, and `grpc-status-details-bin`, the
  base64 of a `google.rpc.Status`.
- `get`: a unary GET of a `NO_SIDE_EFFECTS` method: `message`, `encoding`, `base64`,
  `compression` and `connect=v1`.
- `compression`: the names of the codings and the choice of one, over stdx (decision 10).
- `Method`: what generated code names for each RPC: the service, the method, the request and
  response types, the stream type and the idempotency.

## 7. connect_colibri

`connect_colibri` maps a `connect.Method` onto a stream route of `server.Router` (colibri
decision 163, decision 45), and onto `client.Request` and `client.Response`. A function
handler's route keeps the body in the router's memory and reads it whole, in place, at its end
(decision 12). A type handler's route reads the body as it arrives and answers each message at
once, full-duplex over h2 (decision 18). A type handler with `next` gives one message at a time,
at colibri's `next`, so its stream may be longer than the router's response memory (decision
33). A client's streamed call writes each
message with its `Sender` and reads each answer as its piece arrives, full-duplex over h2 and h3
(decision 18 as amended). Interceptors wrap a route's handler and a client's exchange (decision
19). The client speaks Connect, gRPC-Web and gRPC (decision 11).

## 8. Build plan

Each step names the check that proves it. A step is done when its check passes in CI.

1. **Skeleton.** README, CLAUDE.md, LICENSE, this document, decisions.md, `build.zig`,
   `build.zig.zon` and CI. Check: `zig build test` runs the lint and the public-names test.
2. **Binary runtime.** `protobuf` with round trips, packed and unpacked input, merge semantics,
   UTF-8, group skipping with a depth bound, and the encoding guide's vectors. Check: `zig build
   test-protobuf`, with each check's mutation caught.
3. **Proto3 JSON and the first well-known types.** Check: `zig build test-protobuf` holds round
   trips through JSON and the JSON forms of each well-known type.
4. **The protocol core.** Check: `zig build test-connect`, with each rule's vector from the
   protocol documents of §1.
5. **`connect_colibri` and `examples/eliza`.** Generated code committed, and a server on
   Rotor's loop. Check: `zig build examples` runs a client against the server over an in-memory
   link, in each protocol the client speaks; `tools/interop_check.sh` calls the socket server
   with buf curl in each protocol.
6. **The plugin.** `protoc-gen-connect-zig` reads a `CodeGeneratorRequest` from stdin and writes
   one `<file>.pb.zig` for each file. Check: CI runs `buf generate` with a pinned buf over
   `examples/`, and the output equals the committed code.
7. **Conformance.** The connectrpc conformance suite against the client and the server. Check:
   the suite's report, pinned to a release, for both halves.
8. **Calls, interceptors and full-duplex streams.** `Call` exposes the protocol, codec,
   timeout and request headers, and takes response headers and trailers. Interceptors run on
   both sides, and type handlers stream (decisions 18 and 19). New public names:
   `ExchangeWith`. Check: `zig build examples` runs `interceptors`, `streaming` and `errors`
   over the in-memory link; `tools/interop_check.sh` calls the demo service with buf curl in
   each protocol, and requires Chat's first answer before the client's second message.
9. **Every protobuf type against a reference.** `examples/proto/coverage` holds each scalar in
   each cardinality, every map key type, oneofs, enums, recursion and each well-known type.
   Check: `tools/coverage_check.sh` converts each case in `examples/testdata/coverage`,
   `editions` and `legacy` with Zig and with Go, through buf convert, and requires the same
   message both ways. `editions` and `legacy` hold edition 2023's features and proto2's groups
   (decision 23).
10. **h3 in memory.** A test-only TLS identity, and a round over h3 in each program over the
    in-memory link, beside its cleartext rounds (decision 25). Check: `zig build examples` runs
    `eliza`, `streaming`, `interceptors` and `errors` over h3, with the checks of their other
    rounds.

11. **OpenID Connect tokens.** The `oidc` module: a `Verifier` of a JWT bearer token on
    chapulin's `jws` calls, and a server interceptor with excluded paths (decision 34). New
    public names, all in `oidc`: `Verifier`, `VerifierOptions`, `Claims`, `Error`, `Interceptor`,
    `InterceptorOptions`, `bearer_token` and `constants`. Check: `zig build test-oidc` holds the
    RFCs' known answers for each algorithm and each refusal, with each check's mutation caught.
12. **Values for each call.** `RouteOptions.Values`, a struct the program declares, which the
    route keeps for each call; `Context.values` reads it (decision 35, in its final form after
    step 13). `oidc.Claims` holds its own storage,
    `Verifier.verify` writes into it, and `Claims.string`, `integer` and `holds` read a
    program's own claims. New public names: none at a module's root; a field of `RouteOptions`,
    a method of the call, and the methods of `oidc.Claims`. `Verifier.claims` goes. Check: `zig
    build test-connect-colibri` runs two interleaved streams through colibri's router, and each
    callback reads its own call's values; `zig build test-oidc` holds each lookup and each
    claims' owner.
13. **A handler takes ctx, request and response.** `Call`, `Sender` and `Receiver` go; a handler
    and an interceptor take `Context`, a request and a response (decision 36). New public names
    in `connect_colibri`: `Context`, `Request`, `RequestStream`, `Response`, `ResponseStream`,
    `AnyRequest` and `AnyResponse`. Check: every module's tests, the examples and the
    conformance server build and pass on the new signatures.
14. **Decode into the caller's storage.** `decode_into` reads each repeated field's elements,
    and each `Lazy` field's message, into storage the caller passes, once (decision 37).
    `decode` does not change. New public name in `protobuf`: `decode_into`. Check: `zig build
    test-protobuf` holds a proof harness that decodes each input with both calls and requires
    the same message or the same refusal; `tools/bench_check.sh` decodes with `decode_into`
    before its binary walk, and still matches Go's and Buffa's octets and sums.
15. **Services decode with storage.** `connect.Scratch` gains `storage`, and the codec takes
    `decode_into` for a binary message when it is not empty. Each route of `connect_colibri`
    holds `storage_bytes` of it for its requests: `message_bytes` unless a program names another
    size, and 0 keeps `decode` (decision 37). A client passes storage in its own `Scratch`. New
    public names: none at a module's root; the field `storage` of `connect.Scratch`, and the
    field `storage_bytes` of `connect_colibri.RouteOptions`. Check: `zig build test-connect`
    decodes into a scratch's storage and without one; `zig build test-connect-colibri` holds
    each size of a request's storage.
16. **Read a repeated field's messages in place.** A repeated field's iterator gives a
    message as a pointer, and copies none that lies in `items`; it gives any other element by
    value, as before (decision 37). This changes `next` for a field of messages: its result is
    `?*const T`, where it was `?T`. New public names: none at a module's root; the type `Item`
    of a `Repeated` field's `Iterator`, and its field `current`. Check: `zig build
    test-protobuf` reads each node its harness decodes through its iterators, from a view and
    from storage, and requires the same elements in the same order; `tools/bench_check.sh`
    walks each field of messages in place, and still matches Go's and Buffa's sums.
17. **Google's protobuf conformance suite.** `tools/protobuf_conformance_check.sh` runs the
    suite's runner against `conformance/protobuf_testee.zig`, in binary and in JSON, and
    `tools/ci.sh` holds it as the check `protobuf-conformance` (decision 38). New public
    names: none. `zig build plugin` builds the plugin alone. Check: the runner passes with the
    cases of `conformance/protobuf_known_failing.txt` as its expected failures. At its first
    run 5629 cases pass, 48 are skipped and 113 are listed. The fixes it led to leave 5635
    passing and 107 listed. On 2026-11-17, JSON encode wrote a map key once (decision 38), and
    5707 pass with 35 listed. Runner 37.0.0-rc1 is the npm package's newest; protobuf's rc2 and
    rc3 change no file under `conformance/`.
18. **Checks out of the examples.** The coverage converter, the interop client and the test of
    the generated code move to `tools/`, with the schemas that only they read (decision 41).
    New public names: none. Check: `tools/coverage_check.sh`, `tools/interop_servers_check.sh`
    and `zig build test-generated` pass from their new places.
19. **Each example a project.** `examples/harness` and one project for each example, each
    with its own manifest, schema and generated code, and `examples/quickstart`, the README's
    steps (decision 41). New public names: none. Check: `zig build examples` runs `zig build
    test` in each project; `tools/package_check.sh` builds `examples/quickstart` against a
    fetched copy and calls it over h2 and h3.
20. **The library's rules on every tree.** The lint reads `examples/`, `bench/` and
    `conformance/` with every rule but the four of a library, and each program allocates its
    one `State` at startup (decision 42). New public names: none. Check: `zig build lint`.
21. **OpenTelemetry's trace export.** `examples/otlp` serves `TraceService`, and
    `interop/otel` exports spans to it with OpenTelemetry's Go SDK (decision 40). New public
    names: none. Check: `tools/interop_check.sh`, which runs `interop/otel` against the socket
    server, and `examples/otlp`'s own `zig build test`.
22. **A client interceptor's context.** `ClientCallOptions.Context`, and a context argument of
    `ClientCall.init` and `init_stream`, which each hook gets first (decision 44). New public
    names: none; the options gain a field, and `init` and `init_stream` an argument. Check:
    `zig build test-connect-colibri`, and `examples/interceptors`, whose `Count` counts each
    response in the program's `Tally`.
23. **A routed call in the benchmark.** `bench/call.zig` runs a unary call of the small and of
    the medium message through `connect_colibri`'s route on colibri's router, in Connect and in
    gRPC, so the judge counts what a call costs beside the codec (`docs/performance.md`).
    bench/go and bench/rust make the same calls through connect-go and connect-rust. New public
    names: none. Check: `zig build bench -- --quick` checks each reply's octets,
    `tools/bench_check.sh` compares them across the three, and `tools/perf_check.sh` counts the
    four calls.
24. **colibri v0.17.0.** `connect_colibri` serves each method as a stream route, reads a whole
    body in place at its end, and takes a call's values from colibri's request context
    (decision 45, decision 35 as amended). New public names: none; `RouteOptions.Values` goes.
    Check: `zig build test` on the tag, and `tools/perf_check.sh`, whose routed calls take a
    new baseline.
25. **What conformance suite v1.0.7 asks of the client.** A Connect GET writes its query in the
    protocol's order, and a call whose stream the server reset ends with the code gRPC's table
    gives the reset. New public names: none; `rpc.failure_of` takes the pool's response,
    `*const client.Response`, in place of its `client.Result`. Check: `zig build test-connect`,
    `zig build test-connect-colibri`, `zig build test-conformance`, and runner v1.0.7 in client
    mode.
26. **brotli written.** A program places stdx v0.1.1's brotli encoder in `Encoders.brotli`, and
    a server or a client then writes `br` as it writes gzip and zstd (decision 10 as amended).
    New public names: `connect.BrotliEncoder`; `Encoders` gains the field `brotli`. Check:
    `zig build test-connect`, the conformance suite with `COMPRESSION_BR` in both halves'
    features, and `tools/interop_check.sh`, where curl reads a br answer.
27. **Route tables in the routed call.** The small message's routed call runs in tables of 1,
    16 and 256 routes (225 before colibri v0.18.0, whose router compiles a table of 256), in
    connect-zig, connect-go and connect-rust, each a square of services and methods with the
    same paths. connect-go's call goes through an `http.ServeMux`, as a connect-go server's
    does. New public names: none. Check: `tools/bench_check.sh`, which fails
    when a table size lacks its row, and `tools/routes_chart.py`, which draws each call's time
    against its time with one route.
28. **The full stack.** `tools/fullstack_check.sh` loads connect-zig's OTLP sink,
    `tools/otlp_sink`, and OpenTelemetry's Collector with the same OTLP exports, over gRPC, TLS
    1.3 and h2, under h2load. It reports calls a second, latency at p50 and p99, CPU time a call
    and peak memory (decision 44). New public names: none. Check: one export through `buf curl`
    answers with OTLP's full success, and each server's count of the spans it took equals the
    spans it was sent, with none refused.
29. **The production model.** `tools/fullstack/production.sh` loads each server as one gateway
    core of a fleet of 33,000 servers: 516 TLS connections, gzip exports of 16, 128 and 512
    spans from 70%, 25% and 5% of them, under oha at rates that climb until p99 passes 100 ms
    or a call is refused (decision 44). The sink reads gzip and holds 528 connections. New public
    names: none. Check: the probes and the counts of step 28, over the whole climb.
30. **Servers in Rust.** Vector joins the peak part and the climb over TLS. A second climb, in
    cleartext h2, loads connect-zig, the Collector and Rotel, whose receiver has no TLS. The sink
    takes a second argument, `cleartext`, and then serves with no identity (decision 44). New
    public names: none. Check: the probes and the counts of step 28, with Vector's events and
    Rotel's internal metrics.
31. **Other Connect libraries.** Receivers on connect-go and connect-rust join the peak part and
    the climb over TLS, each on one core (decision 46, issue 7). Each counts the spans it took and
    answers the counts, connect-rust on a port of its own. New public names: none. Check: the
    probes and the counts of step 28.
32. **protovalidate's standard rules.** The `protovalidate` module, and the tables the plugin
    writes for it (decision 47). The plugin reads `(buf.validate.message)`,
    `(buf.validate.oneof)` and `(buf.validate.field)` from each descriptor's options, and
    writes `pub const protovalidate` and `RuleNumber` in each message that has a rule or holds
    a message that has one. `validate` checks `required`, `ignore`, a oneof's `required`, a
    message's `oneof` rules and each type's standard rules, and walks nested messages,
    repeated fields and maps. New public names, all in `protovalidate`: `constants`, `Rules`,
    `validate`, `Options`, `Report`, `Violation`, `Error` and `rules_error`. The package gains
    the modules `protovalidate`, `buf_validate_validate` and `google_protobuf_descriptor`.
    Check: `zig build test-protovalidate` and `zig build test-plugin`, with each check's
    mutation caught; `tools/protovalidate_conformance_check.sh` runs protovalidate's
    conformance harness v1.2.2 against `zig build protovalidate-executor`, with the cases that
    wait for steps 34 and 35 in `conformance/protovalidate_known_failing.yaml`, each under its
    reason.
33. **A hook for each request message.** An interceptor may declare `on_message(app, ctx, T,
    message)`, which a route calls with each request message once it is decoded, before the
    handler takes it (decision 47, which amends decisions 19 and 36). An error it returns ends
    the call as a handler's does. `protovalidate.Interceptor(connect, Values, options)`
    validates the message there. It refuses a message that breaks a rule with
    `invalid_argument`, a message that names the first violation, and a
    `buf.validate.Violations` detail. The call's values hold what that error points to, in a
    field `protovalidate` of the type `protovalidate.InterceptorRoom(connect, options)`. New
    public names, all in `protovalidate`: `Interceptor`, `InterceptorOptions` and
    `InterceptorRoom`, which a server's program names. `connect_colibri`'s root gains none.
    Check: `zig build test-connect-colibri` runs the hook for a unary call and for each message
    of a stream, by both kinds of handler; `zig build test-protovalidate` runs the interceptor
    over a stand-in for `connect`; the example project `validate` serves methods behind the
    interceptor over h2, h11 and h3.
34. **CEL.** The module compiles `cel` and `cel_expression` rules at comptime, from the text
    the table holds (decision 47 as amended on 2026-11-21). The step has four parts, and each
    ends with its conformance cases off the known-failing list.
    - Part a: the tokens, the parser, each part's type from the message's descriptor, and the
      code it unfolds into, for the rules of a message and of a scalar or message field.
    - Part b: lists and maps, with their macros, and the rules of `repeated.items`, `map.keys`
      and `map.values`.
    - Part c: protovalidate's own functions, such as `isEmail`, over the format checks of step
      32, and `format`.
    - Part d: the predefined rules of an extension. The plugin reads each extension's value
      and its rules from its request, and writes them into the table.

    The grammar is one code for the compiler and for a test at run time. Zig's fuzzer and
    the vectors of a Lean model in `spec/lean/` check it (decision 47 as amended).

    New public names: `protovalidate.Error` gains `Unevaluable`, for an expression that fails
    at run time. `Rules.Field` gains `predefined`, which the plugin writes. No root name is
    new. Check: `zig build test-protovalidate`, with each check's mutation caught, and the
    conformance cases of custom rules, of the library's functions and of predefined rules
    leave the known-failing list. The cases whose expression calls `matches` stay, for step
    35.
35. **Patterns.** `pattern` rules and CEL's `matches` run on stdx's regular expression module
    (decision 47). New public names: none. Check: the conformance cases of patterns leave the
    known-failing list.

### Step records

Each step records here what was run, on what, and what it printed, once its check passes. Each
ran on Linux x86-64 with Zig 0.16.0.

- **Steps 1 and 2.** `zig build test` printed 24 of 24 tests passed, with the lint. Each
  mutation of a check's commit was CAUGHT once its test existed; the commits list them.
- **Step 3.** `zig build test-protobuf` printed 39 of 39 tests passed.
- **Step 4.** `zig build test-connect` printed 42 of 42 tests passed. `exchange_test.zig` plays
  a client against a server for each protocol, codec and stream type.
- **Step 5.** `zig build example-eliza` printed "every call answered as expected over h2 and
  h11": Connect POST and GET, a gRPC-Web server stream, a Connect bidirectional stream with a
  trailer, and a gRPC Trailers-Only error. `tools/interop_check.sh` with buf 1.74.0 printed 17
  of 17 calls answered, gRPC's trailers among them.
- **Step 6.** buf 1.74.0 ran the plugin over `examples/proto`, and `tools/generate_check.sh`
  printed "examples/gen matches buf generate". `zig build test-generated` compiles the output,
  `large.proto`'s split pieces among it, and `zig build lint` reads it with every rule and reports
  no finding (decision 17).

- **Step 8.** `zig build examples` printed every call answered over h2 and h11 for `eliza` and
  `streaming`, and over h2 for `interceptors` and `errors`. `tools/interop_check.sh` with buf
  1.74.0 printed 35 of 35 calls answered, Chat's full-duplex check among them.

- **Step 9.** `tools/coverage_check.sh` with buf 1.74.0 printed "every coverage case matches
  Go": 14 cases of `coverage.v1.Everything`, 70 checks against Go's runtime, in each direction
  between binary and JSON. It found three faults, now fixed: float's maximum refused, an Any of
  Empty read differently from Go, and map entries and Any bytes not written as Go writes them.

- **Step 6, later.** Each generated service gains `Routes(transport, App, Handlers, options)`,
  whose `routes` list every method for a transport such as `connect_colibri`, and a unary method
  with no side effects as a GET too. Generated code still imports no HTTP library (decision 2).
  `examples/services/eliza.zig` routes ELIZA through it.

- **Step 10.** `zig build examples` printed every call answered over h2, h11 and h3 for `eliza`
  and `streaming`, and over h2 and h3 for `interceptors` and `errors`. Over h3 that is Connect
  POST and GET, gRPC-Web, gRPC's Trailers-Only errors with their details, and the type handlers
  of Chat and Sum. It found one fault, now fixed: a GET's route read its query from colibri's
  head memory after the head's event, and h3 had reused those octets.

- **Step 7, the server half.** `tools/conformance_check.sh` with runner v1.0.4 printed 2714
  of 2714 cases passed (decision 26), once `rpc.Refusals`, a new public name, answers 405 to a
  DELETE (decision 27). The suite found three faults,
  now fixed. A unary request with no message now fails `unimplemented`, as connect-go answers.
  A compressed message with no coding named now fails `internal`, as gRPC's Message-Encoding
  and Connect's Streaming-Request ask. A gRPC error after response headers keeps its own head.
  `connect_colibri` gains `Call.request_headers`, `Call.request_query` and a context's
  `message_receive_limit`. It also gains 16 KiB of trailer room, for details that echo headers.

- **CI across languages and against a baseline.** `tools/interop_languages_check.sh` printed 507
  calls passed: Go's connect-go in five modes and grpc-go, connect-es in five, grpcio and tonic
  (decision 29). It found the example server hanging a connection past its eight sockets, which
  it now accepts and closes, and which `tools/interop_check.sh` checks. `tools/perf_check.sh`
  counts 24 operations (decision 30). CI runs each check of `tools/ci.sh --list` as its own job.

- **Closed enums and unchecked strings.** The plugin resolves `enum_type` and
  `utf8_validation` (decision 23). `proto.EnumDescriptor` gains `closed` and `names`, and
  `proto.Kind` gains `unvalidated_string`. `tools/coverage_check.sh` printed 117 checks passed,
  eight of them binary cases checked against upb 5.29.3. Strings of 32 bytes and longer are
  checked with stdx's vector UTF-8 check, shorter ones with the standard library's.

- **`ClientCall`.** `connect_colibri.Exchange`, `ExchangeWith` and `ExchangeBuffers` become
  `ClientCall`, `ClientCallWith` and `ClientCallBuffers`, so the client's side of a call reads as
  the pair of the server's `Call`. The records above keep the names of their day.

- **The gRPC client.** connect-zig pins colibri `2cf693b1`, whose client holds a response's
  headers and trailers in buffers (colibri decision 152). `connect_colibri.Exchange` reads its
  headers through `Headers.get` and a gRPC status through `Trailers.get`, and
  `ExchangeBuffers` takes `headers` and `trailers` in place of `values`. `wanted_names` leaves
  the root's list. `zig build example-eliza` reads a gRPC unary and server stream over h2, h11
  and h3, and `example-github` reads gRPC errors that follow response headers.

- **A GitHub-style example.** `zig build example-github` runs one session against
  `github.v1.RepositoryService` and `IssueService` over h2 and h3: tokens, a rate limit, pages,
  an update mask, a private repository, a client stream and a server stream.
  `tools/interop_check.sh` calls it with `buf curl` in gRPC and gRPC-Web. It found a fault in
  colibri's h3 client, which panics on a status its enum lacks, such as 429; the rate-limit step
  runs over h2 alone until colibri fixes it.

- **h3 on the socket server.** `tools/interop_check.sh` calls Introduce with `buf curl --http3`
  in Connect, gRPC and gRPC-Web, under the test identity, beside the h2 and h11 calls (decision
  28).

- **Compression, later.** `connect` gains `ZstdEncoder`, `ZstdDecoder` and `Encoders`; the gzip
  `encoder` of `Reply`, `client.Options` and `connect_colibri.Codings` becomes `encoders`,
  `accept`'s `can_compress` becomes `encoders`, and `compression.compress_gzip` becomes
  `compression.compress` (decision 10). `tools/interop_check.sh` reads a zstd answer with curl.

- **colibri v0.14.0 and `colibri.Server`.** Both socket servers run on `colibri.Server`; the
  example server serves h11 and h2 over TLS and h3 under the test identity (decision 31).
  `tools/interop_check.sh` calls it over https and passes; `tools/interop_languages_check.sh`
  runs 507 scenarios across Go, TypeScript, Python and Rust over TLS, all passing.
  `zig build example-github` runs the rate-limit step over h3 too, now that colibri's h3 client
  reads 429. The server set the endpoint's `ecn`, since v0.14.0's server read each datagram's
  ECN codepoint and left the endpoint's flag at false.

- **colibri v0.14.1.** colibri's server sets `ecn` itself, so the example server drops its own.
  The pin moves with colibri's: Rotor v0.9.0 for the examples, chapulin v0.3.0 through colibri.
  `tools/interop_check.sh` passes, h3 calls among them, as do `zig build test`, the 507
  scenarios across languages, conformance 2714/2714 and the perf gate.

- **One generated file per .proto file.** The plugin writes each .proto file as one
  `<file>.pb.zig`, and the file-length rule skips `.pb.zig` (decision 17). `coverage.proto`'s 28
  files become one of 814 lines. `zig build test` passes, and `tools/generate_check.sh` matches.

- **The public API audit.** The owner ruled a TigerStyle-first audit of the public API on
  2026-11-07. `connect` exports the error sets its functions return (`get.Error`,
  `timeout.Error`, `protocol.Error`, `error_json` and `end_stream`'s `EncodeError` and
  `DecodeError`, `trailers.Error`) and `BrotliDecoder`; `protobuf` exports `WireType`.
  `client.read` becomes `client.Response.init`. `Reply.head` takes a `server.Body`, `.plain` or
  `.compressed`, which `Prepared.body()` gives. `Call.set_header` becomes `add_header`, and
  `EnumDescriptor.names` becomes `contains`. `ClientCall(method, options)` replaces
  `ClientCallWith`, with `ClientCallOptions` (decision 19). The Any types are a `[]const type`
  (decision 21). A struct argument past 16 bytes goes by `*const`. `trailers_max` stays.

- **The library runs on any event loop.** The owner ruled on 2026-11-08 that connect-zig's library
  names neither Rotor nor colibri's `colibri` module (decision 32). The `layering` lint rule
  reports a reference to either in `src/`. A `rotor.Loop` and a `colibri.Server` planted in
  `refusal.zig` each failed the lint.

- **pepegrillo 9ae244b and the performance appendix.** connect-zig moves to the pepegrillo commit
  colibri pins, whose API follows its 2026-11-07 audit: `lint.Scope` replaces `lint.scope.Scope`,
  and no lint verdict changes. `zig build guide` installs pepegrillo's performance method, and
  `docs/performance.md` holds connect-zig's appendix to it. `zig build lint` and the commit lint
  pass.

- **colibri v0.15.0 and stdx 0c0ba95.** connect-zig pins colibri v0.15.0 (`de74e9c5`) and the
  stdx commit it pins, so the build holds one stdx. colibri's step 45 renames reach the programs:
  `server.Router(App, table, options)`, `server.Engine(.{})` with an `Instant`,
  `client.ConnectionPool(.{})`, and `http.Status` as an enum. `connect` keeps the status as a
  number, and `connect_colibri` converts it at colibri's edge. stdx's decoders take methods, and
  `json.Item` is `json.TextReader.Item`. Every check passes, and no instruction count moved:
  `zig build test`, conformance 2714/2714, the 507 scenarios across languages, coverage and
  interop. Colibri's client tries TCP first now; the h3 rounds offer h3 alone and check the
  protocol they spoke, so they still run h3.

- **The protobuf fast paths.** The owner approved an audit's nine fixes on 2026-11-08. Four
  benchmark messages that each hold one kind of field joined the four of `bench/inputs.zig`, and
  stdx builds ReleaseFast in the benchmark. A proof harness compares each fast path with a
  reference that steps one octet at a time. The fixes then landed one commit each: repeated items
  encode from their slice, a child's length is guessed at 2 octets, short strings are checked for
  ASCII a word at a time, base64 tries the standard alphabet first, a `Lazy` child encodes
  through its pointer, varints of one and two octets are written and read inline, the next packed
  element is read inline, and a JSON member's name is matched against comptime names. Per
  operation, from the first baseline to the last: large binary encode 2,161,408 to 901,289
  instructions (-58.30%), large binary decode 1,213,474 to 786,889 (-35.15%), deep binary encode
  21,511 to 13,548 (-37.02%), small binary decode 738 to 525 (-28.86%), large JSON decode
  13,135,358 to 10,832,454 (-17.53%). JSON encode moved by +0.81% at most. `zig build test`,
  `tools/coverage_check.sh` and `tools/bench_check.sh` pass.

- **Client-side full-duplex.** The owner approved on 2026-11-09 the first of three client
  commits: a streamed `ClientCall` over colibri v0.15.0's pieces (colibri decision 153; decision
  18 as amended). New public names:
  - `connect_colibri`: `ClientSendError` and `full_duplex` at the root; `ClientCall`'s
    `init_stream`, `start`, `sender`, `Sender` with `send` and `close_send`, `on_headers`,
    `on_body` and `on_body_taken`, and its fields `id` and `reader`; `ClientCallOptions.pool`;
    `ClientCallBuffers.piece`.
  - `connect`: `client.write_message`; `client.Response.feed` and `end_body`;
    `client.Incoming.streamed`.

  No existing name changed. `zig build example-streaming` gains a streamed round over each of
  h2, h11 and h3. Chat runs in Connect, gRPC and gRPC-Web: over h2 and h3 each answer arrives
  before the next line goes, and over h11 every line goes first. Sum hands each number as a
  piece of its own.
  `zig build test`, `zig build -Drelease`, `tools/generate_check.sh` and `tools/perf_check.sh`
  pass, with no instruction count moved. `tools/interop_check.sh` printed 48 calls answered,
  conformance 2714 of 2714, and `tools/interop_languages_check.sh` 507 calls passed.

- **Step 7, the client half.** `tools/conformance_check.sh` runs runner v1.0.4 in client mode
  against `zig build conformance-client` (decision 26 as amended): 8264 cases in Connect, gRPC and
  gRPC-Web, over h11, h2 and h3, in cleartext and over TLS, proto and JSON, identity, gzip and
  zstd, every stream type, Connect GET, timeouts, cancels and the 1 MiB receive limit. 7349
  pass, and the rest fail on purpose, listed with their reasons in
  `conformance/client_known_failing.txt` and `client_known_flaky.txt`. The server still passes
  2714 of 2714. The suite found these faults in `connect`'s client, now fixed:
  - a program could add 8 headers, and the runner sends 9; `extra_headers_max` is 16;
  - a compressed end-stream message, trailers frame or Connect error body was read compressed;
  - an error body's null, missing or unknown code read `unknown`, not the HTTP status's code,
    and an end-stream's `"error": null` failed the stream;
  - a message past the client's receive limit failed `internal`, not `resource_exhausted`, and a
    Connect unary body was not bounded at all;
  - a 200 response of another media type or codec was read as the protocol's;
  - a head's `grpc-status` counted even when a body or trailers followed it.

- **ELIZA over `std.Io`, with no Rotor.** The owner ruled on 2026-11-09 that it lands before
  v0.1.0, to prove decision 32. `examples/std_io_server.zig` drives colibri's `server.Engine` over
  Zig 0.16's `std.Io`: one task owns the engine, and an acceptor, a reader for each socket and a
  50 ms ticker send it messages through one bounded `std.Io.Queue`. It serves h11 and h2 in
  cleartext, with no TLS and no h3. `examples/std_io.zig` starts it on port 0 and drives a
  `client.ConnectionPool` over a `std.Io` TCP socket. No public name changed. Check: `zig build
  example-std-io`, which `zig build examples` runs, answers six calls over h2 and over h11, and
  sees an idle socket close at the first-request deadline. `zig build test` printed 80 of 80
  steps and 183 of 183 tests passed; `zig build -Drelease` and `tools/interop_check.sh`, 48 calls,
  pass.

- **The client against servers in other languages.** The owner approved on 2026-11-09 the third
  of three client commits, the mirror of decision 29: connect-zig's client calls servers in other
  languages, across the protocol and every type (decision 29 as amended). `interop/` gains a
  server beside each client: connect-go and grpc-go, connect-node, grpcio, and a serve mode of
  connect-rust, each over TLS with the test identity. `examples/interop_client.zig`, which `zig
  build interop-client` builds, drives one pool per run with the conformance client's transport
  (decision 32). No public name changed. Check: `tools/interop_servers_check.sh`, which
  `tools/ci.sh` runs as `interop-servers`, printed 782 calls passed: 238 against connect-go, 33
  against grpc-go, 238 against connect-node, 33 against grpcio and 240 against connect-rust.
  connect-go and connect-node answer chat over HTTP/1.1 with 505, so the client leaves it out
  there. `zig build test` printed 86 of 86 steps and 212 of 212 tests passed;
  `tools/interop_languages_check.sh` still prints 713 calls passed, and `tools/interop_check.sh`
  passes.

- **Compress when asked.** The owner ruled on 2026-11-09 that a client compresses each request
  message in the coding it asked for, as connect-go does (decision 22 as amended).
  `connect.client.Options` gains `compress_len_min`, default 0; no name changed. A server's
  replies keep their floor of 1 KiB. Conformance's client half printed 8204 of 8264 passed, the
  rest known failing: the 855 cases of a Connect unary request in gzip or zstd now pass. The
  server passes 2714 of 2714, `tools/interop_check.sh` 48 calls,
  `tools/interop_languages_check.sh` 713, and no instruction count moved, since no benchmark
  compresses.

- **Response cardinality.** The owner ruled on 2026-11-09 that a client checks the count of a
  unary or client-stream response's messages. `connect.Speaks` gains the field
  `stream_type: ?StreamType = null`, which `client.request` sets from the method, and
  `client.Response.next` then fails a second message, or a success with none, `unimplemented`:
  gRPC's statuscodes.md names a response cardinality violation so, at the client, and connect-go
  reads it the same way. An error with no message keeps its own code. No name changed; a
  server's `Speaks` leaves the field null. Conformance's client half printed 8252 of 8264
  passed, 48 more; the 12 left are known failing. The server passes 2714 of 2714,
  `tools/interop_check.sh` 48 calls, `tools/interop_languages_check.sh` 713, and no instruction
  count moved.

- **Lowercase header names in the library.** The owner ruled on 2026-11-09 that
  `connect_colibri`'s `ClientCall.init` writes each request header name in lowercase, as h2 and
  h3 carry it (RFC 9113 §8.2.1, RFC 9114 §4.2), so a program's own names and its interceptors'
  may take any case. A name with an uppercase letter goes into `ClientCall.names`, a new field of
  `constants.client_header_name_bytes`, 1 KiB, and no allocator; a lowercase one is used as it
  is. The conformance client's copy goes. Conformance's client half still printed 8252 of 8264
  passed, the server 2714 of 2714, `tools/interop_check.sh` 48 calls and
  `tools/interop_languages_check.sh` 713, and no instruction count moved.

- **The lint reads `conformance/`.** The owner ruled on 2026-11-09 that the conformance programs
  keep the tree's rules. `build/lint.zig` scores `conformance/` and passes it to the rules, which
  read it as `examples/`, and `conformance/gen` as `examples/gen`. denied-words skips
  `conformance/proto`, connectrpc's copy. Its findings are fixed: `echo.zig`'s `add_each`
  (complexity 21) and `unary.zig`'s `server_stream` (18) are split, and the local buffers the
  undefined-fill rule names move to the container, or are written whole. No public name changed.
  Conformance printed 2714 of 2714 and 8252 of 8264, `tools/interop_servers_check.sh` 782 calls,
  `tools/interop_check.sh` 48 and `tools/interop_languages_check.sh` 713, and no instruction count
  moved.

- **JSON integers as the mapping reads them.** The owner ruled on 2026-11-09 that
  `json_scalar.parse_integer` refuses what the proto3 JSON mapping and Go's protojson refuse. Its
  general path read a string's text with the standard library's parsers, which took "+1",
  "1_000", "0x10" and "007". It now takes a JSON number alone (RFC 8259 §6), in a string or not,
  and reads its digits exactly once the exponent moves the point, as Go does: "1e2", "1.0",
  "10e-1" and "-0" are integers, and "9.223372036854775807e18" is maxInt(i64), which the old path
  rounded through an f64 to 2^63 and refused. The fast path refuses a leading zero, and the proof
  harness's reference follows the new rules with code of its own. Go 1.24 with protobuf v1.36.12
  gave each verdict. No public name changed. `tools/coverage_check.sh` printed 123 checks passed,
  with the case `coverage/integer_forms`, which the clients of `interop/` echo too:
  `tools/interop_languages_check.sh` prints 758 calls passed and `tools/interop_servers_check.sh`
  831. Conformance printed 2714 of 2714 and 8252 of 8264. The general path stays out of line; the
  varints JSON decode takes 1.39% more instructions, inside the gate, so the baseline stays.

- **colibri v0.15.1.** colibri's client hands a response's status through when it is three
  digits, whatever its value (colibri's ruling on RFC 9110 §15), so a status of 800 reaches
  connect-zig, which maps it to unknown (Connect protocol, "HTTP to Error Code"). The 12
  `nonexistent-http-status-code` cases leave `conformance/client_known_failing.txt`, which is
  empty now. Conformance printed 2714 of 2714 and 8263 of 8264, the last a flaky timing case.

- **Long streams.** The owner ruled on 2026-11-09 that a long stream's handler gives one
  message at a time, for server and bidirectional streams (decision 33). New public name:
  `Next`. `connect.server.Reply` gains `envelope_of` and `ending`, and writes each envelope and
  each stream's end as one slice. A route with `next` declares colibri's `on_writable`, holds
  one envelope that found no room, and builds the stream's end once. connect-zig pins colibri
  v0.15.2 (`a2bda1e`) and the stdx commit it pins, `57a7040`, so the build holds one stdx
  (decision 10).
  - `zig build test-connect-colibri` runs 22 tests of a route with `next` through colibri's
    router and an engine each test controls: 200 notes through 256 octets of response memory,
    over an engine that copies each run and over one that holds each run until its
    acknowledgment. A sweep of 40 stream lengths makes the stream's end find the memory full.
  - colibri's `end` and `trailers` return `error.Full` or `error.NoSpaceLeft` and leave the
    response as it was. The route then returns from `on_writable` and makes the call again at
    the next one, as colibri's usage guide states for v0.15.2. A test of this route found the
    `error.Full` case on colibri's branch, before the tag.
  - The demo's Countdown is a handler with `next`. `zig build examples` runs it over h2, h11 and
    h3 in memory, and `tools/interop_check.sh` reads a Countdown from 200000 with buf curl:
    about 1.6 MiB through 64 KiB of response memory, in Connect, gRPC and gRPC-Web over h2, and
    in gRPC over h3.

- **base64 from stdx.** The owner approved on 2026-11-10 the move from `std.base64` to stdx's
  `base64` module, which colibri v0.15.2's stdx commit `57a7040` holds (decision 10 as
  amended). The `protobuf` and `connect` modules import it, and so does the benchmark's copy of
  `protobuf`. Each base64 value goes through one encoder or decoder, and a long one through one
  encoder in pieces of 60 letters, which the `undefined-fill` rule keeps under a cache line.
  - A sweep compares stdx's decoder with `std.base64`, the reference of
    `protobuf_fast_path_test.zig`, over every text of up to four letters and each letter at each
    place of longer text. Both accept and refuse the same texts and give the same octets.
  - Connect's error details and gRPC's "-bin" values now refuse a text whose pad characters do
    not complete a quantum, such as `/w=`, and a URL-safe letter, as before.
  - Mutations, 17, each CAUGHT, on the alphabet, the padding, the room and the input of each
    encoder and decoder.
  - The judge, CI's `perf` job: large JSON decode -7.19% instructions, large decode+walk -5.95%,
    large JSON encode -0.80%. No other operation moved.

- **JSON encode reads a repeated or lazy field in place.** A profile of the tree message's JSON
  encode, on stdx `8eefa96`, put about 73% of its time in stdx's `TextWriter`: about 2.3 ns for
  each brace or bracket, and 7.4 ns for each name. connect-zig's own 27% was a copy of each
  node's repeated field, and a recursive frame that held the iterator a program's message never
  uses. `write_fields` now passes a repeated or lazy field by pointer, and the iterator's loops
  run out of line. On x86-64-v3 the tree's recursive frame shrinks from 168 to 96 octets.
  - The judge: tree JSON encode -1.28% instructions; no other operation moved past 0.05%.
  - A new test writes JSON for a message decoded from binary, with an array and a map.
  - stdx's session takes the rest to the owner: a cheaper step for a brace or a bracket, and a
    name call for octets that need no escape.

- **colibri v0.16.0.** connect-zig pins colibri v0.16.0 (`b6049724`), and the stdx (`1d1b46f8`)
  and Rotor v0.10.0 (`93398588`) it pins, so the build holds one copy of each (decision 10). The
  library's API does not change; the programs do:
  - `colibri.Server(capacity, .private)` replaces `ServerOf`, and takes the router in `init`.
    `.private` runs on Rotor, so `build.zig` passes `.rotor = true` to colibri only when
    connect-zig is the root build, as it asks for Rotor itself (decision 32).
  - `ServerConfig.unix_seconds`, which colibri's TLS session tickets carry, and `engine` for
    `endpoint`. `server.Instant` is `server.Timestamp`. The pool and Rotor's loop take their
    options by pointer.
  - `std_io_server` shuts a socket's write side at the engine's `half_close` (colibri decision
    160), and keeps reading.
  - colibri's h11 server now reads, or closes in stages, a body it answered early, so the
    conformance server's unexpected-verb case leaves `conformance/known_flaky.txt`.

- **colibri v0.16.1.** connect-zig pins colibri v0.16.1 (`14ae68a9`) and the stdx it pins
  (`89a021c3`). chapulin v0.5.0 and Rotor v0.10.0 stay, and colibri's API does not change. The
  owner ruled on 2026-11-11 that v0.1.0 ships on this stdx.
  - A bytes field's JSON goes through stdx's `TextWriter.base64` (stdx decision 73), which
    writes the letters straight into the text. The loop of 60-letter pieces leaves
    `json_scalar.zig`. Connect's error details keep their loop: they are unpadded, and the new
    call pads.
  - stdx's reader returns a string with no escape as a slice of its input (stdx decision 74).
    connect-zig's readers do not change.
  - Mutations, 2, each CAUGHT: a bytes field written as hexadecimal, and as a plain string.
  - The judge, CI's `perf` job on `ce62759`: JSON encode takes 42% to 70% fewer instructions on
    each of the eight messages, and JSON decode 12% to 22% fewer. No binary operation moved.
    `bench/instructions.txt` holds the new counts.
  - CI's `bench-compare` job, run 86: connect-zig's JSON decode is faster than Buffa's on 7 of
    8 messages, and its JSON encode on 5 of 8. The tree message's JSON encode still takes about
    three times Buffa's time. The README's tables and chart come from this run.

- **The package builds for a project that fetches it.** `build.zig` imports the helpers of
  `build/`, and `.paths` of `build.zig.zon` did not name that folder. `zig fetch` keeps only the
  files the list names, so a project that depended on connect-zig by URL could not compile its
  build script. No check saw it: each one built the whole tree.
  - `.paths` names `build`.
  - `tools/package_check.sh`, the `package` check of `tools/ci.sh`, packs the tracked files,
    fetches them into a new project, and builds it. The project imports `protobuf`, `connect`
    and `connect_colibri`, and installs the plugin.
  - Mutation, 1, CAUGHT: with `build` out of `.paths`, the check fails with
    "unable to load 'lint.zig'".

- **The `oidc` module** (step 11, decision 34). The owner ruled on 2026-11-11 that it ships in
  v0.1.0, and named its two option types `VerifierOptions` and `InterceptorOptions`. A `Verifier`
  checks a JWT bearer token with chapulin's `jws` calls, at chapulin's main (`17fd1f0b`) with
  `JWS=on`, and `Interceptor` refuses a call with no valid token.
  - Files: `token.zig` splits a token and reads its header, `jwks.zig` reads a JWK Set into the
    key forms chapulin takes, `claims.zig` reads the claims, `verifier.zig` orders the checks,
    and `interceptor.zig` holds the interceptor and `bearer_token`. `reader.zig` is stdx's JSON
    decoder with one difference from `json.TextReader`: a string longer than its storage is an
    item, not an error, so a JWK Set with a certificate chain reads.
  - Known answers: RFC 7515 appendix A.2 (RS256) and A.3 (ES256), and RFC 8037 appendix A.4
    (EdDSA), each through `Verifier.verify` under the RFC's key. `tools/oidc_vectors.py` signs
    RS256 tokens with OpenSSL under keys of 1024, 2048 and 4096 bits; the verifier does not keep
    the first. The tests sign ES256 and EdDSA tokens with Zig's standard library, so each
    signature chapulin checks comes from another implementation.
  - Tests, 46, for each refusal: the form, the header, the key a header names, the
    signature, the issuer, the audience, "exp" and "nbf" with the leeway at each side of its
    bound, each rule of a JWK, the paths the interceptor excludes and its challenge.
  - Mutations, 103, each CAUGHT by a test, on each check of the six files. Five more only
    stopped the compiler, and each has a form among the 103 that compiles.
  - One `verify` took about 32 µs with RS256 under a 2048-bit key, 41 µs with ES256, 88 µs with
    EdDSA, and 153 µs with RS256 under a 4096-bit key. That is ReleaseSafe on an arm64 Mac that
    ran other builds, so each number is an upper bound there.
  - `oidc` links chapulin's main, and colibri v0.16.1 links chapulin v0.5.0. So no program links
    `oidc` beside a colibri module yet, and the module's tests give the interceptor a call type
    of their own.

- **A request context for each call** (step 12, decision 35). The owner asked how a handler
  reads the claims, and chose on 2026-11-11 a typed value on the route over a `State` for each
  interceptor and over a generic `Call`. The owner then named it `RequestContext`, over `Local`
  and `Locals`. Step 13 renamed it `Values`, read with `ctx.values`, and ended the hook's extra
  parameter; this record keeps the names of its day.
  - `RouteOptions.RequestContext` is a struct whose fields each have a default. Each call's
    state holds one, and colibri sets that state to its defaults at each request, so each call
    starts with `.{}`. `Call.request_context(T)` returns it, after an assertion compares `T`'s
    name with the route's.
  - An interceptor's `on_call` or `on_finish` takes the request context when it declares one
    more parameter. The chain counts a hook's parameters at compile time. A hook with two, or three
    for `on_finish`, runs as before.
  - `oidc.Claims` owns a copy of the subject and of the payload, and room for a lookup's
    string: about 4.4 KB, 1.3% of a call's 326 KB with the default sizes. `verify(token,
    *Claims)` writes into it, and empties it after a refusal. The interceptor verifies into
    `request_context.oidc`, and leaves it null on an excluded path or a refusal.
  - `Claims.string`, `integer` and `holds` read one member of the payload when asked, and the
    last of a name that appears twice (RFC 7519 §4). stdx's typed decoder refuses the members
    a struct does not name, which every token holds, so a struct of claims would need a walker
    of its own.
  - Tests: two bidirectional streams interleave through colibri's router, and each of six
    callbacks reads its own call's value; each entry of the router serves two calls, and each
    starts with the defaults; a function handler reads the value its interceptor wrote. In
    `oidc`: two calls keep their own claims beside a refused third, and each lookup, its
    types, its bounds and its duplicates.
  - Mutations, 29, each CAUGHT by a test: the hooks with and without the request context, the
    pointer and the type check of `Call.request_context`, each lookup's types, bounds and
    duplicates,
    the claims `verify` writes and empties, and the interceptor's clears. A test that puts the
    value only in a nested array came from the one a first run did not catch.

- **A handler takes ctx, request and response** (step 13, decision 36). The owner found the
  split of connect-go cleaner than one object for the call, and approved each signature by
  card on 2026-11-11. `Call`, `Sender` and `Receiver` go from the root.
  - `context.zig` holds the views: `Context`, `AnyRequest`, `AnyResponse`, `Request(T)`,
    `RequestStream(T)`, `Response(T)` and `ResponseStream(T)`. Each holds a pointer to the
    call the route keeps, which `call.zig` still writes, so no write path changed.
  - The per-call values of step 12 move to `ctx.values(T)`, and `RouteOptions.RequestContext`
    becomes `RouteOptions.Values`. A hook takes no extra parameter for them: a library's
    interceptor names the program's type, as `oidc.Interceptor(Values, options)` does.
  - One change from the approved cards: a stream's `on_end` takes the request with no
    message too, `(app, ctx, state, request, response)`. The conformance server echoes the
    request headers at a client stream's end, one with no message among them, and connect-go
    keeps the request headers readable to the end as well.
  - The examples, the conformance server and the tests move to the new signatures. The
    conformance helpers take the context, the request or the response each needs, no longer
    the whole call.
  - `context_test.zig` drives a unary call, a GET, a client stream, a server stream and a type
    handler's `on_end` through colibri's router. Its engine keeps each response header and
    trailer, so each view's reads and writes are checked where the client would see them.
  - Mutations, 24, each CAUGHT by a test: each member of each view, the counts, and the
    outcome `on_finish` sees. A test of the response stream's headers and trailers came from
    the two a first run did not catch. One more gave a hook a second view of the same call,
    which behaves the same, so it is no mutation and is not counted.

- **Binary encode counts or writes, chosen at compile time.** Buffa led binary encode on 7 of
  8 messages. A profile of Small's encode, and then its disassembly, showed why each field cost
  about 65 instructions: the encoder's `Sink` tested at run time whether it wrote, and kept a
  count of the octets while it wrote them. `Sink` now takes its mode at compile time (commit
  `c416354`), so the compiler builds each message's walk once to count and once to write.
  - The judge, CI's `perf` job on `c416354`: binary encode takes 33.24% fewer instructions on
    strings, 28.27% on small, 21.13% on deep, 16.96% on large, 16.25% on varints, 15.09% on
    medium, 3.02% on tree and 0.30% on packed. No other operation moved past 0.03%.
    `bench/instructions.txt` holds the new counts.
  - A second change followed from the same disassembly (commit `764ee37`). Each scalar field
    built its tag at run time: the wire type went to a stack slot and came back before it
    joined the field's number. `Sink.tag` now takes both at compile time, and writes one
    constant varint. The judge on `764ee37`: binary encode takes 5.11% fewer instructions on
    small, 3.86% on strings, 3.55% on varints, 3.37% on large, 3.28% on deep and 3.00% on
    medium; tree did not move. From the baseline before both changes, small went from 382
    to 260 instructions, and strings from 1125 to 722. Mutations, 5 on the two tag paths, each
    CAUGHT.
  - CI's `bench-compare` of that run, on an EPYC 7763: connect-zig's binary encode is faster
    than Buffa's on small, deep, varints, tree and packed, and slower on medium, large and
    strings. The README's tables came from another machine, an EPYC 9V74, so one later run
    refreshed each cell: run 97, on `52fc27a` and an EPYC 7763. Buffa is faster in 6 of the
    README's 16 cells there, and was in 7 in run 86. The three runs of that day ran on three
    CPUs, and Buffa's ratios moved with each, so the README names its run's machine.
  - A trial that copied a string of up to 32 octets with two loads and no call did not pay on
    a local counter: 1.6% fewer instructions on strings, 3.7% more on deep. It was dropped.
  - Mutations, 7, each CAUGHT: each count of the counting walk, the write of a value, and the
    restore of the writer when a child's length guess fails.
- **`oidc` beside `connect_colibri`, on colibri v0.16.2.** connect-zig pins colibri v0.16.2
  (`03d56223`); stdx `89a021c3` and Rotor v0.10.0 stay. colibri v0.16.2 pins chapulin v0.6.0
  (`17fd1f0b`), the commit connect-zig already pinned, and its request for chapulin's
  TCP object now holds `JWS=on` and `SCRAM=on` (colibri decision 162). `build/chapulin.zig`
  copies that request key for key, so a program links one chapulin object.
  - `examples/oidc.zig` runs a client against `services/account.zig`, a generated `Routes`
    behind `oidc.Interceptor`, over h2 and h3. Status answers with no token, since its path is
    excluded. Whoami is refused with no token, an expired one and one for another audience, each
    with RFC 6750's challenge, and answers a valid token with its subject, email and role.
    `services/issuer.zig` stands where the provider would be. It changes its key between the
    rounds: the verifier refuses the new key's token, reports its keys stale, takes the new
    JWK Set, and then takes the same token.
  - This is the first program that compiles `oidc.Interceptor` against `rpc.Context`,
    `rpc.AnyRequest` and `rpc.AnyResponse`. Until now two chapulin objects kept `oidc` and
    `connect_colibri` out of one binary, and the interceptor's tests used views of their own.
  - `tools/package_check.sh` imports `oidc` beside `connect_colibri` in the fetched project,
    and calls `Verifier.init`. `tools/interop_check.sh` reads Status and Whoami's refusals
    from the socket server with curl and `buf curl`: 401 with the challenge in Connect, and
    `unauthenticated` in gRPC and gRPC-Web.
  - The example server's `App` holds the verifier, and each server starts it before it takes
    a call. `build/examples.zig` builds the servers on a host target alone, where `oidc` exists.
  - Mutations, 6, each CAUGHT. The request without `SCRAM=on`, and with `KEYLOG=on`: the link
    fails with "duplicate symbol definition". No excluded path, no challenge header, claims
    dropped after a valid token, and a lookup of a string before another lookup: the example
    fails.

- **Medium binary against Buffa** (steps 14 and 15, decision 37). The owner wrote on
  2026-11-13 "we need to beat buffa on binary encoding and decoding for medium size docs".
  - Encode, commit `69595b7`: a flat child, with no message and no repeated field, is
    measured before it is written, and no longer moves. The judge on `69595b7`: medium binary
    encode takes 6.21% fewer instructions, and no other operation moved past 0.1%.
  - Decode, commit `e491ebc`: `decode_into`, which the benchmark takes before its binary
    walk. The judge on `e491ebc`: binary decode+walk takes fewer instructions on medium
    (41.32%), deep (38.75%), large (33.53%), packed (21.17%) and tree (18.26%). Two counts
    rose past 2%. Medium binary decode took 4.72% more, because the benchmark now calls
    `decode` from fewer places; with the old calls the library counted the same, on an M1.
    Tree's JSON decode+walk took 2.51% more, from the iterator's inline items check.
  - CI's `bench-compare` on `e491ebc` ([run 43441672466](https://github.com/c4milo/connect-zig/actions/runs/43441672466)),
    an EPYC 9V45. Buffa's time over connect-zig's, medium: decode+walk 1.06, from 0.78 in run
    97; decode 1.22; encode 0.74. Decode+walk elsewhere: large 1.18, deep 1.21, tree 0.73,
    packed 0.64. Buffa still leads binary encode on medium, deep, tree and packed.
  - Each fast path, switched off, counted under callgrind in an x86-64 container on the
    owner's Mac, built for x86-64-v2: the flat child, medium binary encode +7.35%; the inline
    items check, binary decode+walk +86.22% on packed, +26.59% on large, +22.66% on medium
    and +8.35% on tree, with tree's JSON decode+walk 3.18% lower.
  - Tries that lost, each dropped: varints of three to eight octets read and written as one
    word, which took 11% to 15% more cycles to decode on an M1; a copy of short strings with
    no call, which took small 22% more cycles; a packed record's varints written in room
    checked once, 6% more instructions on large and packed; a long varint written with no
    length first, on x86-64 2.78% more on medium and 22.44% more on varints.
  - `bench/instructions.txt` holds the judge's counts of `e491ebc`, which `1fac7e6` repeats.
  - Encode on x86, commits `34558ab` and `d648336`. On x86-64 under callgrind, Buffa ran
    14,432 instructions for medium binary encode and connect-zig 12,173, yet connect-zig took
    16% to 26% longer on CI's x86 runners. Its writer lived in memory: `varint_long` took the
    writer's address, so each write stored the length and the next loaded it. An M1 hides that
    wait, and its cycles had put connect-zig ahead. `varint_long` now takes the buffer and the
    position by value, and the writer's small calls are inline. `varint_len` also divides by 7
    with a multiply and a shift.
  - Both, measured on a branch before they landed, with the owner's word. [Run
    43472841911](https://github.com/c4milo/connect-zig/actions/runs/43472841911) ran on a Xeon
    8573C, the CPU of `69595b7`'s run: medium binary encode went from 771 to 683 ns, against
    Buffa's 646 ns, so Buffa's time over connect-zig's went from 0.84 to 0.94. It read 1.03 on
    a Xeon 6975P-C in the run before. The judge: binary encode takes fewer instructions on
    varints (22.52%), packed (15.95%), small (12.69%), strings (9.70%) and medium (7.27%), and
    more on large (2.00%) and deep (1.38%). Large's count is the price of the inline writer:
    its packed loop calls no function now, and its walk takes more instructions to set up.
  - Tries that lost on x86-64-v2: the reader's `varint_long` by value, 20% to 44% more
    instructions to decode, since its two-part result came back through memory; and a flat
    child written once behind a one-octet length, 2.8% more on medium.
  - Varints and the iterator, commits `9e5ce7a`, `b63de14` and `214d579`. A packed record's
    varints are read with the position in a local, so no element waits for a stored position.
    Binary encode writes a varint of three or four octets inline, as samples, counts and ids
    are. A field's stored items answer their end with no call.
  - JSON encode, commit `b636a88`. The owner wrote on 2026-11-13 "we also need to win on json
    encode speed over Buffa". The encoder calls each method of stdx's `TextWriter` inline, and
    stdx did not change.
  - The judge on `b63de14`, [run 43604260449](https://github.com/c4milo/connect-zig/actions/runs/43604260449),
    against the baseline before the four commits. Binary encode takes fewer instructions on
    medium (21.54%), varints (10.24%), large (4.79%), small (3.96%) and packed (2.43%). Binary
    decode+walk takes fewer on packed (32.86%), medium (13.89%), large (8.14%) and tree
    (1.35%). JSON encode takes fewer on deep (23.10%), small (20.13%), varints (17.86%), tree
    (16.47%), strings (15.43%), large (9.68%) and medium (6.00%). The largest rise is 0.95%,
    on deep binary encode. `bench/instructions.txt` holds these counts.
  - The same run's `bench-compare`, on an EPYC 7763, the CPU of run 97. Buffa's time over
    connect-zig's, from run 97 to this run: medium binary encode 0.86 to 1.16, medium
    decode+walk 0.78 to 1.46, and packed decode+walk 0.62 to 1.19. JSON encode: small 0.83 to
    0.87, deep 0.76 to 0.84, and strings 0.88 to 0.92. Buffa still leads JSON encode on those
    three, on tree (0.47) and on packed (0.96).
  - Two times rose on x86 while their instructions fell, and an M1 shows neither. Large
    binary encode took 73.2 µs on `b636a88` and 81.5 µs on `b63de14`, on the same CPU, with
    4.79% fewer instructions. Tree's binary decode+walk took 9.6 µs in run 97, before
    `decode_into`, and 13.8 µs in this run, with 19.36% fewer instructions. Both causes are
    open.
  - The x86 lab, with the owner's word: a branch whose one CI job builds the benchmark of the
    tree and of the tree with each of a set of patches, runs each three times on that one
    runner, and prints each operation's lowest time. [Run
    43607446083](https://github.com/c4milo/connect-zig/actions/runs/43607446083) ran on an EPYC
    9V45. It never lands.
  - The writer's length stored once. Each inline write did `writer.len += n` after it stored
    octets through the buffer. A store through `[]u8` may be the length itself, so the
    compiler read the length again from memory, and each write waited for the one before it.
    The out-of-line `varint_long` returned the length in a register, so the inline paths of
    three and four octets were the slower ones on x86. Each write now reads the length once,
    stores its octets, and stores the length. In the lab, medium binary encode went from 416
    to 347 ns; no other encode moved past 4%. Mutations, 13, each CAUGHT, after a new test of
    the room a fixed-width value needs.
  - A run's next tag read with no copy of the reader. To learn whether a run of records went
    on, `decode_into` copied the reader, read a tag from the copy, and copied it back: two
    copies through memory at each record. It reads the tag in place now, and moves the
    position back when the tag is another field's. In the lab, binary decode+walk took 10.8%
    less time on medium and 9.0% less on large, with 0.53% fewer instructions on medium.
    Mutations, 5, each CAUGHT.
  - The lab also placed tree's cost: `decode_into` alone took 3.66 µs and the walk 4.69 µs. A
    walk that read the stored nodes in place took 1.74 µs: the iterator's `next` returns each
    56-octet node by value, and the walk copies it three times. Large binary encode showed no
    loss there: the wide varint path was 4.5% faster than the path before it on that CPU.
  - The judge and the times of both fixes, on `c3ad49d`, [run
    43609978018](https://github.com/c4milo/connect-zig/actions/runs/43609978018). No count
    moved past 2%: deep binary encode takes 1.88% more instructions and packed binary
    decode+walk 1.71% more, and tree's binary decode+walk takes 1.76% fewer.
    `bench/instructions.txt` holds these counts. `bench-compare` runs on an arm64 runner too
    since `d44aa02` (decision 16), a Neoverse-N2. There, from the run before to this run,
    binary encode went from 680 to 575 ns on medium and from 51.2 to 43.3 µs on large, and
    medium's decode+walk from 877 to 808 ns. On a Xeon 8573C, Buffa's time over connect-zig's
    is above 1 in each of the README's 16 cells: binary encode reads 1.44 on medium and 1.33
    on large, where the same CPU read 1.32 and 1.10 before the fixes. So the loss on large
    binary encode was the length read again from memory.
  - A run of messages counted with no call. Before `decode_into` reads a run of messages
    that hold runs of their own, it counts the run's records, and the count called
    `Reader.skip` for each one. A message's record is length-delimited, so the count reads
    that length itself, and calls `skip` for a group alone. The lab's second round, [run
    43613206326](https://github.com/c4milo/connect-zig/actions/runs/43613206326), ran on an
    EPYC 9V74 and on a Neoverse-N2: tree's binary decode+walk took 21.5% and 9.1% less time,
    and large's 5.1% and 2.7% less. On x86-64-v2, tree takes 10.22% fewer instructions.
    Mutations, 3, each CAUGHT, after a new test of a counted run of groups.
  - Messages in place (step 16), ruled by the owner on 2026-11-14. The first round of the lab
    placed tree's cost in the walk: `next` returned a 56-octet node by value, and the walk
    copied it three times. `next` now gives a message as a pointer into `items`, or into the
    iterator's slot for a message of a view, and answers the end of a view with no call. The
    benchmark's walk reads each field of messages so, as Go's reads a slice of pointers and
    Buffa's a vector by reference. The lab's second round timed this as a second method,
    `next_ptr`, which the owner then folded into `next`. With the run counted with no call,
    binary decode+walk took less time on tree, 55.5% on the EPYC 9V74 and 45.6% on the
    Neoverse-N2, and on large, 27.5% and 15.1%; medium moved less than 5%. On x86-64-v2, the
    change alone takes 21.33% fewer instructions on tree and 3.93% fewer on large. The
    encoders, the plugin and the conformance server read messages through the pointer; the
    plugin copies a descriptor where it keeps one. Mutations, 7, each CAUGHT.
  - The judge and the times of both, on `989d740`, [run
    43622491626](https://github.com/c4milo/connect-zig/actions/runs/43622491626). Binary
    decode+walk takes 26.88% fewer instructions on tree and 5.80% fewer on large, and tree's
    JSON decode+walk 4.12% fewer; no count rose past 0.5%. `bench/instructions.txt` holds
    these counts. Buffa's time over connect-zig's for tree's binary decode+walk reads 1.79 on
    a Xeon 6975P-C and 2.01 on the Neoverse-N2, where run 116 read 0.85 and 1.10; large's
    reads 1.50 and 1.63.
  - JSON on arm64. The owner asked on 2026-11-14 whether connect-zig beat Buffa on arm64 as on
    x86-64: binary yes, JSON less, with Buffa faster on 14 of 48 rows on the Neoverse-N2 of run
    119 against 9 of 48 on x86-64. A local counter, callgrind in a linux/arm64 container on the
    owner's Mac, counted both runtimes. JSON encode runs fewer instructions than Buffa on every
    message but tree, so its loss there is in cycles, which callgrind does not show; stdx's
    session measured TextWriter at 4.3 instructions a cycle on an N2. JSON decode ran 13% to
    32% more instructions than Buffa on small, varints, tree and packed.
  - JSON decode reads the transcoder's binary one level (decision 9, amended). On x86-64-v2 it
    takes fewer instructions on tree (23.26%), deep (17.07%), large (13.94%) and medium
    (8.20%), and on arm64 alike; the largest rise is 0.36%, packed. Tree's JSON decode on arm64
    now runs 0.91 of Buffa's instructions, from 1.15. Packed, small and varints hold no nested
    message and did not move: their cost is in reading numbers, a later step.
  - JSON arrays of numbers transcode packed (decision 9, amended again). The transcoder wrote
    each element of an array as a record of its own, so the decode read a tag, matched the field
    and widened the view once for each element. A field the descriptor packs is now one packed
    record. On x86-64-v2: packed JSON decode takes 17.57% fewer instructions, and 27.57% fewer
    with every field read; medium 7.00% and 10.83%; large 10.02% with every field read. Large's
    JSON decode alone takes 0.53% more: each of its records' 8 values closes a record of its
    own. arm64 moves alike. Mutations, 5, each CAUGHT, after a test of a repeated enum's null.
  - The judge on `80b8e69`, [run
    43646988363](https://github.com/c4milo/connect-zig/actions/runs/43646988363): packed JSON
    decode takes 17.67% fewer instructions, 27.64% with every field read, medium 7.03% and
    10.86%, large 11.05% with every field read; large's JSON decode alone moved 0.08%.
    `bench/instructions.txt` holds these counts. On a Xeon 6975P-C, connect-zig is faster than
    Buffa in each of the README's 16 cells.
  - JSON encode on the N2, with the owner's word, in the lab: stdx main `22f5139`, past stdx's
    decision 77, makes JSON encode beat Buffa there on small (1.18), deep (1.08) and packed
    (1.13), where connect-zig's pin `89a021c` lost them; strings (0.89) and tree (0.48) still
    trail. It reaches connect-zig when colibri pins it. The numbers went to stdx's session.
  - The judge on `808a25e`, [run
    43642289829](https://github.com/c4milo/connect-zig/actions/runs/43642289829): JSON decode
    takes fewer instructions on tree (23.07%), deep (17.25%), large (14.92%) and medium
    (8.12%), and no count rose past 0.5%. `bench/instructions.txt` holds these counts. Buffa's
    time over connect-zig's for JSON decode, on the Neoverse-N2, from run 119 to this run:
    tree 1.22 to 1.53, deep 1.32 to 1.55, large 1.05 to 1.20, medium 1.51 to 1.61.

- **colibri v0.16.3, with stdx `22f5139`.** connect-zig pins colibri v0.16.3 (`6ff19aa4`) and the
  stdx it pins, `22f5139`, which is stdx's main of 2026-11-14. colibri's API does not change, and
  chapulin v0.6.0 stays. The owner asked on 2026-11-14 to nudge colibri for a release with stdx's
  main, and colibri cut v0.16.3 from v0.16.2 with that one change.
  - The new stdx holds its decisions 76 to 79: the TextReader's token queue, the JSON writer's
    write-back of its state, `TextWriter.member_*` and `TextReader.next_items`, and the base64
    option `pad_bits`. connect-zig's code needs no change for any of them.
  - On x86-64-v2 under callgrind, the new stdx alone takes connect-zig's JSON decode 11% to 34%
    fewer instructions (tree 33.78%, deep 30.17%, packed 26.63%) and its JSON encode 3% to 12%
    fewer; no count rises. On the Neoverse-N2, the lab measured JSON encode beating Buffa on
    small, deep and packed with this stdx.
  - connect-zig keeps its own base64 fallback: stdx's `.pad_bits = .drop` costs about 18
    instructions a bytes field on a valid text, and the fallback costs none (owner, 2026-11-14).
  - The JSON encoder opens a `Lazy` child's object with `TextWriter.member_begin_object` (stdx
    decision 78): one call writes the member's name and the brace. Deep's JSON encode takes 8.65%
    fewer instructions on x86-64-v2, and no other count moves. A scalar member through
    `member_*` took small's and varints' JSON encode 5% to 10% more instructions, and an optional
    message field 0.09% more, so both keep `name` and `write`.
  - The judge on `493b3e0`, [run
    43657281850](https://github.com/c4milo/connect-zig/actions/runs/43657281850), with this pin
    and the member call: JSON decode takes 10% to 34% fewer instructions (tree 34.02%, deep
    30.19%, packed 26.08%), and JSON encode 2% to 13% fewer (deep 13.34%, packed 11.85%, small
    11.19%). No binary count moved past 0.1%. `bench/instructions.txt` holds these counts.
  - Run 129 timed the same commit on an AMD EPYC 9V45 and on a Neoverse-N2. On the N2,
    connect-zig is faster than Buffa in each of the README's 16 cells, and in JSON encode of six
    of the eight messages. On the AMD, Buffa leads deep's binary encode (0.87), as on each run on
    that CPU.

- **A fetched project serves and calls, on colibri's exported modules** (decision 39). The owner
  chose on 2026-11-14 to prove the package before v0.1.0, and to decide its build API now, not
  at the move to colibri v0.17.0.
  - `build.zig` exports colibri's `server`, `client`, `http`, `tls` and `colibri` modules, and
    takes the option `rotor`, which it passes to colibri. A dependent's default stays
    `rotor = false`, so it fetches no Rotor.
  - `tools/package_check.sh` builds the README's steps in a fetched project. It installs the
    plugin with `zig build plugin`, runs `buf generate`, and builds `greet-server` and
    `greet-client` with `.rotor = true`. The server serves `greet.v1.GreetService/Greet` on
    `colibri.Server`, in cleartext. The client calls it over h2 in Connect and in gRPC, on
    `colibri.Client`, and curl calls it in JSON over h11.
  - The first run found a fault that the README taught: a handler's `app` parameter shadows a
    global `app`. The README's server now names its global `state`.
  - The README's step 1 imports the colibri modules from connect-zig, and step 2 installs the
    plugin in a step of its own. Step 4 serves the router on `colibri.Server`, and step 5 names
    `colibri.Client`.
  - TLS and h3, the same day: the owner asked why the server ran in cleartext, and chose TLS
    and h3. The check copies `examples/testdata/tls` into its project (decision 25 as amended).
    The server presents that identity. The client trusts its CA and runs a round over h2 and a
    round over h3, each on a `colibri.Client` of its own, and checks the protocol of each round.
    curl calls over h11 with `--cacert`. The README's step 4 shows the TLS form first.
  - CI's package job failed on `c7bf280`, [run
    43660036629](https://github.com/c4milo/connect-zig/actions/runs/43660036629). Zig 0.16's
    x86_64 backend, which builds Debug on x86-64, placed the client's global off its type's
    alignment, and Rotor's loop stopped on an assertion in `layout.take`. Each global of the
    check, and of the README's server, now states its alignment (pepegrillo's
    `static-alignment` rule), which the lint does not read inside a script.
  - In a linux/amd64 container, `c7bf280`'s client stops on the same assertion, and the new one
    starts its loop. Rosetta has no `epoll_pwait2`, so the run goes no further there. In an
    arm64 container, on Ubuntu 24.04 and 26.04, the client reads every answer over h2 and h3.
  - Mutations, 2, each CAUGHT: a server with no identity, and a server with no h3.

- **Each example a project** (step 19, decisions 41 and 42). The owner ruled on 2026-11-14 that
  each example is a Zig project of its own, on a shared harness, and that each owns the schema
  it is about.
  - `examples/harness` holds colibri's in-memory links, `Rounds(App, Router)`, `Call`, `Served`
    for `zig build serve`, the test identity and chapulin's hook. Its two sides are plain
    structs, and the route table reaches the server through a type-erased reference, so each
    function scores 15 or less.
  - Eleven projects: quickstart, protobuf_messages, sans_io_call, eliza, streaming,
    interceptors, errors, github, oidc, std_io and socket_server. `demo.proto` split into the
    streaming, interceptors and errors schemas. A service is generic over the program's `App`,
    which holds its room in a field named after it, so `socket_server` joins every service
    under one router.
  - Each project's `zig build test` runs its check, and `zig build serve -- [port]` serves its
    service over TLS on h11, h2 and h3, under the test identity. The owner chose on 2026-11-14
    that each example is a program to play with.
  - The root's `zig build examples` runs each project's build as a child, with `--system` on
    the root's `zig-pkg` and the root's cache. A project's own `zig build` fetched 559 MB
    before; the child builds fetch nothing.
  - Every project asks connect-zig with the same options. Other options make Zig build a second
    `connect` module, and the compile fails with "file exists in modules". `eliza` and the
    harness take a `rotor` option, so `std_io` builds them with no Rotor (decision 32).
  - `tools/package_check.sh` builds `examples/quickstart` against a fetched copy, and its
    generated code must equal the fetched plugin's. No program source lives in a script.
  - The lint matches a directory at any depth, so `src` named each project's `src/`. The four
    library-only rules and the library's import rule now exclude `examples`; `magic-numbers`
    and `global-state` read each project, and each `gen/`.
  - One check went: `streaming`'s client interceptor counted responses in statics. A client
    interceptor gets no context in `connect_colibri`, so it cannot count without one. The
    program checks each response's status itself.

- **The library's rules on every tree** (step 20, decision 42). `magic-numbers` and
  `global-state` read `bench/`, `conformance/` and `tools/`, beside `src/`, each `gen/` and each
  example project. Before the change they found 52 and 34 in `bench/`, 4 and 71 in
  `conformance/`, and 32 and 37 in `tools/`; now none.
  - Each program allocates one `State` from `init.arena` before the first call. The
    conformance client's transport is a `Transport` struct, which the interop client holds too.
  - The benchmark's buffers moved from statics to the heap. On x86-64-v2 under callgrind, 46 of
    48 operations moved less than 0.1%. Medium binary decode+walk took 30 instructions more
    (+0.19%), and small JSON decode 3 more (+0.11%): with a static, LLVM folded the buffer's
    address into the alignment of `decode_run.zig`, and a heap buffer computes it at run time,
    as a program's own storage does. No library code changed.
  - The benchmark's message values stay named constants in `bench/inputs.zig`, which the Go and
    Rust benchmarks cite as their source.

- **OpenTelemetry's trace export** (step 21, decision 40). `examples/otlp` serves
  `TraceService/Export` of opentelemetry-proto v1.11.1 and `otlpstore.v1.SpanStore/Received`.
  Its check exports a checkout trace of three spans over h2 in gRPC, over h11 in Connect and
  over h3 in gRPC, and reads every export back each time.
  - `interop/otel` exports spans with OpenTelemetry's Go SDK v1.47.0 and its gRPC exporter, with
    gzip, over TLS under the test CA, through the socket server. Each span comes back equal to
    the one the SDK ended: IDs, parent, name, kind, times, every attribute kind with the slices,
    events, links and status. `tools/interop_check.sh` runs it.
  - The check moved from `tools/interop_languages_check.sh`, as design §8 first said, to
    `tools/interop_check.sh`: the languages check runs the interop server of `tools/`, and the
    receiver is an example, which the socket server serves.

- **A client interceptor's context** (step 22, decision 44). A client interceptor's hooks get
  the value that the call's `init` takes, of the type `ClientCallOptions.Context` names.
  - `examples/interceptors` counts each response again, as it did before step 19: `Count`
    adds to the program's `Tally`, one `State` field, through each call's `*Tally`. The check
    asks for 3 responses a round, each with HTTP 200.
  - Every call that names no context passes `{}`: the examples, the conformance client, the
    interop client and the README's steps.
  - The test of a streamed call reads what its interceptor saw through the call's context, in
    place of two thread-local statics.

- **colibri v0.17.0** (step 24, decision 45). colibri v0.17.0 (`9d17c88a`), with chapulin v0.8.0
  (`c45f661d`), Rotor `f2890f5` and stdx `22f5139`, the pins colibri names.
  - The move ran on a branch at each of colibri's sub-step commits, and reported what the API
    left out. colibri took two of the reports before the tag: one stdx pin for colibri and
    connect-zig, since two stdx in one program failed to link, and the kept octets of a body
    given once more at its end.
  - Counted on x86-64-v2 under callgrind, a routed call took: small Connect 77,238 instructions
    on v0.16.3 and 3,935 on v0.17.0; small gRPC 77,728 and 4,430; medium Connect 100,878 and
    27,344; medium gRPC 101,336 and 27,806. The codec's 48 counts did not move.
  - A copy of the body into the call's state cost the same within 0.7%, and needed a public
    option to size it, so the route reads the body in place.
  - Every router names `header_bytes = 0`, and an error handler takes the request context. A
    test's request event gives `body` a reader of its own, `std.Io.Reader.fixed(&.{})`.
  - Mutations, 10 of 10 CAUGHT: the first piece taken for the body, no piece kept, a longer
    piece taken for the last, a body with no octets never served, a stream's cut envelope not
    kept, a body cut inside an envelope accepted, `drain` that reads nothing, a done call that
    drains nothing, and each of the two counters `on_request` sets left as it was.

- **What conformance suite v1.0.7 asks of the client** (step 25). Runner v1.0.7 in client mode
  failed 58 to 60 of its 8232 cases, in three groups.
  - A Connect GET's query, 10 cases. The suite now checks the order the protocol gives:
    `connect`, `base64`, `compression`, `encoding`, then `message` ("Query-Get"). `write_query`
    wrote `encoding` before `base64`.
  - gRPC-Web's Trailers-Only, 46 cases. A stream that ends with no message carries its status
    and its trailers in the HTTP head. The library read the status there already. The
    conformance client reported the trailers of the body's frame alone, so it now reports the
    head's fields when the head holds `grpc-status`.
  - A reset stream, 2 to 4 cases a run, in "Timeouts" against the reference gRPC server over
    h2. That server ends a call at its deadline with a reset whose code is CANCEL, and the
    reset may arrive before the client's own timer runs. The client then answered
    `unavailable`, where the suite takes `deadline_exceeded` alone.
  - `failure_of` now reads the reset's code. gRPC's table maps h2's codes (PROTOCOL-HTTP2.md,
    "Errors") and h3's (gRFC G2, "Errors"): CANCEL and H3_REQUEST_CANCELLED give `canceled`,
    ENHANCE_YOUR_CALM and H3_EXCESSIVE_LOAD `resource_exhausted`, INADEQUATE_SECURITY
    `permission_denied`, and each other code `internal`. Before, each reset gave `unavailable`.
  - colibri's response names no HTTP version. h2's codes end at 0xd and h3's start at 0x100, so
    one table reads both.
  - The conformance client keeps the call's deadline, since the library reads no clock. Past
    that deadline it reports a call the server canceled as `deadline_exceeded`, as grpc-go's and
    grpc-java's clients do. A program with a deadline of its own owes the same rule.
  - With the four changes, runner v1.0.7 passed its 8232 client cases, and its "Timeouts" suite
    alone 8 times of 8. The pinned runner v1.0.4 passed its 8264.
  - Mutations, 28 of 28 CAUGHT: 2 on the query's order, 8 on the trailers' source, 11 on the
    reset's code, and 7 on the deadline's rule. The two on the query first passed in a copy of
    the tree whose cloned `.zig-cache` gave a false hit. An empty cache caught them.

- **brotli written** (step 26, decision 10 as amended). On colibri v0.17.1 and stdx v0.1.1.
  - `connect.BrotliEncoder` is stdx's encoder at level 1 with WBITS 17. It takes 519 KiB, where
    the gzip encoder takes 293 KiB and the zstd encoder 1.4 MiB. `Encoders.brotli` places it, and
    `writes`, `compress` and `choose` take br as they take gzip and zstd.
  - `Encoders` grew from two pointers to three, 24 octets. So `compression.compress`,
    `compression.choose` and `Encoders.writes` take it as `*const Encoders`, and the server's
    head passes its options by pointer. By value, a routed call took 5 instructions more in
    Connect and 8 more in gRPC. By pointer it takes 12 and 16 fewer than before the step: small
    Connect 3,934 to 3,922, and small gRPC 4,434 to 4,418, on x86-64-v2 under callgrind. The
    codec's 48 counts did not move.
  - The tests' shared codecs hold the encoder, and a decoder of the encoder's window alone. The
    decoder a program places takes 19.5 MB, which overruns the reach of thread-local data on
    aarch64 Linux beside the zstd decoder. With the two, the test binary's thread-local data
    takes 14.0 MiB of the 16 MiB that reach allows, and its tests pass on aarch64 Linux.
  - Both conformance programs place the encoder, and both features files declare
    `COMPRESSION_BR`. Runner v1.0.4 then ran 3536 server cases, where it ran 2714, and 10758
    client cases, where it ran 8264. Each passed. The runner's reference server and client read
    and write br with a Go library.
  - One client run of three failed 2 of the 10758 cases, on a Mac whose load was near 45. Both
    were identity cases of a half-duplex stream over h11 against the reference gRPC server, with
    "invalid Read on closed Body": the race `client_known_flaky.txt` describes, in two other
    suites. Those cases alone passed 6 runs of 6, and a full run beside the client of the commit
    before passed each case.
  - `examples/socket_server` reads and writes br, and `tools/interop_check.sh` asks it for a br
    answer that curl decodes.
  - CI's [run 156](https://github.com/c4milo/connect-zig/actions/runs/43956832740) on
    `2e31fdb` agreed: 3536 and 10758 cases, curl's read of a br answer, the tests on the arm64
    runner, and on the judge 10 to 22 instructions fewer for each routed call (small Connect
    4,204 to 4,194, small gRPC 4,711 to 4,699).
  - Mutations, 12 of 12 CAUGHT: br written never, always, and when the zstd encoder is placed;
    the window at WBITS 18; level 5; the gzip encoder in br's arm; the export gone; the
    conformance client's refusal of br; and no encoders handed to a POST's choice, to a GET's
    choice, to a unary reply and to a stream's reply. The GET's was NOT CAUGHT first: no test
    asked a GET for a compressed answer, and one does now.

- **A message with no member in one call** (a hot-path change, `docs/performance.md`). On stdx
  v0.1.1, whose `TextWriter.empty_object` writes `{}` in one call (stdx decision 82).
  - `write_message` tests each field as its writer does, and writes `{}` through
    `empty_object` when no field writes a member. An empty `Any` takes the same call. The tree
    benchmark holds 341 messages, and 256 of them write no member.
  - Local judges, under callgrind: tree JSON encode 64,928 to 47,626 instructions on
    x86-64-v2 (26.65% fewer), and 57,175 to 42,177 on aarch64 (26.23% fewer). Small, strings
    and varints JSON encode take 2 more for each message, +0.05% to +0.16%, and large on
    aarch64 2 more for each of its 1000 records, +0.07%. No other count moved.
  - CI's judge on `22b3767`, on x86-64-v3, in
    [run 43982316500](https://github.com/c4milo/connect-zig/actions/runs/43982316500): tree
    JSON encode 64,670 to 47,880 instructions, 25.96% fewer. Small, strings,
    varints and deep JSON encode took 2 more, large 2,002 more, medium 14 more. The baseline
    now holds these counts, and with them the cost of stdx v0.1.1 below.
  - Mutations, 8 of 9 CAUGHT: the test always true, the test inverted, and each of the five
    kinds of field left out of the test. The one NOT CAUGHT never calls `empty_object`, and
    writes the same text: the judge catches it once the baseline holds the new counts.

- **colibri v0.17.3 and stdx v0.1.2** (decision 10). colibri v0.17.3 (`2c2144db`) holds the
  two changes that the runner's pin at v1.0.7 waited for, and pins stdx v0.1.2 (`f45a045e`).
  - Over h11, a head says `Connection: close` only when its route ended the response as the
    head goes out, so a stream that answers early keeps its connection. colibri's router sets
    the new `server.ResponseHeader.request_body` for this; no program here calls the engine's
    `respond` itself. The `streaming` example's streamed round over h11 passes again.
  - colibri's router waits for room to write an answer that has no entry, where it cancelled
    the request.
  - Runner v1.0.7's server half, with br declared, runs 3714 cases: 39 runs of 40 passed each
    one. One run failed one h11 case, a Connect server stream that ends at once with an error:
    Go's client read "unexpected EOF", the fault of v0.17.0, now rare. 60 runs with traces did
    not show it again. colibri's session has the report.
  - CI's judge in run 160: a small routed call takes 8 instructions more, +0.19%, and a medium
    one 2 fewer. No codec count but base64's moved past 0.03%.

- **base64's pad bits in stdx's decoder** (decision 10 as amended on 2026-11-10). On stdx
  v0.1.2. proto3 JSON reads a last base64 letter whose pad bits are set, as protobuf's parsers
  do. connect-zig read such a text in a fallback of its own, after stdx's decoder refused it.
  stdx's `pad_bits = .drop` now drops the bits, and the fallback's four functions go.
  - stdx v0.1.1 made the decoder's `init` inline, but kept its options, and whether the CPU has
    AVX2, in fields of one or two bits. Zig 0.16 stores such a field at its width and loads it
    as an octet, and LLVM carries no such store to the load. So a decode knew its options at
    compile time only when each was zero. stdx v0.1.2 keeps each as a whole octet.
  - CI's judge counted large JSON decode at 4,969,617 instructions on stdx v0.1.1, 8 more for
    each of its 1000 bytes fields than on stdx `22f5139`; the baseline holds that count.
  - Local judges, with stdx v0.1.2's decoder: large JSON decode takes 26 instructions a field
    fewer than the fallback's code on x86-64-v2, and 8 more on aarch64; 5 of those 8 come from
    the function's shape once the fallback's call goes.
  - CI's judge on x86-64-v3, in
    [run 160](https://github.com/c4milo/connect-zig/actions/runs/44007655863), with the pin of
    colibri v0.17.3: large JSON decode 4,969,617 to 4,952,616 instructions, 17 fewer a field,
    and 9 fewer than on stdx `22f5139`. The run holds the pin and this change together.
  - Mutations, 4 of 4 CAUGHT: pad bits refused, the standard alphabet alone, padding required,
    and a refused text passed as an empty field.

- **Runner v1.0.7** (step 25, decision 26 as amended on 2026-11-16). On colibri v0.17.3.
  - `tools/conformance_check.sh` downloads runner v1.0.7 for Linux-x86_64, pinned by SHA-256.
    In server mode it passes `--parallel 16`: the runner's default follows the CPU count, and
    the server's router holds 16 calls.
  - With br declared, the server half runs 3714 cases, and the client half 10711.
    `client_known_flaky.txt` lists none: v1.0.5 removed the "Client Message Size" suite whose
    case it held, and runner v1.0.7 refuses a pattern that matches no case.
  - On this Mac the client half passed all 10711 cases. The server half passed every case in 39
    runs of 40, and failed one h11 case in one run with "unexpected EOF". The cause was the
    conformance server's idle wait of 1 s, against Go's 90 s: with 50 ms, about 200 cases a run
    failed the same way. The wait is now 30 s, colibri's default, with 512 sockets for the
    grpc-go client's connections: 8 runs of 8 passed every case. At 30 s with 128 sockets, the
    grpc-go client's cases failed to connect.
  - CI's run 173 failed one h11 client-stream case with "unexpected EOF". The server closed a
    connection that Go's client opened and kept, at the first-request wait of 5 s. At 50 ms,
    24 h11 cases failed in one run. Both waits are now 120 s, past Go's 90 s.
  - `tools/conformance_report.awk` reads both runners' names for the grpc-go peer: v1.0.4's
    "(grpc)" and v1.0.7's "grpc-reference-".

- **Route tables in the routed call** (step 27). On colibri v0.17.3.
  - Each implementation built a router of one route, and connect-go none: its benchmark called
    the handler itself. So the routed call held no routing cost.
  - The small message's call now runs in tables of 1, 16 and 225 routes: 1, 4 and 15 services,
    each of as many methods. The echo method's service holds it and `Filler<j>` methods, and
    each service `bench.v1.Filler<i>` holds `Call<j>` methods. The calls never reach those.
  - colibri finds a route by binary search over each segment's sorted literals, connect-rust by
    a hash map of the whole path, and Go's `ServeMux` by a tree of maps.
  - 225, not 256: colibri v0.17.3's router does not compile a table of 256 routes, since two of
    its functions switch over each route with Zig's default branch quota. colibri's session has
    the report, and the largest table moves to 256 at the release that fixes it.
  - A quick local run on an M1 Pro, from 1 to 225 routes: connect-zig's call took 11% to 13%
    more time, connect-rust's 1% more, and connect-go's moved within its noise.
  - The local judge on x86-64-v2, small Connect call: 3,962 instructions with 1 route, 3,988
    with 16, and 4,203 with 225 (+6.1%); gRPC 4,458, 4,485 and 4,699 (+5.4%). Of the 241 more
    at 225 routes, about 110 are the binary search's steps, about 13 instructions each, about
    40 a copy that the one-route build left out, and about 30 calls that the compiler no longer
    inlines into the larger router.
  - CI's [run 164](https://github.com/c4milo/connect-zig/actions/runs/44014548420) on `cc20a73`.
    The judge, x86-64-v3: the small Connect call takes 4,224 instructions with 1 route, 4,264
    with 16 and 4,432 with 225 (+4.9%); gRPC 4,730, 4,770 and 4,937 (+4.4%). The baseline holds
    the new rows. Times, from 1 to 225 routes: connect-zig's call took up to 14% more on the
    EPYC 9V74 and 8% more on the Neoverse-N2, connect-rust's up to 3%, and connect-go's up to 2%.
- **The full stack** (step 28). On colibri v0.17.3.
  - CI's [run 168](https://github.com/c4milo/connect-zig/actions/runs/44024752259) on `8cf269e`,
    an EPYC 9V45. At 16 spans, connect-zig answered 52,806 calls a second at 19.0 µs of CPU a
    call, and the Collector 23,695 at 42.0 µs. At 512 spans, connect-zig answered 1,607 at
    620.0 µs, and the Collector 1,275 at 785.0 µs.
  - The check found a copy in colibri's body path whose cost grew with the square of a body's
    pieces (colibri v0.18.1, below).
- **The production model** (step 29). The 516 connections, the 70/25/5 mix and the 100 ms
  limit were chosen on 2026-11-17.
  - A local run on an M1 Pro, in a Linux VM, on colibri's fix `ed40807`: connect-zig held
    712,098 spans a second, at p99 33 ms with its core 99% busy, and the Collector 213,620, at
    p99 27 ms with its core 85% busy. On v0.17.3, connect-zig's CPU grew faster than its load,
    from 38% busy at 213,600 spans a second to 79% at 284,800, where calls were refused.
  - The sink holds about 480 MiB from its start: about 0.5 MiB for each of 528 connections, and
    about 3 MiB for each of the 64 calls that it holds at once.
  - CI's [run 170](https://github.com/c4milo/connect-zig/actions/runs/44077206597) on `253404b`,
    on colibri v0.18.1. On an EPYC 9V74, connect-zig held 569,536 spans a second at p99 1.46 ms,
    and the Collector 213,580 at p99 20.71 ms. On a Neoverse-N2, connect-zig held 712,014 at
    p99 18.65 ms, and the Collector 142,400 at p99 14.31 ms. `tools/fullstack_chart.py` draws
    the README's charts from the job's output.
- **Servers in Rust** (step 30). CI's
  [run 172](https://github.com/c4milo/connect-zig/actions/runs/44093381647) on `c2c75dd`.
  - Over TLS, on a Xeon 6975P-C: connect-zig held 854,352 spans a second, the Collector 213,600
    and Vector 71,200. On a Neoverse-N2: 712,000, 142,400 and 53,400.
  - In cleartext: connect-zig held 854,352 and 712,032, the Collector 213,600 and 142,404, and
    Rotel 284,800 and 213,604.
  - Vector spent 8.99 µs of CPU a span on x86-64 and 13.54 µs on arm64, and grew to 1,471 MiB
    and 709 MiB. Rotel spent 3.02 µs and 4.51 µs. Rotel's p99 stayed near 41 ms from 53,400
    spans a second up, on both machines, and Vector's passed 40 ms at about the same rate.
  - The steps grow by up to half, so run 172's ratios could be off by half. Now three halvings
    follow the first failure (decision 44). CI's
    [run 177](https://github.com/c4milo/connect-zig/actions/runs/44148697298) on `ca4bea6`, on
    an AMD EPYC 7763 and a Neoverse-N2: over TLS, connect-zig held 551,704 and 694,200 spans a
    second, the Collector 186,896 and 204,700, and Vector 57,834 and 66,748. In cleartext,
    connect-zig held 640,800 and 783,184, the Collector 169,116 and 195,800, and Rotel 222,488
    and 222,478.
- **Other Connect libraries** (step 31). CI's
  [run 182](https://github.com/c4milo/connect-zig/actions/runs/44322389021) on `15e6986`.
  - Over TLS, on a Neoverse-N2: connect-zig held 729,750 spans a second, connect-rust 258,090
    and connect-go 89,000. On an EPYC 9V74: 622,968, 329,300 and 124,600.
  - connect-rust spent 3.76 µs of CPU a span on arm64 and 3.03 µs on x86-64, and connect-go
    10.30 µs and 7.21 µs, where connect-zig spent 1.37 µs and 1.43 µs. connect-rust grew to 53
    MiB and 55 MiB, and connect-go to 144 MiB and 131 MiB.
  - A local run in an arm64 container before it gave 4.5 times connect-go's rate and 1.8 times
    connect-rust's, with every span counted.
- **protovalidate's standard rules** (step 32, decision 47). Run on a Xeon at 2.1 GHz, x86-64
  Linux, with buf 1.74.0 and go 1.24.7.
  - `zig build test-protovalidate` printed 72 of 72 tests passed, and `zig build test-plugin` 20
    of 20. `zig build test` passed. The lint reads the module and each generated table with
    every rule (decision 17).
  - `tools/generate_check.sh` printed a match for each `gen/`. No example's generated code
    changed: a message with no rule keeps the code it had.
  - `tools/protovalidate_conformance_check.sh` built the harness from protovalidate's commit
    `4baed765`, the release v1.2.2. With strict messages and strict errors it printed `PASS
    (failed: 0, skipped: 1054, passed: 1818, total: 2872)`. Of the 1,054 listed cases, 796 state
    a CEL rule, 244 a predefined rule and 14 a `pattern`.
  - The suites `library/*` are 635 of the CEL cases. They state `string`'s well-known forms as
    CEL expressions. An executor that called `format_name.zig`, `format_ip.zig` and
    `format_uri.zig` in the expressions' place passed all 635. The tree does not keep it.
  - The suite found two faults, now fixed. A map's message values were not read, since an
    entry holds its value as an optional. A timestamp in a rule's message was not written as RFC
    3339 text.
  - Mutations of the plugin, against `zig build test-plugin`: 29 of 29 CAUGHT.
  - Mutations of the library, against `zig build test-protovalidate`: 343. A test caught 336:
    78 of the walk, the report and the tables, 124 of the rules, and 134 of the formats and
    the messages' text. The compiler stopped 4 more: each made a table of the tests' own
    messages one that `rules_error` refuses. 3 are NOT CAUGHT and equivalent: an IPv6 host with
    no brackets, a userinfo with an "@" and a path with a "?" cannot arrive, because the text
    is split at those characters first.
  - Mutations of the conformance check, 6 of 6 CAUGHT: a validation error answered as success
    failed 754 cases; rules that cannot be checked answered as a run-time error failed 29; a
    failing case left off the list and a passing case put on it failed 1 each; another message
    for `string.min_len` failed 2; and a map key's violation with no `for_key` failed 11.
  - The first run of each set found mutations that no test caught. Each now has a test: a
    message's `oneof` rules, a oneof with `required` unset, strings compared by their octets,
    a map entry's path, equal bounds of a range, a port's and an IPv4 octet's letters and digit
    count, the text after an IPv6 host's bracket, a URI's host and zone, and the fraction and
    leap day of a timestamp's text. Six checks that no input could reach are gone: a hostname's,
    an email domain's and a Protobuf name's empty text, the end of an IPv4 address inside an
    IPv6 one, a prefix's empty length, and a list's reset of its path.
- **A hook for each request message** (step 33, decision 47). Run on a Xeon at 2.1 GHz, x86-64
  Linux, with buf 1.74.0.
  - `zig build test-connect-colibri` printed 72 of 72 tests passed, 7 of them the hook's
    (`message_hook_test.zig`). They run a route for each place that decodes a request message:
    a function handler's one message and its `RequestStream`, a type handler's `on_message`,
    and the `on_request` of a server stream's type handler.
  - `zig build test-protovalidate` printed 83 of 83 tests passed, 11 of them the
    interceptor's and its error text's, over a stand-in for `connect`.
  - `zig build example-validate` printed "every call answered as expected over h2, h11 and
    h3": an account taken over Connect, one refused in JSON with 1 violation, one refused over
    gRPC with 3, a stream of 2 taken over gRPC-Web, and a stream refused at its second
    account, whose third no handler took. `zig build serve` answered curl 400 and
    `invalid_argument`, with the message "email: must be a valid email address (and 1 more)"
    and a `buf.validate.Violations` detail.
  - `zig build test` passed, and `tools/generate_check.sh` matched each `gen/`. The example's
    schema takes validate.proto from the Buf Schema Registry at v1.2.2, whose file equals the
    tree's.
  - `tools/perf_check.sh` with valgrind 3.22 counted 4,177 instructions for the small routed
    Connect call and 4,430 in 256 routes, as before the hook: a route whose interceptors declare
    no `on_message` makes no call for a message.
  - Mutations of the hook, against `zig build test-connect-colibri`, 14 of 14 CAUGHT: the hook
    skipped at each of the four places, run after the handler, its error dropped, only the
    first interceptor run, the list read backwards, no list read, a stream with no hook, a
    refused message passed on, a refusal that is not the call's failure, a failed stream read
    on, and a message counted after the hook.
  - Mutations of the interceptor, against `zig build test-protovalidate`: 29. A test caught 28.
    The compiler stopped 1: with `values_error` refusing every `.Values`, the tests' own
    interceptor does not build.
  - Mutations of the example, against `zig build example-validate`, 2 of 2 CAUGHT: routes that
    list no interceptor, and a schema with no email rule.
  - The step changes one thing a program may see: `RequestStream(T).next` gives no message
    after its stream failed. Before, `next` read the body again when a handler asked after a
    failure.
- **CEL, parts a to c** (step 34, decision 47 as amended). Run on a Xeon at 2.1 GHz, x86-64
  Linux.
  - A spike came first: 200 lines that parse an expression at comptime, type it from a
    message's fields and unfold it, in Zig 0.16. The owner then ruled for the comptime
    compiler in the module, in place of functions the plugin writes.
  - `zig build test-protovalidate` printed 148 of 148 tests passed, 65 of them the compiler's,
    in `src/protovalidate/cel/`. `zig build test` passed.
  - `tools/protovalidate_conformance_check.sh` printed `PASS (failed: 0, skipped: 258, passed:
    2614, total: 2872)`. Part a moved 130 cases off the list, part b 22, and part c 644: the
    seven `library/*` suites, 635 cases, pass whole. The 258 listed cases are 244 of predefined
    rules and 14 of patterns.
  - Mutations of part a, 167: a test caught 127, and the compiler stopped 40, where the tests'
    own expressions no longer compiled. Of part b, 39 of 39 CAUGHT, and of part c, 17 of 17.
  - The first runs found 15 mutations with no test: bytes of one length, an unsigned kind, a
    bool's default, a variable named `now`, arithmetic on strings, `dyn` through a call and
    through a negation, a double that is not a number, a wrong left side of `&&`, a rule's path
    under `repeated.items` and `map.keys`, a list's and a map's own rule, and three counts of
    the elements read. Each has a test now. Two checks no input reached are gone.
  - The commit `b6f90a1` has a subject of 74 columns, 2 past the limit, and `zig build
    lint-commits` refuses it. A rewrite of a pushed commit needs the owner's word.
- **CEL, part d** (step 34, decision 47 as amended). Run on a Xeon at 2.1 GHz, x86-64 Linux.
  - The module's side came first, in `e12c39d`: `Rules.Field.predefined`, and the check of
    each entry's CEL rules, which read the field as `this`, the extension's value as `rule`
    and the rule message as `rules`. Of its 20 mutations a test caught 17 and the compiler
    stopped 3.
  - The plugin's side, in `95ecace`, is `src/protoc_gen/rules_predefined.zig`. It finds each
    extension of a rule message in the request, reads its records from the message's unknown
    fields, and writes the field's `predefined` list. `zig build test-plugin` printed 31 of 31
    tests passed, and `zig build test` 97 of 97 steps and 533 of 533 tests.
    `tools/generate_check.sh` matched every `gen/`.
  - `tools/protovalidate_conformance_check.sh` printed `PASS (failed: 0, skipped: 50, passed:
    2822, total: 2872)`. 208 cases of `predefined_rules` left the list. The 50 listed cases
    wait for step 35: 36 predefined rules whose expression calls `matches`, and 14 of
    `pattern`.
  - Mutations of the plugin's side, 76: a test caught each one. Six of the first mutants did
    not compile for a reason of their own, and each ran again in a form that compiles.
  - A reading of the mutation list before its run found five checks with no test: a wrapper's
    default for a bool and for a string, the member of `Predefined.Value` for each type, a list
    of no value, two CEL rules of one extension, and FieldRules itself as a site. Each has a
    test now. A test with hand-written octets holds the four new numbers of
    `descriptor_pb.zig`, which an encoding by the same file cannot check.
  - The plugin walks the tags of a span in code of its own, about 40 lines, as the protobuf
    module exports no wire reader. The owner's word is owed on a public name for one.
- **CEL: the grammar's checks, and large schemas** (step 34, decision 47 as amended). Run on a
  Xeon at 2.1 GHz, x86-64 Linux, 4 cores. The owner asked whether a large schema compiles in
  reasonable time, and for a fuzzer and a Lean model of the CEL reader.
  - Compile time of a Debug build, a schema of M messages of N fields, each field with a CEL
    rule of its own text and each message with three. Before and after:
    1 × 200, 203 expressions, 10.7 s and 3.5 s; 1 × 500, 31.8 s and 8.0 s; 20 × 50, 1,060
    expressions, 48.2 s and 13.4 s; 100 × 20, 2,300 expressions, 100.4 s and 27.7 s. After
    alone: 1 × 1,000 in 14.4 s and 1 × 2,000 in 27.9 s, which did not compile before. With
    standard rules alone, 100 × 20 built in 2.8 s and 1 × 1,000 in 3.6 s, where 1 × 1,000
    took 23.1 s. A CEL expression costs about 13 ms.
  - Where the time went: the reader read each token again at each level of operators, each
    reader of a tree asked the compiler for a tree of its own, and each field searched the
    table for its entry. The reader now holds one token ahead, `cel_parse.tree_of` gives one
    tree for each text, and `table.entry_of` reads a place computed once for each type.
  - Three limits fell. The protobuf module stopped at a message of about 500 fields: each
    function that reads every field at compile time now raises its branch quota. The table of
    a message with more than 1,000 `.of(` calls stopped the compiler: the plugin now writes
    such a table in a block that raises the quota. One limit stays, and "What a later step
    owes" names it: about 1,000 repeated and map fields in one message.
  - `tools/wide` holds one message of 600 fields with rules, and `zig build test-generated`
    reads it through binary, JSON and `validate`.
  - The CEL reader was read against the language definition for the model. Nine things
    differed, and each follows the definition now: a string of three quotes, a bytes literal's
    prefix order, `0X`, a line end in a string of single quotes, the reserved words, a keyword
    as a field's name, a comma after a list's last element, a double past the greatest one,
    and a number's sign after a "!". One error was found in the reader itself: a string with a
    numbered escape, such as `'é'`, did not compile.
  - The Lean model, 6,647 vectors: the Zig grammar gave the model's tree or its refusal for
    each. The first run differed on one, `r'a\'`, where the model was wrong: a raw string ends
    at its first quote. `tools/lean_check.sh` printed `Build completed successfully`, and
    exits 1 on a vector file that was changed.
  - Zig's fuzzer: `zig build test-protovalidate -Drelease --fuzz=2M` ran 2,001,782 inputs,
    1,423 of them unique, in 327 s, with no failure.
  - `zig build test` printed 97 of 97 steps and 544 of 544 tests passed.
    `tools/protovalidate_conformance_check.sh` printed `PASS (failed: 0, skipped: 50, passed:
    2822, total: 2872)`. `tools/perf_check.sh` printed no operation past the baseline: the
    small routed Connect call takes 4,177 instructions.
  - Mutations, 64: a test caught 58, and the compiler stopped 6, where the tests' own
    expressions no longer compiled. The CEL reader took 50 of them, the table 6, the plugin 4
    and the protobuf module 4. Three of the first mutants did not compile for a reason of
    their own, and each ran again in a form that compiles.
  - pepegrillo moved to `e94a349`. Its commit linter still holds a subject to 72 columns, so
    `b6f90a1` still fails `zig build lint-commits`.
- **Ubuntu 26.04** (`fa83b86`, decision 44 as amended on 2026-11-20). CI's
  [run 191](https://github.com/c4milo/connect-zig/actions/runs/44673102412), the first on
  `ubuntu-26.04` and `ubuntu-26.04-arm`. Every job passed. Over TLS on arm64, connect-zig held
  712,016 spans a second, connect-rust 267,000 and connect-go 89,002: 2.7 and 8.0 times. The
  first attempt of `bench-compare` on arm64 timed some of connect-zig's cells at twice the lab's
  time, with the same CPU and code; a second attempt matched the lab, and the README takes it.
  valgrind 3.26 counted the routed call's instructions as 3.22 did: 4,177 and 4,430.
- **colibri v0.19.0** (`af0b01e`). CI's
  [run 185](https://github.com/c4milo/connect-zig/actions/runs/44627403358). colibri issue 137
  halved each socket's buffers and decision 167 moved each TLS session into a buffer the program
  passes, so the sink's peak fell from 483 MiB to 378 MiB on both machines. The small routed
  Connect call took 4,177 instructions, 1.42% fewer, and 4,430 in 256 routes. Over TLS on arm64,
  connect-zig held 694,200 spans a second, connect-rust 266,990 and connect-go 97,898: 2.6 and
  7.1 times, where run 182 gave 2.8 and 8.2, within the climb's 1/16.
- **colibri v0.18.1** (steps 27 to 29, decision 10). colibri v0.18.1 (`0942b20a`) pins the
  stdx, chapulin and Rotor that v0.17.3 pins, so only colibri moves.
  - v0.18.0's router compiles a table of 256 routes, so the largest route table moves from 225
    routes to 256: 16 services of 16 methods.
  - v0.18.1 fixes the copy that step 28 found. The router copied a body's held octets onto
    themselves after each piece, and a unary call holds its body until its end. The TLS
    connection shifted its buffers in a byte loop. v0.18.1 copies nothing in place, and shifts
    with `@memmove`.
  - Measured in turns on the M1 Pro, the sink under h2load, five rounds each. These numbers
    order the builds, and the published ones come from CI (docs/performance.md). At 16 spans:
    36,152 calls a second on v0.18.0's tree and 62,102 on the fix, at 27 and 16 µs of CPU a
    call. At 512 spans: 819 and 1,997 calls a second, at 1,220 and 495 µs.
  - CI's [run 169](https://github.com/c4milo/connect-zig/actions/runs/44076765191) on `87b91d5`,
    a Xeon Platinum 8370C. The judge, x86-64-v3: each routed call takes 13 instructions more
    (+0.3%), the medium call 23 more, and no codec count moved. The small call takes 4,460
    instructions in a table of 256 routes, +5.3% on one route, and 4,965 in gRPC, +4.7%. The
    baseline holds them.
  - The full stack in run 169: at 16 spans connect-zig answered 3.12 times the Collector's
    calls a second, and at 512 spans 1.80 times; in run 168, on v0.17.3 and an EPYC 9V45, 2.23
    and 1.26 times. In the production model connect-zig held 427,128 spans a second on one core,
    at p99 2.55 ms, and the Collector 142,402, at p99 25.21 ms. A burst filled the sink's 64
    calls at 569,600 spans a second, with its core 94% busy, and a call was refused.

### What a later step owes

- A stream that waits for an event of the program once its request ended (colibri issue 130).
  colibri v0.16.0 left it out, as ruled on 2026-11-10. No release up to v0.17.0 holds it, and
  the issue is still open.
- For `oidc`, a measurement before any change: a client sends one token with each call, and
  the verifier checks its signature each time. If that cost shows in a server's profile, a
  verifier may keep the last tokens it took.
- For `protovalidate`, what step 35 needs of stdx's regular expression module:
  - RE2's syntax, as CEL's `matches` takes it. The suite's patterns hold a flag group, anchors,
    classes, a hex escape range and Perl classes: `(?i)^[a-z0-9]+$`, `^[\x00-\x7F]+$` and
    `\* \\ \w`.
  - A search: `matches` is true when any part of the text matches, so a pattern states its
    own anchors.
  - Time linear in the text, no allocator, and a pattern that is comptime data in generated
    code, with the size of what a match needs known at comptime.
  - `bytes.pattern` reads its value as UTF-8, and a value that is not UTF-8 is a run-time
    error, not a violation.
- For `protovalidate`, a `unique` list longer than `compared_items_max` fails with
  `TooManyItems` (decision 47). A program that needs longer lists needs a set in storage it
  passes. No step holds that yet.
- For `protovalidate`, the parts of CEL that no rule of the conformance suite uses and the
  module does not read yet: `timestamp(string)`, sums and differences of timestamps and
  durations, the accessors of a timestamp such as `getFullYear`, `map` over a field,
  `filter`, and `string` of a number. Each stops the build with a message that names it.
- A generated message holds at most about 1,000 repeated and map fields. Zig counts each
  `proto.Repeated(...)` of a struct's fields against a branch quota of 1000, which no
  statement of the struct can raise. An alias for each element type, declared once in the
  file, would take the calls out of the struct.
- The Lean model states the CEL syntax and proves no theorem. A proof that the model reads the
  text of each tree back as the tree would hold the grammar and the text to each other for
  every tree, where the vectors hold 600. The format checks of step 32, a URI of RFC 3986
  among them, have no model yet: one would follow the RFC's ABNF, with vectors as here.
- `examples/socket_server` serves every example's service but `validate`'s. A route table names
  one `.Values` type, and each example's service names its own for its interceptor. A service
  that takes the table's `.Values` as a parameter would let the table hold the fields of both.
