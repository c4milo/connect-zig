# Changelog

Every release of connect-zig, newest first. Each entry says what a user of the library sees: what
it can do, what changed in its API, and what it still cannot do. The reasons behind each choice
are in [docs/decisions.md](docs/decisions.md), and the steps and their measurements in
[docs/design.md](docs/design.md) §8.

connect-zig follows [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may
change the public API, and the entry marks each change that does.

## Unreleased: v0.1.0

The first release.

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
- A handler takes the call's context, its request and its response, as connect-go splits them:
  `rpc.Context`, `rpc.Request(T)` or `RequestStream(T)`, and `rpc.Response(T)` or
  `ResponseStream(T)`. An interceptor takes `rpc.AnyRequest` and `rpc.AnyResponse`, with no
  message (decision 36).
- Values for each call, of a struct the program declares in `RouteOptions.Values`. An
  interceptor writes them, and each callback of the call reads them with `ctx.values`
  (decision 35).
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
  `.proto` file.

### Runs on any event loop

- The library does no I/O, holds no allocator and reads no clock. It builds on colibri's protocol
  modules alone and never names Rotor (decision 32).
- The examples run on `colibri.Server` and colibri's in-memory links, and one serves ELIZA on
  colibri's engine over Zig's `std.Io`, with no Rotor at all.

### Checked

- connectrpc's conformance suite v1.0.4: the server passes 2714 of 2714 cases. The client runs
  8264 cases, and passes each but one timing case of the reference server, which may fail and
  is listed as flaky with its reason.
- Clients in other languages call connect-zig's server: connect-go, grpc-go, connect-es on Node,
  grpcio, tonic and connect-rust, across every protobuf type. connect-zig's client calls their
  servers too.
- Every protobuf type is compared with Go's runtime, and closed enums and unchecked strings with
  upb's.
- A performance gate on instruction counts, and a benchmark beside Go's protobuf runtime and
  connect-rust's Buffa, published by CI.
- A project that fetches connect-zig as a package builds against it, as `zig fetch` keeps the
  files: `tools/package_check.sh`, a CI job of its own.
- `oidc` verifies the RFCs' known answers for RS256, ES256 and EdDSA, and RS256 tokens that
  OpenSSL signs, and each of its checks was broken on purpose to prove a test catches it.

### Known limits

- A function handler writes its whole stream in one call, so the router's response memory
  bounds it (decision 12). A long stream takes a type handler with `next`.
- A stream cannot wait for an event of the program once its request ended. colibri plans that
  for v0.17.0 (colibri issue 130).
- Against Buffa, connect-rust's protobuf runtime, on CI's run 105: connect-zig decodes binary
  faster on all eight messages, and JSON on seven. With every field read after a binary
  decode, it is faster on six; in JSON encode on five; and in binary encode on four. A message
  of small nested objects takes its JSON encode about 2.7 times Buffa's time. The ratios move
  with the runner's CPU, and CI publishes the table with each run.
- The library does not report a missing required field (decision 23).
