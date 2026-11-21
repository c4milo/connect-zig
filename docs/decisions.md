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

39. **The package exports the colibri modules a program builds on.** Ruled by the owner on
    2026-11-14.
    - `build.zig` exports colibri's `server`, `client`, `http`, `tls` and `colibri` modules under
      colibri's own names. A program takes them as it takes `connect_colibri`:
      `dependency.module("server")`.
    - A program thus builds its router, its server and its client on the one colibri that
      `connect_colibri` uses. Two colibri instances in one build fail: Zig finds one file in two
      modules.
    - The build option `rotor` goes to colibri. With `.rotor = true`, a program gets the
      `.private` kinds of `colibri.Server` and `colibri.Client`, which run on Rotor. Without it,
      a dependent fetches no Rotor, and the library still needs none (decision 32).
    - `tools/package_check.sh` proves it. A project that depends on connect-zig alone generates
      code with the plugin, and serves a method over TLS on TCP and over h3 on UDP, under the
      test identity (decision 25). It calls the method with `connect_colibri`'s client over h2
      and h3, and with curl over h11.
    - Why: before this, a project that followed the README could not reach `server.Router` or
      `client.ConnectionPool`. A project that added colibri itself got a second instance, unless
      it passed connect-zig's three arguments exactly. It could not build on Rotor at all.
    - Beaten: the README states the three arguments that colibri takes, and a `rotor` option. A
      program then repeats connect-zig's request, and a change of that request breaks it.

41. **Each example is a Zig project of its own.** Ruled by the owner on 2026-11-14.
    - `examples/<name>/` holds `build.zig`, `build.zig.zon`, `buf.gen.yaml`, `proto/`, `gen/` and
      `src/`. Its manifest names connect-zig by path, `../..`. A reader copies the folder, and
      swaps the path for a URL.
    - `examples/harness` is a package, not an example: colibri's in-memory links, the server and
      client rounds over h11, h2 and h3, the test identity and chapulin's hook. Each project that
      runs in memory depends on it by path. `socket_server` depends by path on the projects
      whose services it serves.
    - `examples/quickstart` is the README's "Use it in your project", as a project.
      `tools/package_check.sh` builds it against a fetched copy of connect-zig, so no program
      source lives in a script.
    - The root's `zig build examples` runs `zig build test` in each project, with the root's
      package folder and cache. So the tree fetches each package once and compiles each module
      once. `zig build example-<name>` and `zig build run-eliza-server` stay.
    - The coverage converter, the interop client and the test of the generated code are checks,
      not examples. They move to `tools/`, with the schemas that only they read.
    - Why: a reader copies one folder and has a program that builds. Each project writes the
      build that a dependent writes, so the examples prove decision 39 too.
    - Beaten: one build for every example, which hides the build a project writes; and a copy
      of the harness in each project, which repeats about 900 lines in six places.
    - Amended the same day, on the owner's choice: each example owns the schema it is about, and
      no project holds every proto. `demo.proto` splits into one schema for each of streaming,
      interceptors and errors. A project that builds on another example's service, such as
      `socket_server`, `std_io` and `sans_io_call`, depends on that project by path and imports
      its exported modules. The interop service, which only the checks call, moves to
      `tools/interop_server` with a server of its own. `large.proto` stays beside
      `kitchen.proto`, whose `shared.proto` it imports. Beaten: one project of every proto,
      which makes each example depend on schemas it does not use.
    - Amended again the same day, on the owner's choice: each example is also a program to play
      with. `zig build serve -- [port]` serves its service on a real socket, over TLS under the
      test identity, on h11, h2 and h3, through the harness's `Served`. Each project keeps its
      `App` and route table in `src/app.zig`, which the check and the server share.
    - A project that depends on another passes connect-zig the same options, or Zig builds a
      second `connect` module. `eliza` and the harness take a `rotor` option for a project with
      no Rotor, such as `std_io` (decision 32).

42. **Every tree of hand-written Zig takes the library's rules.** Ruled by the owner on
    2026-11-14.
    - `examples/`, `bench/`, `conformance/` and the programs of `tools/` take every lint rule
      that `src/` takes, except the four that state what a library is: no allocator, no I/O, no
      clock and no Rotor. A program owns its memory, its sockets, its clock and its loop. `tools/`
      joined when the checks moved there from `examples/` (decision 41).
    - Each tree names its limits in a `constants.zig`, as `src/` does (the `magic-numbers`
      rule).
    - A program holds no container-level `var` (the `global-state` rule). Its `main` allocates
      one `State` from `init.arena` before the first call, and hands a pointer to each function.
      TigerStyle allocates once, at startup, in the same way. The allocator gives the type's
      alignment, which Zig 0.16's x86_64 backend does not always give a static.
    - Why: a reader copies an example into a program, so the rules that hold the library to its
      bar hold the copy to it too. The package check's program lived in a shell script that no
      rule read, and a misaligned static reached CI that way.
    - Beaten: one aligned static `State` that the rule allows by name, since pepegrillo's rule
      has no such option; and `threadlocal` statics, which break `std_io_server`'s queue, which
      its tasks share across threads.

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

   Amended on 2026-11-13 by decision 37: `decode_into` reads each repeated field's elements
   into storage the caller passes, once, and `decode` keeps the views above.

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
   Amended on 2026-11-14: `decode_json` decodes the transcoder's binary one level, as
   `Lazy.get` decodes bytes `decode` checked, and does not check each nested payload again.
   The transcoder read the JSON to its full depth and checked each value as it wrote it: stdx
   refuses a lone surrogate and any text that is not UTF-8, and each scalar is parsed into its
   field's type. A test, and a fuzz test, hold that what the transcoder writes passes `decode`
   whole. The second check read each subtree again, and cost tree's JSON decode 30% more
   instructions, as the owner asked on 2026-11-14 to cut JSON decode on arm64.
   Amended on 2026-11-14 again: an array of a field the descriptor packs is written as one
   packed record, as an encoder writes it, where each element was a record of its own. The
   binary is canonical then, as an Any keeps it, and the decode reads one record for the array.

## Connect

10. **Compression comes from stdx.** gzip and zstd encode and decode; brotli decodes only, since
    stdx has no brotli encoder yet. connect-zig accepts `gzip`, `zstd` and `br`. A program places
    the encoders it compresses with in `connect.Encoders`, and a server answers in the first
    coding the peer lists that it holds an encoder for. The zstd encoder runs at level 1 with a
    128 KiB window, which an RPC message rarely outgrows. connect-zig pins the stdx colibri
    pins, since two stdx in one binary repeat its exported symbols. Beaten: a C codec, which
    stdx exists to replace.
    Amended on 2026-11-10: base64 comes from stdx too, for proto3 JSON's bytes, Connect's error
    details, gRPC's "-bin" values and a unary GET's message. stdx's decoder reads either alphabet
    in one pass and refuses a text that mixes them. It refuses pad characters that do not
    complete a quantum of four (RFC 4648 §4), which connect-zig's own reader dropped before.
    Beaten: `std.base64`, which reads one alphabet in a call, so a reader that takes either one
    tried each in turn.
    Amended on 2026-11-16: brotli encodes too, since stdx v0.1.1 holds an encoder.
    `connect.BrotliEncoder` runs at level 1 with a window of 128 KiB (WBITS 17, RFC 7932 §9.1),
    as the zstd encoder does, and takes 519 KiB, where the zstd encoder takes 1.4 MiB. A program
    places it in `Encoders.brotli`. Beaten: stdx's default window of 256 KiB at level 1, which
    costs 128 KiB more for the messages past 128 KiB alone, and level 5, which takes 3.2 MiB at
    the least.

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
    Amended by the owner on 2026-11-09, a second time: a type handler with `next` sends a stream
    of any length (decision 33). A function handler keeps this decision's bound on what it
    writes in its one call.

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
    one and left no room for a client option but interceptors. Amended 2026-11-11: a server
    hook takes the call's `Context`, `AnyRequest` and `AnyResponse`, and `Call` goes (decision
    36). Amended 2026-11-21: an interceptor may also define `on_message`, which runs in list
    order with each request message once it is decoded, and may refuse the call (decision 47).

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
    Amended by the owner on 2026-11-09: a client compresses each request message in the coding
    it asked for, as connect-go does, whether or not the coding shrinks it. Its head names the
    coding: Content-Encoding for a Connect unary request, connect-content-encoding or
    grpc-encoding for a stream, and each envelope is flagged compressed. `client.Options`
    gains `compress_len_min`, default 0, below which a message goes as it is, so a program may
    still skip tiny messages. A server's replies keep the floor of 1 KiB and the shrink test: the
    Connect protocol ("Compression") and PROTOCOL-HTTP2.md ("Message-Encoding") let a sender
    send any message uncompressed, and the reply's head names the coding it chose. Beaten: the
    shrink test on requests, which sent a Connect unary request under 1 KiB with no
    Content-Encoding, so a server that checks the coding it was promised refused it.

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
    at each run, which needs openssl in every build. Amended 2026-11-14 (decision 39):
    `tools/package_check.sh` copies the identity into the project it builds. That project's
    server presents it over TLS for h11, h2 and h3, and its client and curl trust the CA. The
    check is a test too, and the fetched package does not hold the identity.

26. **The conformance suite runs against a server of its own.** `conformance/` holds a program
    that serves connectrpc's ConformanceService on a socket the kernel picks, as the runner's
    server mode asks. It runs on `colibri.Server` in cleartext, as the example socket server
    runs on it over TLS (decision 31). `tools/conformance_check.sh` downloads runner v1.0.7, pinned by
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
    Amended on 2026-11-16: the runner is v1.0.7, where it was v1.0.4 (design §8 step 25). It
    sends 16 calls at once in server mode, as many as the server's router holds. The server
    keeps an idle connection 30 s, colibri's default, and holds 512 sockets for the grpc-go
    client, which leaves a connection open for each case.
    Amended on 2026-11-17: the server waits 120 s for a connection's first request and between
    requests, past the 90 s that Go's client keeps a connection. Go's client opens connections
    it may not use at once. At a first-request wait of 5 s, CI's run 173 failed one h11 case
    with "unexpected EOF". Beaten: colibri's defaults, which close a connection the client may
    still send on.

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
    same octets for both. Beaten: buf curl alone, which is one client; and the conformance
    runner alone, whose reference client is connect-go.
    Amended on 2026-11-09, with the client half the owner approved: the client side runs too,
    on `rpc.ClientCall` over `client.ConnectionPool` (decision 32), not on `colibri.Client`.
    `interop/` also holds servers on connect-go and grpc-go, connect-node, grpcio and
    connect-rust, each pinned by its client's lock file. `examples/interop_client.zig` runs every
    scenario against each, in each protocol, codec and HTTP version the server speaks, and
    `tools/interop_servers_check.sh` runs it. connect-zig writes no map in a deterministic order,
    so where the octets differ the client compares the two messages' proto3 JSON as values.
    Beaten: a third transport, where the conformance client's already drives a pool over TLS.

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

33. **A long stream's handler gives one message at a time.** Ruled by the owner on 2026-11-09.
    A type handler of a server or bidirectional stream may declare `next`, which fills one
    response and answers `rpc.Next`: `.message`, `.wait`, `.end` or `.failure`. A server stream's
    type handler takes its one request in `on_request`.
    - The route declares colibri's `on_writable`, and calls `next` while the response memory has
      room. So colibri's `response_bytes` bound the octets in flight, not the stream (colibri
      decisions 103 and 127 as amended on 2026-11-09).
    - A message that found no room stays in the call as one envelope, and goes out first at the
      next call. The handler never sees a full writer, and never gives a message twice.
    - Each envelope goes to colibri's writer as one slice, which that writer takes whole or not
      at all. `Reply.prepare` leaves room for the prefix before the message, so no copy joins
      them.
    - The route builds the stream's end once, when the handler ends the stream, and writes it
      when the memory has room. The handler's memory may change in between.
    - Each call of `on_writable` ends with one flush, so the client reads the messages of a
      call before the next call.
    - colibri's `end` and `trailers` can return `error.Full` or `error.NoSpaceLeft`, which
      leave the response as it was. The route then returns, and makes the call again at the
      next `on_writable`.

    Limits. `.wait` is for a bidirectional stream whose client still sends: colibri cannot yet
    wake a route whose request ended (colibri issue 130), so the route answers `internal` there.
    An envelope longer than the response memory never fits, and colibri then cancels its call,
    so a route table that streams sets `response_bytes` above `message_bytes`. Beaten: a handler
    with `on_writable` and a `Sender` whose `send` fails when the writer is full, which makes
    each handler keep its own position, and which colibri cancels when a call sends nothing; and
    a function handler that blocks in `send`, which needs a thread or a coroutine the library
    does not have (decision 18).

34. **OpenID Connect tokens are checked in a module of their own, `oidc`, on chapulin.** Ruled
    by the owner on 2026-11-11. A server that takes bearer tokens from an OpenID provider is
    common, so the library holds the check: a `Verifier` with no I/O, and a server interceptor
    that lets the paths a program names through.
    - The signature check and base64url are chapulin's `jws` calls: RS256, ES256 and EdDSA
      with Ed25519. The module reads the JSON with stdx, and checks the claims itself. It names
      no colibri module, and colibri exports no crypto of chapulin's: the owner refused both a
      path through colibri's `dnssec` module and a signature module in colibri.
    - connect-zig names chapulin in its own `build.zig.zon`, at the commit colibri pins, and
      asks for its object with colibri's own request (`build/chapulin.zig`). Zig keys a
      dependency by its package and its options, so a program that links colibri and `oidc`
      links one chapulin object; a request that differs in one value fails the link with a
      duplicate symbol (decision 10). Amended 2026-11-12: since colibri v0.16.2 that request
      holds `JWS=on` and `SCRAM=on` itself (colibri decision 162), so `oidc` links beside
      `connect_colibri`. chapulin builds `jws` for a host target alone, so another target has
      no `oidc` module.
    - The program fetches the issuer's JWK Set, and passes its text to `set_keys` and the time
      to `set_time` (decisions 3 and 4). `keys_stale` says when a token named a key the
      verifier does not hold.
    - Each key verifies with one algorithm, which its JWK fixes (RFC 8725 §3.1). The key comes
      from the verifier's set, never from the token. `VerifierOptions.algorithms` takes all three by
      default, because no token can move a key to another algorithm.
    - The order of the checks is RFC 7519 §7.2's: the form, the header, the signature, then
      the issuer, the audience, "exp" and "nbf". No claim is read before the signature passed.
      A token with no "exp" is refused, as OpenID Connect Core 1.0 §2 and RFC 9068 §2.2
      require one.
    - A name the module reads appears once in its object, in a header, a claims set and a JWK.
      The RFCs let a parser refuse a second one, and the refusal leaves no two readings of one
      text.
    - The claims belong to the call (amended 2026-11-11, decision 35). `verify` writes them
      into a `Claims` the caller owns, which holds a copy of the subject and of the payload. The
      interceptor verifies into its call's values, the field `oidc`, a
      `?oidc.Claims`, which stays null on an excluded path and after a refusal. A handler reads
      `ctx.values(Values).oidc` at any callback of its call, the tenth message of a stream
      included.
    - A program reads its own claims on demand, with `Claims.string`, `integer` and `holds`
      over the payload's copy. A string a lookup returns stays valid until the next lookup on
      the same `Claims`. A claim nobody asks for costs nothing.
    - `Interceptor(.{ .exclude = ... })` takes its list at compile time, because a generated
      `Routes` gives one interceptor list to each method of a service. An entry is a method's
      path, or a service's prefix that ends in "/". Its `on_call` takes any call type with
      `path`, `request_header` and `add_header`, so the module serves another transport too.
    - A refused call gets `unauthenticated`, which Connect writes as HTTP 401, and RFC 6750
      §3's `WWW-Authenticate: Bearer` challenge, with `error="invalid_token"` when the call
      carried a token.

    Limits. One issuer and one audience for each verifier, and 8 keys. An RSA key holds 2048
    to 4096 bits. A token holds 4096 characters at most, which is what a route copies of a
    request's headers. A string a lookup returns holds `claim_bytes_max` octets at most. A
    `Claims` takes about 4.4 KB of each call's values. A NumericDate with an exponent
    is refused.
    The module reads no "typ",
    "nonce", "azp" or "at_hash": those belong to the client that ran the login, not to the
    server that takes the token. Beaten: Zig's `std.crypto`, which the owner refused for
    chapulin; one copy of the JWT code in colibri, which the owner refused for a copy in each
    library; claims in the verifier, valid until its next `verify`, which a later callback of a
    stream read wrong (this decision's first form); a struct of claims the program declares,
    which stdx's typed decoder cannot fill, since it refuses the members a struct does not name,
    and which needs a bound for each string and array; and an exclusion list read at run time,
    which a comptime list makes free for a route with none.

35. **A call keeps values of the type the program declares.** Ruled by the owner on
    2026-11-11. What an interceptor learns about a call belongs to that call: the claims of its
    token, the user a rate limit counted, an identifier a log prints. Before this decision it
    lived in the program's `App`, which every call shares. So a stream's later callback could
    read what another call wrote in between.
    - `RouteOptions.Values` is a struct whose fields each have a default, `struct {}` when the
      program names none. The route keeps one in each call's state. colibri sets that state to
      its defaults at each request, so every call starts with `.{}`.
    - An interceptor and a handler read it at any callback with `ctx.values(Values)` (decision
      36). The call keeps a pointer to it and the name of its type, and an assertion compares
      the name, so a read with the wrong type fails at once. A library's interceptor that
      writes into it takes the program's type as a parameter, as `oidc.Interceptor(Values, ...)`
      does.
    - Each request entry of the router grows by `@sizeOf(Values)`.

    Beaten: a `State` for each interceptor, read through the interceptor's type, which needs a
    table keyed by type in the call, and gives two interceptors no slot they share; a generic
    `CallWith(T)`, which changes every signature for one type; a hook that takes the values as
    a parameter of its own, which gave each hook two signatures (this decision's first form);
    and the names `Local`, `Locals` and `RequestContext`, before the call's own object took the
    name `Context`. The owner chose `Values`, connect-es's word for the same values.

    Amended on 2026-11-15, at colibri v0.17.0 (decision 45). The values live in colibri's request
    context. The route table names their type as `.Values`, colibri starts each request with its
    defaults, and `ctx.values(T)` reads them through colibri, which halts a read with another
    type. `RouteOptions.Values` goes. A table names one type for all its routes, so a table that
    joins services declares one struct with the fields of each.

36. **A handler takes the call's context, its request and its response.** Ruled by the owner on
    2026-11-11 ("ctx, request and response split is cleaner"), as connect-go splits a call
    into a `context.Context`, a `Request` and a `Response`. `Call` goes; it held all three.
    - `Context` is the call: its path, protocol, codec and timeout, the counts of the messages
      it read and wrote, and `values(T)` (decision 35). A handler's parameter is `ctx`.
    - `Request(T)` holds one message and the request's headers and query. `RequestStream(T)`
      reads a stream's messages with `next`, and holds the headers and query too. It replaces
      `Receiver`.
    - `Response(T)` holds one message to fill, and adds response headers and trailers.
      `ResponseStream(T)` sends each message with `send`, and adds headers and trailers too. It
      replaces `Sender`.
    - A function handler takes `(app, ctx, request, response)`, each of the kind its stream
      type needs. A type handler's callbacks take `(app, ctx, state, ...)` with the same
      kinds: `on_message` a `Request` and, for a bidirectional stream, a `ResponseStream`;
      `on_request` a `Request`; `next` a `Response`; `on_end` an `AnyRequest`, whose headers
      last to the stream's end, and a `ResponseStream` or a `Response`.
    - An interceptor takes `on_call(app, ctx, *const AnyRequest, *AnyResponse)` and
      `on_finish(app, ctx, *AnyResponse, ?RpcError)`: the request and the response without a
      message, as connect-go's `AnyRequest` and `AnyResponse`. Amended 2026-11-21: `on_message(app,
      ctx, comptime T: type, *const T)` is the one hook that takes a message, of any type, so
      one interceptor serves every method (decision 47).
    - Each of these is a view of the call the route keeps, valid during the callback that
      receives it. A program keeps nothing of it past the callback but what it copies.

    Beaten: one object for the call, its request and its response, as connect-es's
    `HandlerContext`, which the owner found less clean; messages as plain parameters with the
    headers on two more, which gave a unary handler six parameters; and bare messages in a type
    handler's callbacks, which read headers another way than a function handler does.

37. **A second decode takes storage the caller owns, for the elements of repeated fields.**
    Ruled by the owner on 2026-11-13, after the owner wrote "we need to beat buffa on binary
    encoding and decoding for medium size docs". It amends decision 6.
    - `decode_into(T, bytes, storage)` decodes as `decode` does. It also reads each run of a
      repeated field's records once, into elements in `storage`, and each `Lazy` field's
      message. An iterator then reads them as a slice, and parses nothing again.
    - A field whose records come in two runs, and a run that finds no room, keep decision 6's
      view. A closed enum's field keeps it too. `decode_into` refuses the inputs `decode`
      refuses, with the same error.
    - Strings and bytes still point into the input. A message from `decode_into` points into
      the input and into `storage`, and both must outlive it.
    - A run whose elements hold no repeated field and no message of their own takes one pass:
      each element follows the one before. Any other run is counted first, so its elements stay
      together while their own runs take storage after them.
    - The decoder's mode, `stored`, is known at compile time, so `decode` compiles as before.
    - The owner named the call `decode_into` on 2026-11-13: it says where the elements go. It
      beat `decode_stored`, the name the call first shipped with, and `decode_eager`.
    - connect's codec takes `decode_into` for a binary message when its `Scratch` holds
      storage. Each route holds `message_bytes` of it by default, which the owner chose over
      none (design §8 step 15).
    - An iterator gives a message in place (design §8 step 16). `next` returns `?Item`: for a
      message, a pointer that holds until the next call, into `items` or into the iterator's
      own slot for a message of a view; for a number, a string or an enum, the value. The
      owner ruled it on 2026-11-14. It follows TigerStyle's `*const` for a value of more than
      16 octets, and std has iterators whose `next` returns a pointer. No std iterator chooses
      by a compile-time parameter, so the iterator names the choice `Item`. Before, `next`
      returned each message by value, and a walk copied a 56-octet node three times: with
      messages in place and a run counted with no call, tree's decode with every field read
      took 4.5 µs where it took 10.0 µs, on an EPYC 9V74. It beat a second method `next_ptr`
      beside `next`, which the owner ruled first and then replaced, since one method reads a
      field; a pointer for every element, where a number needs `.*` at each read and passes
      through the slot; and a slot the caller passes, which adds a line at each call.
    - Why: a program that reads every field parsed each repeated field twice, once when
      `decode` checked it and once when the program read it. So Buffa's decode with every field
      read beat connect-zig's on medium, large, tree and packed.

    Beaten: one `decode` that takes storage, `&.{}` for none. The owner chose it first, then
    chose two calls once it was measured: 76 call sites passed no storage, and the empty path
    took 4% to 39% more instructions. Also beaten: an array for each repeated field, as decision
    6 beat it, where one slice serves every field; and `decode` alone, which parses each repeated
    field twice.

    Cost: a second decode call, and a second copy of the decoder in a program that calls both. A
    run that is counted first reads its records' tags twice.

44. **A client interceptor takes the program's context, as `std.sort` takes one.** Ruled on
    2026-11-15. A client call's options name a `Context` type, `void` by default. `init` and
    `init_stream` take a value of it, and each hook gets that value first.
    - The hooks are `on_request(context, *connect.client.Request) !void` and
      `on_response(context, *connect.client.Response) void`. A server interceptor gets the
      program's `app` first in the same way (decision 36).
    - The program chooses the type. A pointer, such as `*State`, lets an interceptor count or
      record what it sees. A call with no interceptor, or one whose interceptors need nothing,
      names no type and passes `{}`.
    - The call keeps the value from `init` until it ends, since `on_response` runs at the
      response's head, in `on_headers` or in `read`.
    - Why: a client interceptor had no place for state but statics, and decision 42 removed
      them. So the interceptors example lost its check that counts each response (design §8
      step 19).

    Beaten: a context pointer of `*anyopaque` in each call, which a hook would cast; the
    program's `App` as a type parameter of `ClientCall`, which every call names even with no
    interceptor; and a field the program writes after `init`, which a call can forget.

45. **`connect_colibri` serves each method as a stream route of colibri v0.17.0.** Ruled on
    2026-11-15. colibri decision 163 makes a struct route a stream: `on_request` at the head,
    `on_data` at each event of the body, and `next` while the response has room. One request
    context reaches every callback.
    - Each method's route is a struct route, whose state holds the call. A function route reads
      a body whole but holds no state, and a call's state takes tens of KiB.
    - A route that reads its body whole keeps each piece, so colibri holds the body in the
      router's `body_bytes`. At the body's end colibri gives the kept octets once more as the last
      piece, with no new octet, and the route reads the whole body there, in place. A body past
      `body_bytes` gets 413 from colibri, as it did before.
    - A type handler's route of a client or bidirectional stream reads each whole envelope of a
      piece as it arrives, and keeps a cut one for the next piece.
    - The 405 refusals are struct routes with `on_request` alone, which answer at the head.
    - Each route reads its header at the head, so every router names `header_bytes = 0`.
    - A call's nested buffers default to `undefined`, and `on_request` sets their counters.
      colibri v0.17.0 resets a state one field at a time, and a field whose default is
      `undefined` costs no store. On v0.16.3 the router copied the whole state at each request:
      about 375 KB at the default message size.
    - Why: a small routed Connect call took 77,238 instructions on v0.16.3 and 3,935 on
      v0.17.0, on x86-64-v2 (design §8 step 24).

    Beaten: a copy of the body into the call's state, with a new `RouteOptions.body_bytes` to
    size it, which cost the same within 0.7% and added a public option; and a function route for
    each unary method, which holds no state for the call.

## Validation

47. **protovalidate's rules are checked in a module of their own, `protovalidate`, from tables
    the plugin writes.** Ruled by the owner on 2026-11-21. A server that checks each request
    against the rules of its schema is common, so the library holds the check:
    [protovalidate](https://github.com/bufbuild/protovalidate) v1.2.2's
    `(buf.validate.message)`, `(buf.validate.oneof)` and `(buf.validate.field)` options.
    - It lives in this repository. The rules are read from the plugin's request, and the check
      reads a generated message's fields, which no public contract describes. A second
      repository needs a second plugin that copies this one's names, index and features.
    - `protovalidate` imports `protobuf` and the generated code of `validate.proto`, and no
      `connect` module. A program with no RPC validates a message. The owner expects `protobuf`
      to move to stdx one day, and a module that names no `connect` can move with it.
    - No rule is read at run time. The plugin writes a message's rules as a table,
      `pub const protovalidate: validate.Rules`, beside its `protobuf` descriptor. `validate`
      reads the table at comptime, as `encode` reads the descriptor, so a rule that a field
      lacks costs no instruction. A CEL expression becomes a Zig function that the plugin
      writes (design §8 step 34).
    - The table holds the generated types of `validate.proto` itself, such as
      `buf.validate.FieldRules`. The plugin reads each option with that type, and writes it as
      a Zig literal from the type's own descriptor, so the plugin names no rule. A violation's
      rule path takes each rule's number, name and type from the generated descriptor.
    - The package exports that generated code as the module `buf_validate_validate`, the name
      the plugin gives `buf/validate/validate.proto`, and `google_protobuf_descriptor`, which
      it imports. A program's generated code that names `buf.validate.Violations` imports the
      same module, so one `Violation` type exists in a build.
    - A rule fails closed. A rule that the library has no check for, or that does not fit its
      field, stops the build with a message that names it. `rules_error` gives that message as
      a value, for a program that must report it at run time, as the conformance executor
      does.
    - Each number above 1 of a rule is a constant of the message's `RuleNumber`, named for its
      field and its rule, as decision 17 asks of every number in generated code.
    - A message with no rule, in itself or in a message it holds, keeps the code it had. Its
      file imports no `protovalidate`.
    - `validate` writes each violation into a `Report` over storage the caller passes: the
      field's path, the rule's path, the rule's id and a message, as `buf.validate.Violation`
      holds them. A full report ends the walk and says so. A standard rule's message is a
      comptime string.
    - The module holds no set, so it compares the elements of a `unique` list, and the keys of
      a map, pair by pair, up to `compared_items_max` of them. A longer `unique` list fails with
      `TooManyItems`. A map is read as a program reads it with `map_get`: the last entry of a
      key is the map's. A longer map is read entry by entry, which checks more than the map
      holds and never less, and is refused where `min_pairs` would count a key twice.
    - A rule that reads the time takes it from `Options.now` (decision 3). A message whose
      rules need the time fails with `TimeMissing` when the caller passed none.
    - A server checks each request message in an interceptor's `on_message` hook, which runs
      once the message is decoded and before the handler (design §8 step 33, which amends
      decisions 19 and 36). `protovalidate.Interceptor` refuses a message with
      `invalid_argument` and a `buf.validate.Violations` detail. It takes the `connect` module
      as a parameter, as a generated `Routes` takes its transport (decision 2).
      - The hook takes the message's type as a comptime parameter. A message with no rule
        then costs no instruction, and one interceptor serves every method of a route table.
      - An error's message and details must last until the reply is written, after the hook
        returns. The call's values hold them (decision 35), in a field `protovalidate` of the
        type `protovalidate.InterceptorRoom(connect, options)`, as `oidc` keeps its claims.
        The room holds the report's storage too, so no message costs a fill of the stack.
      - The error's message names the first violation's field and what it broke, and the
        count of the others. A detail that does not fit its room holds the first violations
        that do.
      - A rule that reads the time takes it from a field `protovalidate_now` of the program's
        `App`, which the program writes from its clock. With no such field the call fails
        with `internal`: the rule cannot be checked, so the message is not passed on.
      - A function handler of a client or bidirectional stream reads its messages through
        `RequestStream(T).next`, which names no `App`. The stream holds the hook as a function
        pointer with the `App` behind an untyped pointer: one indirect call for each message,
        and only when an interceptor declares `on_message`. Beaten: an `App` type parameter on
        `RequestStream`, which changes every such handler's signature.
    - `pattern` and CEL's `matches` take RE2's syntax. They wait for a regular expression
      module in stdx, which the owner chose on 2026-11-21 (design §8 step 35). Until then a
      rule with a pattern stops the build.
    - protovalidate's conformance harness v1.2.2 runs against `zig build
      protovalidate-executor`. The harness sends each case as an Any beside a
      `FileDescriptorSet`. The library has no dynamic message, so the executor holds the
      suite's generated messages and finds a case's type by its URL, as decision 21 does.

    Beaten: a repository of its own, for the reasons above; a CEL interpreter at run time, as
    every other protovalidate library has, which needs an allocator and messages read through
    reflection (decisions 4 and 6); rule tables written by hand in the library, a second copy
    of `validate.proto`'s shape with each rule's number typed in; the rules as encoded octets
    that `validate` decodes at comptime, which no reader can check against the schema; and a
    check function that the plugin writes for each message, which passes cognitive complexity
    15 at a message of many rules (decision 17).

## Tooling

15. **pepegrillo is lazy.** `build.zig` requests it only when `b.pkg_hash.len == 0`, so a project
    that depends on connect-zig never fetches it, as in colibri (colibri decision 36).

16. **CI downloads Zig 0.16.0 and buf 1.74.0 pinned by SHA-256**, and every check a person runs
    is one `zig build` step or one script of `tools/`, as in colibri's workflow (colibri decision
    47). `bench-compare` runs a second time on GitHub's arm64 runner, with Zig and buf pinned
    for that machine too. The owner asked on 2026-11-14 for an arm64 chart in the README, and
    a chart's numbers come from one CI job (decision 30). The runner is the workflow's to name,
    so this one job joins the workflow file and no other check does.

38. **Google's protobuf conformance suite checks the runtime, in binary and in JSON.** Ruled by
    the owner on 2026-11-13 and 2026-11-14.
    - `tools/protobuf_conformance_check.sh` runs the suite's runner against
      `conformance/protobuf_testee.zig`, for the proto3, proto2 and edition 2023 test messages,
      with the recommended cases enforced. The program answers `skipped` for the text format,
      for JSPB, and for a JSON case that asks to ignore unknown members: connect-zig has none
      of the three.
    - The suite is that of protobuf v37.0's first release candidate, which the owner chose over
      v36.2, the latest stable release.
    - The runner comes prebuilt in the npm package `protobuf-conformance` 37.0.0-rc1, pinned by
      the SHA-512 of its tarball. One maintainer publishes it from `timostamm/protobuf-npm` as
      an unofficial package, and Buf's `protobuf-conformance` repository names it as the
      runner's home since v32.0. The owner kept it on 2026-11-14 with that known. It beat a
      build of the runner from protobuf's source in CI, which adds minutes to the job or a
      cache. The package holds a runner for x86-64 Linux and for macOS, so the check runs on
      the x86-64 runner.
    - The test protos are the package's own, copied to `conformance/proto`, and the check
      compares them with the package's at each run.
    - A case that fails on purpose, or that does not pass yet, is in
      `conformance/protobuf_known_failing.txt` under its reason. The runner fails when a listed
      case passes, so a fix removes its lines.
    - connect-zig reads no proto2 extension: an extension's field is an unknown field, which it
      keeps and writes back.
    - Why: connectrpc's suite tests the RPC protocols, and the coverage check compares with
      Go's runtime on this repository's own cases. Neither holds the encoding's corner cases.
      This suite's first run found a generated name that did not compile, a JSON decoder that
      did not compile for a message of 150 fields, and 113 failing cases.
    - Amended on 2026-11-17, ruled by the owner: JSON encode writes a map key once. A map read
      from binary may hold a key twice, and its last entry wins ("Maps", language guide). A JSON
      object holds each name once (RFC 8259 §4), and Go's protojson refuses a key twice. So
      `json_map.skipped` leaves out each entry whose key a later entry holds. A first pass sets
      a bit of a 1,024-bit filter for each key's fingerprint; only two keys on one bit start a
      second pass, which compares the keys. The check runs on a map of at most
      `json_map_entries_checked_max` entries, 256, and a larger map is written as received, so
      hostile input costs at most 32,640 comparisons a map. The 72 `DuplicateKey.JsonOutput`
      cases now pass. Medium's JSON encode, whose map holds 16 keys, took 1.89% more
      instructions under callgrind on arm64.
    - Beaten: a scratch buffer from the caller, which adds a public name and still needs a rule
      without one; and a comparison of every pair with no bound, which a map of 2 GiB makes
      take hours.

40. **The examples serve OpenTelemetry's trace export, and OpenTelemetry's Go SDK calls it.**
    Ruled by the owner on 2026-11-14.
    - `examples/otlp/proto/opentelemetry` holds the four files of opentelemetry-proto v1.11.1
      that trace export needs, as OpenTelemetry wrote them, under their Apache 2.0 license. The
      denied-words rule skips the folder, as it skips `conformance/proto`.
    - The project `examples/otlp` serves `opentelemetry.proto.collector.trace.v1.TraceService`,
      and `socket_server` serves it beside the other services (decision 41). `Export` keeps the
      encoding of each request, up to a named bound, and answers a request past the bound with
      `partial_success.rejected_spans`.
    - `otlpstore.v1.SpanStore/Received`, a method of this repository, answers with every request
      the service kept, as one `ExportTraceServiceRequest`. Two encodings of one message, one
      after the other, decode as one message whose repeated fields hold both.
    - `interop/otel` exports spans with OpenTelemetry's Go SDK v1.47.0 and its gRPC exporter,
      with gzip, over TLS under the test CA (decision 25). The SDK also records each span in
      memory. The program then calls `Received`, and compares each span field by field.
      `tools/interop_check.sh` runs it against the socket server, beside the calls of curl and buf
      curl to the other example services.
    - Why: the other clients call schemas of this repository. This schema and this client are
      the work of others, and many programs use them, so the check shows connect-zig serve a
      real API as its users would.
    - Beaten: gRPC health and reflection, since reflection needs a design for the plugin first;
      and ELIZA in the package check, which adds no client that others wrote.

43. **Line coverage comes from pepegrillo's tool under kcov, and the badge from a named CI run.**
    Ruled by the owner on 2026-11-14.
    - Zig 0.16 has no line coverage of its own for tests. pepegrillo's `coverage` tool, pinned at
      `580a9d1`, runs each library module's test binary under kcov 43, and prints each module's
      share of lines and a total. The owner chose that the tool live in pepegrillo, so each of
      the owner's Zig projects shares it.
    - `zig build line-coverage` builds each module's tests in Debug with LLVM, since Zig's own
      x86-64 backend writes an incomplete line table. `tools/line_coverage_check.sh` runs it on
      Linux: GitHub's Ubuntu 24.04 has no kcov package, so the check runs it in an ubuntu:26.04
      container, which packages kcov 43. `tools/ci.sh` holds it as the check `line-coverage`.
    - Zig compiles only the functions that code references, so the share is of the lines the
      tests compile, and a function no test references does not lower it.
    - The README's badge is a static shields.io badge. A commit takes its number from a named CI
      run of the check, as the README's charts take theirs. Beaten: Codecov, which needs an
      account and a token in the repository's secrets.
44. **A full-stack benchmark loads whole servers over TLS and h2, beside OpenTelemetry's
    Collector.**
    - The routed call (design §8 step 23) leaves out the socket, TLS and HTTP/2.
      `tools/fullstack_check.sh` measures them. h2load sends OTLP's `TraceService/Export` over
      gRPC, TLS 1.3 and h2 to connect-zig's OTLP sink and to OpenTelemetry's Collector v0.165.0,
      which the script downloads pinned by SHA-256.
    - The Collector runs its OTLP receiver into its `nop` exporter, with no processor. The sink,
      `tools/otlp_sink`, decodes each export, counts its spans and drops it. So each server reads
      and checks every octet, and keeps nothing. Beaten: a full Collector in Zig, which is a
      product of its own and not an example of a library.
    - colibri's `.private` server runs one loop on one thread. So each server runs alone on one
      core, the Collector with GOMAXPROCS=1, and h2load runs on two other cores (colibri decision
      33). The report gives each server's CPU time a call, which holds on any count of cores.
    - Go's runtime encodes the exports, through `tools/fullstack/otlp_request.py` and `buf
      convert`, so connect-zig encodes none of the octets it reads. One export holds 16 spans.
      The other holds 512, the largest batch an OpenTelemetry SDK exports by default.
    - Each round first sends one export through `buf curl`, which must answer with OTLP's full
      success, no span refused and no message: gRPC states a call's status in its trailers,
      which h2load does not read. After
      each round, each server's own count of spans must equal what it was sent, with none
      refused. Either failure fails the check. The times report and never gate, as
      `bench-compare`'s do.
    - TLS runs TLS_AES_128_GCM_SHA256, which every TLS 1.3 implementation has (RFC 8446 §9.1).
      The sink states its thread's timing mode, as colibri's test programs do, so it runs AES-GCM,
      as Go does.
    - h2load is the load generator, as in colibri's judge: a gRPC call is an HTTP/2 POST, so its
      body is fixed ahead of time. Beaten: ghz, which speaks gRPC alone, so it cannot send the
      Connect calls of issue 7. CI installs h2load from Ubuntu's `nghttp2-client` for this check
      alone, as it installs valgrind for `perf`.
    - A second part models production traffic: one gateway core for a fleet of 33,000 servers.
      Each server runs a Collector agent, which exports over OTLP/gRPC with gzip, the default of
      the Collector's otlp exporter, on one TLS connection. A gateway tier of 64 cores shares the
      connections, so one core holds 516 of them. 70% send exports of 16 spans, 25% exports of
      128, and 5% exports of 512. The spans carry the attributes of OpenTelemetry's semantic
      conventions for Kubernetes, HTTP, gRPC, databases and Kafka, and 2% are errors.
    - The production part climbs: oha sends at fixed rates with its latency correction, as
      colibri's judge measures latency, so a call's latency holds its time in a queue. A step
      fails when p99 passes 100 ms, a call is refused, or the server takes less than 95% of the
      step's spans. The report gives the highest step each server holds. Beaten: a peak rate
      alone, which hides the queue, and h2load's `--rps`, which corrects no latency.
    - Amended on 2026-11-17: after the first step that fails, three more steps halve the gap
      between it and the last step that passed. The steps grow by up to half, so the rate a core
      holds is known within 1/16 of it. Before, a ratio of two servers' rates could be off by
      half: Vector held 71,200 spans a second and failed 106,800. A step after a failure waits
      5 s for the server's queue to empty.
    - Amended on 2026-11-17: the `fullstack` and `bench-compare` checks draw the README's charts
      from their own output, and CI keeps them with the run for 90 days, as `charts-<check>-<arch>`.
      A person copies a chosen run's charts to `docs/images`, so the README still names one run.
      Beaten: CI that commits the charts, which needs write access, and moves the README's numbers
      with each runner's CPU model.
    - Vector and Rotel run as they ship, with Nagle's algorithm on. Each passes its accepted
      sockets to tonic itself, and neither sets TCP_NODELAY, so their p99 stays near 40 ms, Linux's
      delayed ACK, from a low rate. colibri and Go set TCP_NODELAY. Beaten on 2026-11-17: a
      preloaded library that sets it on each accepted socket. In an arm64 container it cut their
      p99 at 1.5 exports a connection a second from 42 ms to 5 ms, but did not raise the rate
      either held: Rotel 9.5 and 7.75 exports a connection a second, Vector 3 and 2.875.
    - Slack, whose fleet the model takes its size from, publishes no rate of spans. So the model
      states each core's rate, and the fleet's rate divided by it gives the cores a tier needs.
      The 516 connections, the mix and the 100 ms limit were chosen on 2026-11-17.
    - oha v1.16.0 is pinned by SHA-256, the digest GitHub states for each release asset.
    - CI runs the check on x86-64 and on GitHub's arm64 runner, as it runs `bench-compare`, so the
      README can chart both machines. Each job's numbers belong to its machine alone.
    - Two servers in Rust join, chosen on 2026-11-17. Vector v0.62.0 takes OTLP over TLS with its
      `opentelemetry` source into its blackhole sink, on one thread, and counts one event for each
      span. Its gRPC listener offers no ALPN protocol unless its TLS names `h2`, so the check
      names it (RFC 7301 §3.2). Vector joins the peak part and the climb over TLS.
    - Vector runs its default decoding, which converts each span into an event of its own model.
      Beaten on 2026-11-17: the source's `otlp` codec, which keeps OTLP's form. Its gRPC handler
      decodes each export, encodes it again, and decodes it into a tree. On one core of an
      arm64 container, it answered 4,400 calls a second of 16 spans where the default answered
      9,400, and 120 of 512 spans where the default answered 390.
    - Rotel v0.2.7, the Rust OpenTelemetry collector, has no TLS on its OTLP receiver. So a second
      climb runs in cleartext h2, for connect-zig, the Collector and Rotel. Rotel counts its spans
      in its internal metrics, which it sends by OTLP every 10 seconds; its release build has no
      metrics endpoint. A second Collector takes them and shows them to Prometheus. Beaten: a TLS
      proxy before Rotel, which the climb would measure too, and Rotel's log of each call, which
      costs it CPU that the other servers do not pay.
    - Amended on 2026-11-20, ruled by the owner: CI runs on GitHub's Ubuntu 26.04 images,
      `ubuntu-26.04` and `ubuntu-26.04-arm`, as colibri, stdx and chapulin do. The image moves
      the numbers of `bench-compare` and `fullstack`, so a lab branch ran one commit on both
      arm64 images, each a Neoverse-N2 on kernel 7.0 (run 44664572054). connect-zig did not
      move: its codec's median time was 1.001 times 24.04's, and it held 729,722 spans a second
      over TLS against 729,752. The other servers gained on 26.04: connect-go 10%, the Collector
      9%, Vector 7% and connect-rust 3.5% in the climb over TLS, and connect-rust's routed call
      took 11% less time. So the charts' ratios to them shrink a little. Each chart after this
      names a run on 26.04. Python 3.14 on 26.04 also needed the cp314 wheels of grpcio and
      grpcio-tools in `interop/python/requirements.txt`, and the coverage check now names its
      upb environment after the Python too, since the dependency cache is kept per architecture.

46. **The full-stack benchmark loads receivers on connect-go and connect-rust beside the sink.**
    Ruled by the owner on 2026-11-18, for issue 7.
    - The routed call (design §8 step 23) compares connect-zig with connect-go and connect-rust in
      memory, with no socket, TLS or HTTP/2. The full stack (decision 44) puts sockets, TLS and
      HTTP/2 in, beside OTLP products with pipelines of their own. Neither shows how much of the
      library's lead survives the transport.
    - So two receivers join the full-stack check: `tools/fullstack/connect-go`, on connect-go
      and `net/http`, and `tools/fullstack/connect-rust`, on connect-rust's `connectrpc` server,
      hyper and rustls. Each serves TraceService/Export over TLS with the test identity, counts
      each export's spans and drops it, as `tools/otlp_sink` does. connect-go decodes each export
      into Go's structs; connect-rust into Buffa's view of the request's octets.
    - Each runs alone on one core: connect-go with GOMAXPROCS=1, and connect-rust with
      TOKIO_WORKER_THREADS=1. Both join the peak part and the climb over TLS, under the probes and
      the counts of step 28. connect-go answers `GET /sink/count` as the sink does. connect-rust's
      server has no plain route, so a thread on a second port answers the counts; it waits in
      `accept` while the load runs.
    - The check builds both into the cache: connect-go with the modules its go.sum pins, and
      connect-rust in release with the crates its Cargo.lock pins. connect-rust's server sets
      TCP_NODELAY, so it has no 40 ms floor.
    - Beaten: a second harness that loads the interop servers with `Echo` of
      `coverage.v1.Everything`. It measured the same libraries over the same transport, and adds
      only the Connect protocol and a large reply. It needed a second check, a second chart, and
      a CPU probe in the interop server, which runs ChaCha20 alone. Beaten too: one cipher suite,
      ChaCha20, for every server, which Go and rustls choose only on a CPU with no AES hardware.
