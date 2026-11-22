# Changelog

Every release of connect-zig, newest first. Each entry says what a user of the library sees: what
it can do, what changed in its API, and what it still cannot do. The reasons behind each choice
are in [docs/decisions.md](docs/decisions.md), and the steps and their measurements in
[docs/design.md](docs/design.md) §8.

connect-zig follows [Semantic Versioning](https://semver.org/). Before 1.0, a minor version may
change the public API, and the entry marks each change that does.

## Unreleased

### Added

- `protovalidate`, a module that checks a message against the
  [protovalidate](https://github.com/bufbuild/protovalidate) v1.2.2 rules of its schema
  (decision 47). The plugin writes each message's `(buf.validate.message)`,
  `(buf.validate.oneof)` and `(buf.validate.field)` options as a table, `pub const
  protovalidate`, beside its descriptor. `protovalidate.validate` reads the table at compile
  time, so no rule is parsed at run time, and writes each violation into a `Report` over storage
  the program passes. It checks `required`, `ignore`, oneofs and every standard rule: numbers,
  bool, enum, string with each well-known form, bytes, repeated fields, maps, Any, Duration,
  Timestamp and FieldMask.
- The package exports `protovalidate`, and the generated code of validate.proto and of
  descriptor.proto as `buf_validate_validate` and `google_protobuf_descriptor`.
- A message with no rule, in itself or in a message it holds, keeps the code it had.
- A server interceptor may declare `on_message(app, ctx, T, message)`. A route calls it with
  each request message once it is decoded, before the handler takes it: a unary call's one
  message, and each message of a stream, for a function handler and for a type handler. An
  error it returns ends the call. A route whose interceptors declare none makes no call for a
  message.
- `protovalidate.Interceptor(connect, Values, options)` validates each request message in that
  hook. A message that breaks a rule ends its call with `invalid_argument`, a message that
  names the first violation, and a `buf.validate.Violations` detail. The route table's
  `.Values` holds a `protovalidate.InterceptorRoom(connect, options)` in a field
  `protovalidate`. The example project `validate` serves a service behind it.
- `RequestStream(T).next` gives no message after its stream failed.
- `protovalidate` compiles a schema's CEL rules, `cel` and `cel_expression`, at comptime, from
  the text the table holds (decision 47 as amended). An expression unfolds into plain code: no
  interpreter runs, and the plugin writes no function. It reads CEL's operators, conditionals,
  field selection, `has`, `dyn`, lists and maps with `in`, `size`, an index and the macros
  `all`, `exists` and `exists_one`, the conversions, the string functions and protovalidate's
  own functions. A problem of an expression stops the build.
- `protovalidate.Error` gains `Unevaluable`, for an expression that fails as it runs, such as
  by a division by zero.
- The plugin reads the predefined rules of an extension from its request: an extension of a
  rule message whose declaration states CEL rules in `(buf.validate.predefined)`. It writes
  each one's value and rules into the table of the message that sets it, and `protovalidate`
  compiles them as it compiles a schema's own. A value is a scalar, a wrapper or a list of
  them.
- A CEL string of three quotes, `'''...'''`, which holds line ends, and a comma after the last
  element of a list literal, as the CEL language definition states them.
- A Lean model of the CEL syntax in `spec/lean/`, and `zig build lean`, which requires the
  vectors a unit test replays to be what the model gives. `tools/lean_check.sh` runs it, and
  is the check `lean` of `tools/ci.sh`.
- CEL's `type(x)`, compared with a type's name such as `int`, `list`, `null_type` or a
  message's full name.
- CEL's timestamps and durations: `timestamp(string)` and `duration(string)` of any text,
  arithmetic between them, the `get` functions such as `getFullYear` and `getHours('+05:30')`,
  and `string` of each. A zone is `UTC` or a fixed offset; a zone's name stops the build.
- CEL's `+` of two strings, two bytes values or two lists, and `string` of an int, a uint, a
  double or a bool, so a rule's message may be `'too long: ' + string(size(this))`. A string is
  written into the report's storage, as `format` writes, and a list is joined as it is read.
- CEL reads a map's string key as a field: `this.labels.env` is `this.labels['env']`, and
  `has(this.labels.env)` tells whether the map holds the key.
- CEL's `filter(x, p)`, `map(x, t)` and `map(x, p, t)` on any list or map, such as
  `this.items.filter(i, i.price > 0).size() > 0`. The list they give is computed as it is read,
  so it needs no memory. Before, only `map` of a list literal compiled.
- The plugin raises the compiler's branch quota in the table of a message with more than 500
  list and message rules, so a message of a thousand fields with rules compiles.
- `docs/specs/cel/langdef.md`, the CEL language definition as cel-spec published it at
  v0.25.3, with its checksum. `tools/citations_check.sh`, the check `citations`, requires each
  citation of it in the code to name one of its sections.
- `tools/validate_compare_check.sh`, the check `validate-compare`: connect-zig's
  `protovalidate`, protovalidate-go, protovalidate-es on Node.js, protovalidate-buffa and
  prost-protovalidate on one schema, each message's verdict required to match.
  `tools/validate_chart.py` draws `docs/images/validate-vs-go.svg` from its output.
- `tools/lean_check.sh [seed...]` also compares the Lean model with the Zig grammar on
  expressions that the model draws from a seed, a new seed on each run.
- `tools/cel_differential_check.sh`, the check `cel-differential` of `tools/ci.sh`: random
  CEL rules over random messages, with this library's verdicts held to those of
  protovalidate-go v1.4.1, which runs cel-go.
- `tools/compile_time_check.sh`, the check `compile-time`: the build of a schema of 690 CEL
  rules against the build of the same schema with none, held to `bench/compile_time.txt`.
  Unit tests hold the compiler's reading and typing of an expression to a count of branches,
  and `tools/branch_budget.py` finds a new count.
- `pattern` of a string and of bytes, and CEL's `matches`, on stdx's regular expressions:
  RE2's syntax, in time linear in the text (design §8 step 35). The compiler reads each
  pattern once. The pattern of `matches` is a string literal, and a pattern stdx refuses is a
  problem of the rules. `bytes.pattern` of octets that are not UTF-8 fails with `Unevaluable`.
- connect-zig pins stdx a second time, as `stdx_regex`, at the commit that brought `regex`,
  and takes that module alone from it (decision 47).
- CEL's `format`, `'text %s'.format([values])`, from the CEL strings extension, which
  `docs/specs/cel/strings.md` holds. The text and the list are literals, and the conversions
  `%s`, `%d`, `%x` and `%X` are read; `%f`, `%e`, `%o`, `%b` and a precision stop the build. A
  rule's formatted message is written into the report's storage. protovalidate's conformance
  suite passes all of its 2872 cases.
- A formatted message with no room in the report ends `validate` as a full report does:
  `Invalid`, with the report marked truncated.
- Not yet: arithmetic on a timestamp or a duration, and `timestamp(string)`. A message with such
  a rule stops the build, with a message that names the rule.

### Changed

- The README is a quarter of its length. `docs/guide.md` holds the full walkthrough,
  `docs/protovalidate.md` the guide to validation, `docs/testing.md` every check with its
  command, and `docs/benchmarks.md` every chart.
- connect-zig builds on colibri v0.19.0. **Changes a program's setup.** A program that serves TLS
  on `colibri.Server` passes room for its TLS sessions: a field
  `tls_buffer: [server.Config.tls_buffer_len(n)]u8`, where `n` is the TCP connections over TLS
  it holds at once, and `.engine = .{ .tls_buffer = &state.tls_buffer }` in `init`'s
  configuration (colibri decision 167). With an identity and no buffer, `init` asserts. A
  cleartext server passes nothing. The README's server code shows the form.
- On colibri v0.19.0, a TCP connection holds about 151 KB, where it held about 531 KB, and a TLS
  session takes about 83 KB of the buffer while its connection lasts. In CI's run 185, the OTLP
  sink's peak memory under the full-stack load fell from 483 MiB to 378 MiB. A route search
  compares 8 octets at a time, and the small routed call takes 1.4% fewer instructions.
- An h11 request head longer than 24,582 octets is refused (colibri's step 62).
- A schema's CEL rules compile in a fifth of the time: 2,300 expressions in 20 s of a Debug
  build, where they took 100 s, about 7.5 ms for a rule. The compiler reads each token once,
  keeps one tree and one typing for each expression, and finds a function and a field by its
  name in one step (docs/performance.md, "The compiler's time").
- A CEL expression has the verdict protovalidate-go gives it. **Changes what compiles.** `==`,
  `!=` and `in` take two values of one type, so `1 == 1u` stops the build, and behind `dyn`
  two values of unlike types are not equal. A conversion of a literal that fails, such as
  `int('x')`, stops the build. One `-` before a number is the number's sign, so
  `-2.5.isInf()` asks -2.5, and `--9223372036854775808` is refused. `uint` takes no double
  below zero, and `int` no double at or below the least int. A duration literal holds an
  int64 of nanoseconds at most, about 292 years, as the definition's "Overflow" states.
- The CEL reader follows the language definition's lexis where it did not. **Changes what
  compiles.** A bytes literal's prefix is `b` then `r`, so `rb'x'` is refused. A hexadecimal
  number starts with `0x` in lower case. A string in single quotes holds no line end. A
  reserved word such as `package` names no variable, and a keyword such as `in` names no
  field. A double past the greatest one is refused. `!-5` reads, since a number's sign is
  part of its literal.
- A table with two entries for one field stops the build.
- CEL's `size` of a repeated field that `decode_into` stored reads no element, and an index of
  one reads only the element at its place. A string form check, such as `email`, `uri` or
  `hostname`, looks each octet up in a table, and finds a separator eight octets at a time.
  `min_len` and `max_len` count a string's characters only until the count settles the rule.
  docs/performance.md lists what each costs when it is switched off.
- CEL reads a repeated field or a map that `decode_into` stored from its slice, and a stored
  map's lookup stops at the key, from its last entry back.
- `tools/perf_check.sh` also counts `protovalidate` on the six messages of the validation
  benchmark, `bench-validate --instructions`, against `bench/instructions.txt`.

### Fixed

- A message of about 500 fields or more encodes and decodes. Before, the compiler stopped at
  its default branch quota in `encode`, in `decode` and in the JSON writer.
- A message with more than about 1,000 repeated and map fields compiles. A generated file now
  declares each repeated type once, at the top, as `const RepeatedSpan = proto.Repeated(Span,
  .message);`, and each field uses that name. The field types are the same as before. Before,
  Zig stopped at the branch quota of the struct that held the fields.
- In CEL, a conversion of a conversion of a constant that fails, such as `uint(double(-100))`,
  stops the build, as protovalidate-go refuses the rule. Before, only a conversion of a literal
  did, and the rule failed each time it ran.
- In CEL, the least int's remainder by -1 fails, as it fails in cel-go. Before, it gave 0, and
  a rule that read it could pass where protovalidate-go's fails.
- A macro over a list literal, such as `[1, 2].all(n, n > 0)`, and a signed duration literal,
  such as `duration('-3s')`, compile. Before, each stopped the build with a compiler error.
- A CEL string with a numbered escape, such as `'é'` or `'\x41'`, compiles. Before, the
  build stopped in the escape's own code.
- JSON encode writes a map key once, with its last entry's value, as protobuf's map rule says.
  Before, a map read from binary with a key twice wrote the key twice, which Go's protojson
  refuses. A map of more than 256 entries is written as received. Google's protobuf suite now
  passes 5707 cases, and lists 35 that fail on purpose.

### Checked

- protovalidate's conformance harness v1.2.2 runs against the library, with strict messages
  and strict errors. 2822 of 2872 cases pass, and `conformance/protovalidate_known_failing.yaml`
  lists the other 50, each under its reason.
- Receivers on connect-go and connect-rust join the full-stack check, each on one core. In CI's
  run 182, one core of connect-zig held 8.2 times connect-go's spans a second over TLS on arm64
  and 5.0 times on x86-64, and 2.8 and 1.9 times connect-rust's.
- The full-stack climb halves the gap after its first failure three times, so each rate is
  known within 1/16 of it. Run 172's ratios came from coarse steps, and could be off by half. In
  CI's run 177, one core of connect-zig held 3.0 times the Collector's spans a second on x86-64
  and 3.4 times on arm64, and 9.5 and 10.4 times Vector's, over TLS. In cleartext it held 2.9
  and 3.5 times Rotel's.
- The conformance server waits 120 s for a connection's first request, past the 90 s that Go's
  client keeps a connection, so a case never reads "unexpected EOF".

## v0.2.0 (2026-11-17)

It builds on colibri v0.18.1 and on stdx v0.1.2, with Zig 0.16.0. Two changes to the API are
marked below.

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

### Checked

- The routed call runs in tables of 16 and 256 routes, and the performance gate counts its
  instructions there too.
- A full-stack check loads connect-zig's OTLP sink beside OpenTelemetry's Collector, Vector and
  Rotel, each on one core. In CI's run 172, connect-zig held 4.0 times the Collector's spans a
  second on x86-64 and 5.0 times on arm64, with p99 under 100 ms. It held 12.0 and 13.3 times
  Vector's over TLS, and 3.0 and 3.3 times Rotel's in cleartext.

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
