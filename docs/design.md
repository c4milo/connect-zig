# connect-zig design

connect-zig is [Connect RPC](https://connectrpc.com/docs/protocol/) for Zig 0.16: a protobuf
runtime, a protocol core, an adapter over [colibri](https://github.com/c4milo/colibri), and the
protoc plugin `protoc-gen-connect-zig`. This document holds the module graph, the formats, and
the numbered build plan. Decisions are numbered in [decisions.md](decisions.md).

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
- Unknown fields and groups are skipped, with groups nested at most `depth_max` deep (decision 5).
- `encode` writes fields in number order. Implicit scalars at their default are left off, and
  packable repeated fields are packed unless the field says otherwise.

## 5. Proto3 JSON

`encode_json` writes a message with stdx's `json.TextWriter`. `decode_json` transcodes JSON into
the binary encoding in a caller scratch buffer and then calls `decode` (decision 9). Well-known
types live in `proto.wkt` and have their own JSON forms: Timestamp, Duration, the wrappers,
Empty and FieldMask in the first step; Any, Struct, Value and ListValue later.

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

## 7. The colibri adapter

`connect_colibri` maps a `connect.Method` onto a route of `server.router`, with `.whole_body`
set, and onto `client.Request` and `client.Response`. Streams are whole bodies in v0 (decision
12). The client speaks Connect and gRPC-Web (decision 11).

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
5. **The colibri adapter and `examples/eliza`.** Generated code committed, and a server on
   Rotor's loop. Check: `zig build examples` runs a client against the server over an in-memory
   link, in each protocol the client speaks; `tools/interop_check.sh` calls the socket server
   with buf curl in each protocol.
6. **The plugin.** `protoc-gen-connect-zig` reads a `CodeGeneratorRequest` from stdin and writes
   one `<file>.pb.zig` for each file. Check: CI runs `buf generate` with a pinned buf over
   `examples/`, and the output equals the committed code.
7. **Conformance.** The connectrpc conformance suite against the client and the server. Check:
   the suite's report, pinned to a release.

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
  printed "examples/gen matches buf generate". `zig build test-generated` compiles the output.

### What a later step owes

- The connectrpc conformance suite (step 7).
- A gRPC client over colibri, once colibri's client exposes response trailers (decision 11).
- Long streams written at `on_writable`, and full-duplex streams (decision 12).
- Unknown fields kept, Any, Struct, Value and ListValue in JSON, and editions in the plugin.
