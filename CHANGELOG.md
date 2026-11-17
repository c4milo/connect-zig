# Changelog

Every release of connect-zig, newest first. Each entry says what a user of the library sees: what
it can do, what changed in its API, and what it still cannot do. The reasons behind each choice
are in [docs/decisions.md](docs/decisions.md), and the steps and their measurements in
[docs/design.md](docs/design.md) §8.

connect-zig follows [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may
change the public API, and the entry marks each change that does.

## Unreleased

### Added

- brotli both ways. A program places `connect.BrotliEncoder` in `Encoders.brotli`, and a server
  or a client then writes `br`: stdx's encoder at level 1 with a 128 KiB window, in 519 KiB.
  Before, `br` was read and not written.

### Changed

- CI runs connectrpc's conformance suite v1.0.7, where it ran v1.0.4: the server passes its 3714
  cases, and the client its 10711.
- JSON encode writes a message with no member, `{}`, in one stdx call: tree's JSON encode takes
  27% fewer instructions.
- **Changes the API.** `compression.compress` and `compression.choose` take the encoders as
  `*const Encoders`, since `Encoders` holds three pointers now. A call passes `&encoders`.
- connect-zig builds on colibri v0.18.1 and on stdx v0.1.2, the tag colibri pins. A program that
  names stdx itself pins that tag too, so it links one stdx.
- A server reads a large request body in a time that grows with its length. On colibri v0.17.3
  the time grew with the square of the pieces the body arrived in.
- **Changes the API.** `rpc.failure_of` takes the pool's response, `*const client.Response`, in
  place of its `client.Result`, so it reads the code of a reset stream.
- A call whose stream the server reset ends with the code gRPC's table gives the reset, over h2
  and h3: CANCEL gives `canceled`, ENHANCE_YOUR_CALM `resource_exhausted`, INADEQUATE_SECURITY
  `permission_denied`, and each other code `internal`. Before, each reset gave `unavailable`.

### Fixed

- Over HTTP/1.1, a stream that answers before its request ends keeps its connection, and a
  response that ends its connection says `Connection: close`, so a client never sends its next
  request into a closed connection (colibri v0.17.3).
- A request to a path with no route gets its 404, 405, 501 or 503 when the connection is busy,
  where over HTTP/2 it could read a reset with CANCEL (colibri v0.17.3).
- A Connect GET writes its query in the protocol's order: `connect`, `base64`, `compression`,
  `encoding`, then `message`. connectrpc's conformance suite v1.0.7 checks it.

## v0.1.0 (2026-11-15)

The first release. It builds on colibri v0.17.0, and on the stdx (`22f5139`) and chapulin
(v0.8.0) commits colibri pins, with Zig 0.16.0.

### Protocols

- Connect, gRPC and gRPC-Web, on the server and the client, over h11, h2 and h3, in cleartext
  and over TLS.
- Unary calls and every stream type. Bidirectional streams are full-duplex over h2 and h3, on the
  server through type handlers and on the client through `rpc.ClientCall`'s `Sender`. Over h11
  both sides are half-duplex (decision 18).
- Server and bidirectional streams of any length. A type handler declares `next`, and its route
  asks it for one message at a time while the response memory has room (decision 33).
- Connect's unary GET for methods marked `NO_SIDE_EFFECTS`.
- gzip and zstd both ways. brotli is read, not written, until stdx has an encoder.
- Interceptors on the server and the client, typed error details, timeouts, headers and trailers.
  A client interceptor's hooks get the context the call's `init` takes, such as a pointer to the
  program's state (decision 44).
- A handler takes the call's context, its request and its response, as connect-go splits them:
  `rpc.Context`, `rpc.Request(T)` or `RequestStream(T)`, and `rpc.Response(T)` or
  `ResponseStream(T)`. An interceptor takes `rpc.AnyRequest` and `rpc.AnyResponse`, with no
  message (decision 36).
- Values for each call, of a struct the program names as the route table's `.Values`. An
  interceptor writes them, and each callback of the call reads them with `ctx.values`
  (decision 35).
- Each method is a stream route of colibri v0.17.0's router, which reads a whole body in place
  (decision 45). A small routed Connect call takes 4,204 instructions on CI's judge
  (x86-64-v3), where colibri v0.16.3, which copied each call's state at each request, took
  34,682.
- A method Connect does not serve gets 405 with an `Allow` header, as connect-go answers.

### OpenID Connect

- `oidc`, a module that checks an OpenID Connect bearer token with no I/O: a JWT signed with
  RS256, ES256 or EdDSA, then its issuer, its audience and its times (decision 34). The program
  passes the issuer's JWK Set and the time.
- `oidc` checks signatures with chapulin, the TLS library colibri links, through one object:
  connect-zig's build asks for chapulin with colibri's own request.
- `oidc.Interceptor`, a server interceptor that refuses a call with no valid token, and lets
  the paths a program excludes through. It writes the claims into the call's values.
  `Claims.string`, `integer` and `holds` read a program's own claims, such as `email` or
  `roles`.

### Protobuf

- A runtime with no allocator: decoding leaves strings, bytes and repeated fields pointing into
  the input, and a message is encoded straight into the body it goes out in.
- `decode_into` reads each repeated field's elements, and each recursive field's message, into
  storage the caller owns, once. A program that reads every field takes it, and parses nothing
  twice. `decode` stores nothing (decision 37).
- JSON decode checks the binary it transcodes once, as it writes it, and decodes it one level:
  tree's JSON decode takes 23% fewer instructions, deep 17% and large 14%. An array of a packed
  field transcodes to one packed record, as the encoder writes it: packed JSON decode takes 18%
  fewer instructions.
- JSON encode opens a nested message's object with its member's name in one stdx call: deep's
  JSON encode takes 9% fewer instructions.
- A repeated field's iterator gives a message in place: for a field of messages, `next`
  returns a pointer, and copies no message that `decode_into` stored or that a program set.
  The pointer holds until the next call. A number, a string or an enum still comes back by
  value.
- A server reads each binary request's repeated fields into storage once, so a handler that
  reads them parses them once: each route holds `storage_bytes`, `message_bytes` by default, and
  0 keeps `decode`. A client passes storage in its `connect.Scratch`.
- Every scalar type, `optional`, packed and unpacked repeated fields, maps with every key type,
  oneofs, enums, recursive messages, and unknown fields kept and written back.
- proto2, proto3, and editions 2023 and 2024, with groups, closed enums and `utf8_validation`.
- The proto3 JSON mapping, with every well-known type: Timestamp, Duration, FieldMask, the
  wrappers, Empty, Struct, Value, ListValue and Any.
- base64 from stdx for bytes in JSON, error details, "-bin" values and unary GET messages. A
  value whose pad characters do not complete a quantum of four is refused (RFC 4648 §4).
- `protoc-gen-connect-zig`, a protoc and buf plugin that writes one `.pb.zig` file for each
  `.proto` file. A field or an enum value named `protobuf` gains an underscore, since each
  generated type declares its descriptor under that name.

### Runs on any event loop

- The library does no I/O, holds no allocator and reads no clock. It builds on colibri's protocol
  modules alone and never names Rotor (decision 32).
- The examples run on `colibri.Server` and colibri's in-memory links, and one serves ELIZA on
  colibri's engine over Zig's `std.Io`, with no Rotor at all.
- The package exports colibri's `server`, `client`, `http`, `tls` and `colibri` modules, so a
  program builds on the colibri that `connect_colibri` uses. `.rotor = true` builds
  `colibri.Server` and `colibri.Client` on Rotor (decision 39).
- Each example is a Zig project of its own, which you can copy: its own manifest, schema and
  generated code. `zig build test` runs its check, and `zig build serve` serves its service over
  TLS on h11, h2 and h3, for curl and buf curl. `examples/quickstart` holds the README's steps
  (decision 41).

### Checked

- connectrpc's conformance suite v1.0.4: the server passes 2714 of 2714 cases. The client runs
  8264 cases, and passes each but one timing case of the reference server, which may fail and
  is listed as flaky with its reason.
- Google's protobuf conformance suite, of protobuf v37.0's first release candidate, in binary
  and in JSON: 5635 cases pass, and 107 fail, each listed with its reason. The suite found and
  fixed a tag longer than 5 bytes read, lowercase "t" and "z" read in a JSON timestamp, a
  field mask written that JSON could not carry back, URL-safe JSON bytes with pad bits refused,
  and a oneof's repeated `Lazy` member that silently replaced the first.
- Clients in other languages call connect-zig's server: connect-go, grpc-go, connect-es on Node,
  grpcio, tonic and connect-rust, across every protobuf type. connect-zig's client calls their
  servers too.
- Every protobuf type is compared with Go's runtime, and closed enums and unchecked strings with
  upb's.
- The tests run 97.6% of the library's lines under kcov, on CI's run 136 (decision 43).
- OpenTelemetry's Go SDK exports spans to `examples/otlp`, OTLP's trace receiver, over gRPC with
  gzip and TLS, and the check reads each span back as the SDK ended it (decision 40).
- A performance gate on instruction counts, for the codec and for a routed unary call. A
  benchmark beside Go's protobuf runtime and connect-rust's Buffa, and a routed call beside
  connect-go and connect-rust, which CI publishes.
- CI runs the tests on x86-64 Linux and on arm64 Linux.
- A project that fetches connect-zig as a package follows the README: it generates its code
  with the plugin, and serves a method over TLS on h11, h2 and h3. It calls the method with
  connect-zig's client over h2 and h3, and with curl over h11. `tools/package_check.sh` runs it
  as a CI job of its own.
- `oidc` verifies the RFCs' known answers for RS256, ES256 and EdDSA, and RS256 tokens that
  OpenSSL signs, and each of its checks was broken on purpose to prove a test catches it.

### Known limits

- A function handler writes its whole stream in one call, so the router's response memory
  bounds it (decision 12). A long stream takes a type handler with `next`.
- A stream cannot wait for an event of the program once its request ended. colibri issue 130,
  which asks for it, is still open at v0.17.0.
- Against Buffa, connect-rust's protobuf runtime, on CI's run 129. On x86-64, connect-zig is
  faster on all eight messages in binary decode and in JSON decode, and with every field read
  after a binary decode; on seven in JSON encode; and on five in binary encode. On arm64, it is
  faster on all eight in binary encode, in JSON decode, and with every field read after a binary
  decode; on seven in binary decode; and on six in JSON encode. A message of small nested
  objects takes its JSON encode about 2.3 times Buffa's time on x86-64, and 2.0 times on arm64.
  The ratios move with the runner's CPU, and CI publishes the tables with each run.
- The library does not report a missing required field (decision 23).
