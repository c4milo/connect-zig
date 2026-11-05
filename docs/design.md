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

## 2. Rules

The library owns no I/O, reads no clock and holds no allocator (decisions 3 and 4). Every loop
is bounded, and every bound is a constant in its module's `constants.zig`. Assertions stay on in
production and cover programmer error alone. Hostile input returns an error value.

## 3. Module graph

```text
protobuf          <- stdx json, stdx codec
connect           <- protobuf, stdx json, codec, gzip, zstd, brotli
connect_colibri   <- connect, protobuf, colibri server, client, http
protoc-gen-connect-zig (executable) <- protobuf
```

`connect` imports no HTTP library (decision 2). Only `connect_colibri` imports colibri.

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

`connect_colibri` maps a `connect.Method` onto a route of `server.router`, and onto
`client.Request` and `client.Response`. A function handler's route sets `.whole_body` and takes
its stream whole (decision 12). A type handler's route reads the body as it arrives and answers
each message at once, full-duplex over h2 (decision 18). Interceptors wrap a route's handler and
a client's exchange (decision 19). The client speaks Connect and gRPC-Web (decision 11).

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
   the suite's report, pinned to a release.
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

- **Step 7, the server half.** `tools/conformance_check.sh` with runner v1.0.4 printed 2712
  of 2714 cases passed, and the two known failures (decision 26). The suite found three faults,
  now fixed. A unary request with no message now fails `unimplemented`, as connect-go answers.
  A compressed message with no coding named now fails `internal`, as gRPC's Message-Encoding
  and Connect's Streaming-Request ask. A gRPC error after response headers keeps its own head.
  `connect_colibri` gains `Call.request_headers`, `Call.request_query` and a context's
  `message_receive_limit`. It also gains 16 KiB of trailer room, for details that echo headers.

- **Compression, later.** `connect` gains `ZstdEncoder`, `ZstdDecoder` and `Encoders`; the gzip
  `encoder` of `Reply`, `client.Options` and `connect_colibri.Codings` becomes `encoders`,
  `accept`'s `can_compress` becomes `encoders`, and `compression.compress_gzip` becomes
  `compression.compress` (decision 10). `tools/interop_check.sh` reads a zstd answer with curl.

### What a later step owes

- The connectrpc conformance suite against the client (step 7), once colibri's client exposes
  trailers and streams a request body.
- A gRPC client over colibri, once colibri's client exposes response trailers (decision 11).
- Long server streams written at `on_writable` (decision 12).
- Client-side full-duplex, once colibri's client streams a request body.
- h3 on the socket server, over a UDP socket, and `tools/interop_check.sh` over h3.
