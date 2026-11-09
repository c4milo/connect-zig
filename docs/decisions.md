# connect-zig decisions

Each entry is numbered and states what it beat. A change that reverses an entry amends the entry
first. Cite an entry by number in code and commits ("decision 6").

## Scope and shape

1. **The full stack, in one repository.** connect-zig holds a protobuf runtime (binary and proto3
   JSON), a Connect client and server, and the protoc plugin `protoc-gen-connect-zig`, which
   `buf generate` runs. It speaks three protocols, as connect-go does: Connect, gRPC and
   gRPC-Web. Beaten: a runtime alone, which leaves every user to write the RPC layer; and Connect
   alone, which cannot talk to gRPC servers.

2. **Three library modules and one executable.** `protobuf` knows no RPC. `connect` is the
   protocol core and knows no HTTP library: it reads header values and body bytes the caller
   passes, and writes header values and body bytes into storage the caller owns. `connect_colibri`
   is the one module that imports colibri. Beaten: one module over colibri, which ties the
   protocol rules to one transport and makes them harder to test.

3. **No I/O, and no clock.** The library makes no system call and reads no clock. A deadline is
   an instant in nanoseconds that the caller passes, as colibri passes time (colibri
   non-negotiable 3). The `io`, `determinism` and `heap` lint rules hold `src/` to it. Beaten:
   reading the clock for `Connect-Timeout-Ms`, which makes a test depend on the machine.

4. **No allocator in `src/`.** Every buffer is the caller's. Sizes are named constants or caller
   choices. The one exception is the plugin executable in `src/protoc_gen/`: it is a program, not
   the library, and it uses the arena `std.process.Init` gives it. Beaten: an allocator parameter
   on decode, which colibri and stdx both refuse (colibri non-negotiable 4, stdx non-negotiable 2).

## Protobuf

5. **Unknown fields are dropped in v0.** `decode` skips a field it does not know, groups included,
   and `encode` writes only known fields. Beaten: keeping them as a span of the input, which costs
   a field in every struct before any user needs it. Decision 24 keeps them.

6. **Decoding copies nothing.** A string or bytes field is a slice of the input. A repeated field
   is a `Repeated(T, kind)`: either `items`, which a program sets to encode, or a view of the
   enclosing message's bytes from the field's first record to its last, plus the field number,
   which an iterator reads (packed and unpacked). A singular message that may contain its own type is a `Lazy(T)`: encoded bytes or a
   pointer. Beaten: decoding into caller arrays, which needs a size for every repeated field.

   Cost: a view names one span. When a singular message field occurs twice in one input, and the
   first occurrence set a `Repeated` view or a `Lazy` field in it, the merge cannot hold both
   spans. `decode` then returns `error.MergeUnsupported` and fails closed, instead of keeping one
   occurrence's elements. A serializer never writes a message field twice, so this needs an
   input built by hand or by concatenation.

7. **Field types.** Implicit-presence scalars are plain values with defaults (`x: i32 = 0`).
   Explicit presence (`optional`, proto2) is `?T`. A singular message is `?Sub`, or `Lazy(Sub)`
   when it is recursive. A oneof is `?union(enum)`. A map is a `Repeated` of its entry messages.
   An enum is a non-exhaustive `enum(i32)`, so an unknown number decodes (proto3 enums are open).
   Its tags are the value names in lower snake case, and its `EnumDescriptor` lists the .proto
   names, aliases included, for JSON. Beaten: Zig tags spelled as the .proto names, which
   breaks the naming rule and cannot hold aliases.

8. **The table is named `protobuf`, and generated code imports the runtime as `proto`.** A
   struct's `pub const protobuf: Descriptor` is the name the design settled. A file that also
   names the import `protobuf` makes the reference ambiguous, which Zig refuses. Generated code
   and tests write `const proto = @import("protobuf");`.

9. **JSON decode transcodes to binary.** `decode_json` reads the JSON text with stdx's
   `json.TextReader` and writes the binary encoding into a scratch buffer the caller owns, then
   decodes that with `decode`. Strings and bytes then point into the scratch buffer. A nested
   message's length is written into a 5-byte placeholder once the message ends, and the body
   moves up to meet the octets the length needs, so the binary is canonical: an Any keeps its
   message's bytes as they are, and Go writes them canonical. Beaten: a second decoder that writes
   struct fields from JSON, which doubles the merge and presence rules.

## Connect

10. **Compression comes from stdx.** gzip and zstd encode and decode; brotli decodes only, since
    stdx has no brotli encoder yet. connect-zig accepts `gzip`, `zstd` and `br`. A program places
    the encoders it compresses with in `connect.Encoders`, and a server answers in the first
    coding the peer lists that it holds an encoder for. The zstd encoder runs at level 1 with a
    128 KiB window, which an RPC message rarely outgrows. connect-zig pins the stdx colibri
    pins, since two stdx in one binary repeat its exported symbols. Beaten: a C codec, which
    stdx exists to replace.

11. **Plain gRPC waits on colibri for the client.** colibri's `client.Response` holds no
    trailers, so a client cannot read `grpc-status` over h2. The server speaks gRPC now. The
    client speaks Connect for every stream type, through the end-stream message, and gRPC-Web,
    whose trailers are a body frame. Beaten: reading trailers below colibri's API, which colibri's
    rules forbid to a dependent. Lifted on 2026-11-05: colibri `2cf693b1` holds a response's
    trailers apart (colibri decision 152), and the client reads gRPC's status from them.
    Amended on 2026-11-09: `connect` still writes `te: trailers` for a gRPC request
    (PROTOCOL-HTTP2.md, "Requests"), since it serves any HTTP library. colibri adds its own only
    when the request names no TE (colibri decision 152), so the header goes once. A gRPC request
    sends no trailers. Beaten: leaving the header to colibri, which a `connect` caller on another
    HTTP library would then lose.

12. **Streams are whole bodies in v0.** colibri's router hands a route the whole request body,
    and a route writes its response into the response memory the router pool holds. A server
    stream is therefore bounded by `response_bytes`, and a bidirectional stream is half-duplex.
    Beaten: waiting for flow control in colibri before shipping any stream. A later step writes
    long streams at `on_writable`. Decision 18 lifts the half-duplex part for type handlers.
    Amended on 2026-11-09: a client's streamed call sends its request and reads its response in
    pieces, through colibri's pool (colibri decision 153), so the client side of a stream is no
    whole body. The server side keeps this decision's bounds.

13. **Examples run in cleartext.** The ELIZA programs speak h2 with prior knowledge and h11, and
    hold no TLS identity, so they need no certificate to run. colibri's `tls` module still links
    chapulin, so each program defines `ch_assert_fail`. Beaten: colibri's test identity, which
    colibri does not package. Decision 25 adds a round over h3, under a test identity
    of the examples' own; the cleartext rounds stay.

14. **A handler returns its error as a value.** A handler fills its response and returns null, or
    returns the `connect.RpcError` the client reads. A Zig error from a handler is a fault, which
    the route table's `error_handler` answers. Beaten: a Zig error set per handler, which cannot
    carry a message or details.

17. **Generated code passes every lint rule the tree runs, but file-length.** Two choices
    follow from it:
    - Each message numbers its fields in a `FieldNumber` enum, and its descriptor names each
      number through it, as the magic-numbers rule asks. An enum's table names numbers through
      its tags. Hand-written messages use the same shape, through `proto.field_of`.
    - A generated file imports another by module name, never by a path with `../`, as the
      relative-import rule asks. Its header names the modules the build gives it: the module of
      `kitchen/v1/shared.proto` is `kitchen_v1_shared`.
    Each .proto file becomes one `<file>.pb.zig`, whatever its length, and the file-length rule
    skips `.pb.zig`. The cognitive-complexity score still reads it, with the same limit of 15. protoc-gen-go writes one file per .proto file, and prost-build one per
    package, with no limit. Beaten: exempting `.pb.zig` from every rule, as colibri exempts its
    generated tables from magic-numbers, which would leave a project's own lint failing on the
    code it generates; and, first chosen and then dropped, a file for each declaration of a long
    .proto file, which turned `coverage.proto` into 28 files and left a message of more than about
    160 fields too long all the same.

18. **A type handler streams full-duplex.** A client or bidirectional stream's handler may be a
    type with `on_message` and `on_end`. Its route sets no `.whole_body`, so colibri hands it the
    body as it arrives, and it passes each whole envelope on and keeps a partial one for the
    next read. Each message a `Sender` writes is flushed to the endpoint at once. Over h2 a
    client reads answers while it still sends; `tools/interop_check.sh` checks it with buf curl.
    A function handler still takes its stream whole. Beaten: a handler that blocks on a
    `Receiver`, which needs a thread or a coroutine the library does not have.
    Amended by the owner on 2026-11-09: a client streams full-duplex too, over h2 and h3.
    - `ClientCall.init_stream` builds a client or bidirectional stream whose two bodies go in
      pieces (colibri decision 153 ruling 7). Its `Sender` writes each message, as the server's
      does, and `close_send` ends the request. The pool holds one piece at a time, so a message
      written meanwhile waits and goes at the next `body_taken` event.
    - The program passes the pool's `headers`, `body` and `body_taken` events to the call. Each
      response piece is copied after the octets not read yet and given back at once, so an
      envelope two pieces split is read whole, and the call's `reader` reads each message.
    - `rpc.full_duplex(protocol)` decides the mode: full-duplex over h2 and h3, half-duplex over
      h11, where the whole request goes before the response is read. The Connect protocol
      ("Streaming RPCs") leaves the duplex a call can use to the HTTP version; the owner ruled
      h11 half-duplex on 2026-11-09, since proxies that buffer an HTTP/1.1 body would stall an
      interleaved one. The library sends and reads the same way over each; the program follows
      the mode.
    - Interceptors see a streamed call as they see any: `on_request` before the first message,
      with an empty body, and `on_response` once, at the response's head.
    - Unary and server-stream calls keep `init` with every message.
    Beaten: pointing colibri's `Response.body` at the free end of the gathering buffer, which
    changes a slice the pool reads during the exchange (colibri decision 124); a pool behind
    function pointers, which decision 19 beat for interceptors, where `ClientCallOptions.pool`
    names its type; and a `Sender` that refuses a message while the pool holds a piece, which
    makes every program keep its own queue.

19. **Interceptors are types, chosen at compile time.** A route lists its interceptors in its
    options. Each may define `on_call`, which runs in list order and may refuse the call, and
    `on_finish`, which runs in reverse and returns the outcome the client reads. A client's
    `ClientCall` lists `on_request` and `on_response` interceptors the same way, in its options:
    `ClientCall(method, .{ .interceptors = ... })`, as a route takes `RouteOptions`. A handler and
    an interceptor read the call through `Call`: its protocol, codec, timeout and request
    headers, and the response headers and trailers they add. Beaten: a runtime list of function
    pointers, which costs an indirect call and loses the `app` type; and, amended 2026-11-07, a
    `ClientCallWith(method, interceptors)` beside `ClientCall(method)`, which named two types for
    one and left no room for a client option but interceptors.

20. **Examples share their services.** The programs in `examples/` import the ELIZA and demo
    services, the in-memory link and its client loop from `examples/services/`, so each program
    holds only its calls and its checks. The socket server serves both services. Beaten: one
    copy of the link loop per program.

21. **An Any's JSON names its type from a comptime list.** Writing or reading an Any in JSON
    needs the type its URL names. The well-known types are always in the list. A program adds
    its own with `pub const protobuf_any_types: []const type = &.{ ... };` in its root file, or
    passes them to
    `encode_json_with` and `decode_json_with`, which a test needs since a test's root is the
    test runner. The list is a `[]const type`, as std passes a list of types, not a tuple
    (amended 2026-11-07). A type outside the list fails with `UnknownAnyType`. Beaten: a runtime registry,
    which needs an allocator or a fixed table of function pointers, and loses comptime decoding.

22. **A message is encoded into the body it goes out in.** The server encodes each reply message
    into the free space of the response writer's buffer, after room for its envelope prefix, and
    the client into its request body, so no message is copied from scratch storage. gzip, when it
    shrinks a message, compresses into scratch storage and copies the shorter result back. A
    server message that does not fit the buffer, and a Connect unary reply that may be
    compressed, whose head names its coding, go through scratch storage as before. A 16 KB
    stream message takes 0.38 us against 3.3 us. Beaten: always encoding into scratch, one copy
    per message more.

23. **The plugin reads editions 2023 and 2024, and the runtime writes groups.** The plugin
    resolves three features for each field, from its file down through its messages: presence,
    which makes a singular field a `?T`; repeated encoding, packed or expanded; and message
    encoding, where DELIMITED makes a message field a `.group`, written between start and end
    tags as a proto2 group is. A map entry's fields never have presence. LEGACY_REQUIRED reads
    as explicit, since the runtime checks no required field. Beaten: refusing edition files, which
    buf generates by default for new modules. Amended on 2026-11-05: the plugin resolves
    `enum_type` and `utf8_validation` too, as protobuf.dev's editions overview defines them. A
    closed enum's descriptor says `closed`, and a number it does not name goes to the unknown
    fields: a singular or oneof field stays as it was, a repeated field's iterator passes over it,
    a map passes over the whole entry, and `encode` writes each back. A string field with NONE has
    the kind `.unvalidated_string`, which no parser checks and JSON still refuses when it is not
    UTF-8. upb is the reference for both, through `tools/coverage_check.sh`, since Go treats closed
    enums as open. `json_format` changes nothing: JSON is strict for every file.

24. **A generated message keeps the fields it does not know.** Its struct ends with
    `_unknown: proto.Unknown`, the span of the input from its first unknown record to its last.
    `encode` writes those records back after the known fields, as Go and C++ do, and skips the
    known records the span also holds. So a service built on an older schema passes a newer
    client's fields on, as `tools/coverage_check.sh` checks against Go. A map entry keeps none,
    and a message merged from two inputs fails with `MergeUnsupported`, as a view does
    (decision 6). JSON writes no unknown field (proto3 JSON mapping). Beaten: dropping them, as
    v0 did (decision 5), which loses data a proxy forwards.

25. **The examples run h3 too, under a test-only identity.** Each program over the in-memory link
    adds a round over h3: QUIC over colibri's datagram link. The server presents a P-256 CA and a
    leaf for `localhost` from `examples/testdata/tls`, which `tools/test_identity.sh` mints with
    openssl, and the client trusts the CA. Both certificates are valid from 2020 to 2099, and the
    programs judge them at the fixed instant 1_800_000_000. The key is public and for tests
    alone: no module of `src/` reads it. The rounds over h2 and h11 stay in cleartext (decision
    13). Beaten: colibri's test identity, which colibri does not package; and minting an identity
    at each run, which needs openssl in every build.

26. **The conformance suite runs against a server of its own.** `conformance/` holds a program
    that serves connectrpc's ConformanceService on a socket the kernel picks, as the runner's
    server mode asks. It runs on `colibri.Server` in cleartext, as the example socket server
    runs on it over TLS (decision 31). `tools/conformance_check.sh` downloads runner v1.0.4, pinned by
    SHA-256, and `conformance/known_failing.txt` names each case that fails on purpose, with the
    reason; the runner fails when a listed case passes. The client half waits on colibri's
    client (decision 11). Beaten: the runner's reference server against our client alone, which
    leaves the server untested; and a copy of the loop in each program.
    Amended on 2026-11-09: the client half no longer waits. `conformance/client.zig` runs the
    runner's client mode against its reference server, over h11, h2 and h3, in cleartext and
    over TLS, with the features of `conformance/client_config.yaml`. It drives one
    `client.ConnectionPool` with `poll` over a TCP and a UDP socket, one case at a time
    (decision 32): `colibri.Client` takes no streamed exchange and no cancel. Each case it fails
    on purpose is in `conformance/client_known_failing.txt` with its reason, and each it may fail
    in `client_known_flaky.txt`. Beaten: a Rotor loop of the program's own, which needs the
    socket bookkeeping of colibri's `client_tcp.zig` for one connection at a time.

27. **A method Connect does not serve gets 405.** colibri's router answers 501 for a method no
    route of the table names, and 405 with an Allow header for one that a route names on another
    path (colibri decision 122). connect-go answers 405, and the conformance suite asks it. So a
    table joins `rpc.Refusals(App, method).routes` once: on that method's path they answer 405
    with Allow, and on every other path colibri answers 405 itself. A method outside RFC 9110's
    eight and PATCH still gets 501, as RFC 9110 §15.6.2 says. Beaten: refusal routes on every
    path, which multiply the table for no other answer; adding the entries to the generated
    `Routes`, which a table of several services would then name twice; and a change to
    colibri's router, which is colibri's ruling.

28. **The socket server speaks h3 on the UDP port of its TCP port.** `socket_loop.zig` opens a
    datagram socket on the same Rotor loop when `quic_connections` is set, with one multishot
    receive into buffers the loop owns and a slot for each datagram in flight, as colibri's
    `src/testing/udp.zig` does. The example server presents the test identity of decision 25,
    and draws its keys and each TLS session's secrets from `std.Io`'s entropy. The conformance
    server stays in cleartext. Beaten: a second loop for UDP, which splits one clock in two; and
    waiting for colibri's `colibri.Server` (colibri decision 150), which colibri had not built.
    Decision 31 moves both servers onto `colibri.Server`, which colibri v0.14.0 ships.

29. **Clients in other languages call the server, across the protocol and every type.**
    `interop.v1.InteropService` has each RPC shape once, and each message is a
    `coverage.v1.Everything`. `interop/` holds clients on connect-go and grpc-go, connect-es,
    grpcio and tonic, each pinned by its lock file, which echo every coverage case in each
    protocol, codec and compression their library speaks, and run every stream shape, a typed
    error, a timeout, headers and trailers. Two messages are the same when a runtime writes the
    same octets for both. The client side waits for `colibri.Client` (colibri decision 153).
    Beaten: buf curl alone, which is one client; and the conformance runner alone, whose
    reference client is connect-go.

30. **CI gates performance on instruction counts.** `tools/perf_check.sh` counts each benchmark
    operation under callgrind, on an x86-64-v3 build, and fails past 2% above
    `bench/instructions.txt`. Counts repeat exactly on one build, so a shared runner judges them as
    a quiet machine would. Beaten: wall time on shared runners, which moved 2x between runs here;
    and a dedicated machine, which this project does not have.

31. **Both socket servers run on `colibri.Server`, and the example one is TLS everywhere.**
    colibri v0.14.0 ships `colibri.Server` (colibri decision 150), so `socket_loop.zig` and
    `socket_datagram.zig` go. With an identity, colibri puts TLS on TCP, picks h2 or h11 by ALPN,
    serves h3 on the UDP socket of the same port, and advertises it in Alt-Svc. The example server
    keeps the test identity of decision 25, so curl, buf curl and the clients of `interop/` trust
    its CA. The conformance server holds no identity and stays in cleartext, as the runner asks.
    A connection past the socket limit waits in the kernel's backlog until a socket frees, as
    colibri rules. Beaten: a server with no identity, which drops h3; and keeping our loop, a copy
    of colibri's.

32. **The library runs on any event loop.** Ruled by the owner on 2026-11-08. `connect_colibri`
    builds on colibri's protocol modules alone: `server`, `client` and `http`, which take octets
    and give octets back. No file in `src/` names `rotor` or colibri's `colibri` module, whose
    `Server` and `Client` own a Rotor loop. `build.zig` gives the library no such module, and the
    `layering` lint rule reports a reference to either. So `rpc.ClientCall` stays on
    `client.ConnectionPool` when `colibri.Client` ships, and the example programs show Rotor as
    one way to run the library. `examples/std_io_server.zig` and `examples/std_io.zig` prove it:
    they run the engine and the pool on Zig 0.16's `std.Io` alone, with no Rotor. Beaten:
    building on `colibri.Client` and `colibri.Server`, which is shorter for a Rotor program and
    makes every program adopt Rotor and its task model.

## Tooling

15. **pepegrillo is lazy.** `build.zig` requests it only when `b.pkg_hash.len == 0`, so a project
    that depends on connect-zig never fetches it, as in colibri (colibri decision 36).

16. **CI downloads Zig 0.16.0 and buf 1.74.0 pinned by SHA-256**, and every check a person runs
    is one `zig build` step or one script of `tools/`, as in colibri's workflow (colibri decision
    47).
