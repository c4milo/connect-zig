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
protoc-gen-connect-zig (executable) <- protobuf
```

`connect` imports no HTTP library (decision 2). Only `connect_colibri` imports colibri. `oidc`
imports chapulin for its `jws` calls, and no colibri module (decision 34).

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

`connect_colibri` maps a `connect.Method` onto a route of `server.Router`, and onto
`client.Request` and `client.Response`. A function handler's route sets `.whole_body` and takes
its stream whole (decision 12). A type handler's route reads the body as it arrives and answers
each message at once, full-duplex over h2 (decision 18). A type handler with `next` gives one
message at a time, at colibri's `on_writable`, so its stream may be longer than the router's
response memory (decision 33). A client's streamed call writes each
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

### What a later step owes

- A stream that waits for an event of the program once its request ended (colibri issue 130).
  The owner ruled on 2026-11-10 that colibri v0.16.0 does not wait for it. Neither v0.16.1 nor
  v0.16.2 holds it: it ships in v0.17.0.
- colibri v0.17.0 gives its router a per-request `RequestContext` with `values(T)`, and each
  callback the shape `(app, ctx, request, response)` (approved by the owner in colibri on
  2026-11-11). `connect_colibri` then reads `ctx.values` from colibri's entry, and
  `RouteOptions.Values` goes for the route table's `.Values`. The owner ruled that v0.1.0
  waits for it.
- For `oidc`, a measurement before any change: a client sends one token with each call, and
  the verifier checks its signature each time. If that cost shows in a server's profile, a
  verifier may keep the last tokens it took.
