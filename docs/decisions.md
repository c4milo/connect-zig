# connect-zig decisions

Each entry is numbered and states what it beat. A change that reverses an entry amends the entry
first. Cite an entry by number in code and commits ("decision 6").

## Scope and shape

1. **The full stack, in one repository.** connect-zig holds a protobuf runtime (binary and proto3
   JSON), a Connect client and server, and the protoc plugin `protoc-gen-connect-zig`, which
   `buf generate` runs. It speaks three protocols, as connect-go does: Connect, gRPC, and
   gRPC-Web. Beaten: a runtime alone, which leaves every user to write the RPC layer; and Connect
   alone, which cannot talk to gRPC servers.

2. **Three library modules and one executable.** `protobuf` knows no RPC. `connect` is the
   protocol core and knows no HTTP library: it reads header values and body bytes the caller
   passes, and writes header values and body bytes into storage the caller owns. `connect_colibri`
   is the one module that imports colibri. Beaten: one module over colibri, which ties the
   protocol rules to one transport and makes them harder to test.

3. **No I/O, and no clock.** The library makes no system call and reads no clock. A deadline is
   an instant in nanoseconds that the caller passes, as colibri passes time (colibri
   non-negotiable 3). The `io`, `determinism`, and `heap` lint rules hold `src/` to it. Beaten:
   reading the clock for `Connect-Timeout-Ms`, which makes a test depend on the machine.

4. **No allocator in `src/`.** Every buffer is the caller's. Sizes are named constants or caller
   choices. The one exception is the plugin executable in `src/protoc_gen/`: it is a program, not
   the library, and it uses the arena `std.process.Init` gives it. Beaten: an allocator parameter
   on decode, which colibri and stdx both refuse (colibri non-negotiable 4, stdx non-negotiable 2).

39. **The package exports the colibri modules a program builds on.** Ruled by the owner on
    2026-11-14. Amended by decision 52: the modules are fields of `connect_zig`.
    - `build.zig` exports colibri's `server`, `client`, `http`, `tls`, and `colibri` modules under
      colibri's own names. A program takes them as it takes `connect_colibri`:
      `dependency.module("server")`.
    - A program thus builds its router, its server, and its client on the one colibri that
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

52. **A program imports one module, `connect_zig`, and a build option leaves colibri out of
    it.** Ruled by the owner on 2026-11-24.
    - The package exports one module, `connect_zig`. Its fields name `protobuf`, `connect`,
      `protovalidate`, stdx's `platform`, the generated code of validate.proto and
      descriptor.proto, and, with colibri, `connect_colibri`, `oidc`, and colibri's `server`,
      `client`, `http`, `tls`, and `colibri` (amended below). Each is the module the library builds on, so a
      program and its generated code hold one copy of each, and a program names no stdx.
    - The build option `colibri`, true by default, chooses whether the module names colibri. A
      program that codes or checks messages, or runs the protocol on an HTTP library of its
      own, passes `.colibri = false`. Its module then reaches no colibri module, and the
      program links no chapulin and no libc. A colibri name it uses stops the build with a
      message that names the option.
    - Generated code imports `connect_zig`, and reads `protobuf`, `connect`, `protovalidate`,
      and the library's generated code from it. The two files of the library's own generated
      code import `protobuf` and each other by module, since the library builds them below
      `connect_zig`.
    - The build's own checks and benchmarks give generated code the module without colibri,
      so a check that serves no RPC links no chapulin.
    - This amends decision 39: colibri's modules are fields of `connect_zig`, and no longer
      exports of their own.
    - `examples/std_http` serves ELIZA on `std.http.Server` and calls it with
      `std.http.Client`, with `.colibri = false`. It is the first program that runs the
      protocol over a socket on an HTTP library other than colibri. `std.http` speaks HTTP/1.1
      and sends no trailers, so it speaks Connect and gRPC-Web, and not gRPC.

    Beaten:
    - One module that always names colibri. A program that imports it links chapulin and libc
      and defines `ch_assert_fail`, even one that only codes messages, because Zig links the
      objects of every module a compilation reaches.
    - `connect_zig` beside an exported `protobuf`, with generated code that imports one or the
      other. A file with rules then had to import `connect_zig` for `protovalidate`, so a
      program that validates and serves nothing linked chapulin, and a program of messages
      whose schema declares a service did too.
    - `connect_zig` beside a second module with no colibri. A program then maps the name of
      generated code to one of two modules. A build option is what a Cargo feature is to
      tonic, whose transport is a default feature, and connect-zig already takes `rotor` so.
    - What it costs: two projects in one build must pass connect-zig the same `colibri` and
      `rotor`, or Zig builds two packages and the compile fails with a file in two modules.
    - Amended on 2026-11-25, on the owner's word: colibri at a88c515 exports one module,
      `colibri`, which names each of its others (colibri decision 170). `connect_colibri` and
      `connect_zig` import it, and read `server`, `client`, `http`, and `tls` from it. Decision
      32 keeps its point: the library names none of colibri's kinds on Rotor, `colibri.Server`
      and `colibri.Client`, and the `layering` rule still refuses a chain that starts with
      `colibri` outside `src/connect_zig`. The owner had CLAUDE.md's third non-negotiable say so
      the same day.
    - Amended again on 2026-11-25, on the owner's choice: no program uses the API yet, so each
      name says one thing once. `connect_zig` names `CpuFeatures`, stdx's type, in place of the
      whole `platform` module: a program needs the type alone, and connect-zig exports no other
      part of stdx, as colibri exports nothing of chapulin (colibri decision 162). It names
      `colibri` and no longer `server`, `client`, `http`, or `tls` beside it, so a program writes
      `connect_zig.colibri.server`. Beaten: the whole `stdx` module, which makes stdx's API part
      of connect-zig's; and the four names beside `colibri`, two names for each module.

41. **Each example is a Zig project of its own.** Ruled by the owner on 2026-11-14.
    - `examples/<name>/` holds `build.zig`, `build.zig.zon`, `buf.gen.yaml`, `proto/`, `gen/`, and
      `src/`. Its manifest names connect-zig by path, `../..`. A reader copies the folder, and
      swaps the path for a URL.
    - `examples/harness` is a package, not an example: colibri's in-memory links, the server and
      client rounds over h11, h2, and h3, the test identity, and chapulin's hook. Each project that
      runs in memory depends on it by path. `socket_server` depends by path on the projects
      whose services it serves.
    - `examples/quickstart` is the README's "Use it in your project", as a project.
      `tools/package_check.sh` builds it against a fetched copy of connect-zig, so no program
      source lives in a script.
    - The root's `zig build examples` runs `zig build test` in each project, with the root's
      package folder and cache. So the tree fetches each package once and compiles each module
      once. `zig build example-<name>` and `zig build run-eliza-server` stay.
    - The coverage converter, the interop client, and the test of the generated code are checks,
      not examples. They move to `tools/`, with the schemas that only they read.
    - Why: a reader copies one folder and has a program that builds. Each project writes the
      build that a dependent writes, so the examples prove decision 39 too.
    - Beaten: one build for every example, which hides the build a project writes; and a copy
      of the harness in each project, which repeats about 900 lines in six places.
    - Amended the same day, on the owner's choice: each example owns the schema it is about, and
      no project holds every proto. `demo.proto` splits into one schema for each of streaming,
      interceptors, and errors. A project that builds on another example's service, such as
      `socket_server`, `std_io`, and `sans_io_call`, depends on that project by path and imports
      its exported modules. The interop service, which only the checks call, moves to
      `tools/interop_server` with a server of its own. `large.proto` stays beside
      `kitchen.proto`, whose `shared.proto` it imports. Beaten: one project of every proto,
      which makes each example depend on schemas it does not use.
    - Amended again the same day, on the owner's choice: each example is also a program to play
      with. `zig build serve -- [port]` serves its service on a real socket, over TLS under the
      test identity, on h11, h2, and h3, through the harness's `Served`. Each project keeps its
      `App` and route table in `src/app.zig`, which the check and the server share.
    - A project that depends on another passes connect-zig the same options, or Zig builds a
      second `connect` module. `eliza` and the harness take a `rotor` option for a project with
      no Rotor, such as `std_io` (decision 32).

42. **Every tree of hand-written Zig takes the library's rules.** Ruled by the owner on
    2026-11-14.
    - `examples/`, `bench/`, `conformance/`, and the programs of `tools/` take every lint rule
      that `src/` takes, except the four that state what a library is: no allocator, no I/O, no
      clock, and no Rotor. A program owns its memory, its sockets, its clock, and its loop. `tools/`
      joined when the checks moved there from `examples/` (decision 41).
    - Each tree names its limits in a `constants.zig`, as `src/` does (the `magic-numbers`
      rule).
    - A program holds no container-level `var` (the `global-state` rule). Its `main` allocates
      one `State` from `init.arena` before the first call, with `rawAlloc` (decision 48), and
      hands a pointer to each function.
      TigerStyle allocates once, at startup, in the same way. The allocator gives the type's
      alignment, which Zig 0.16's x86_64 backend does not always give a static.
    - Why: a reader copies an example into a program, so the rules that hold the library to its
      bar hold the copy to it too. The package check's program lived in a shell script that no
      rule read, and a misaligned static reached CI that way.
    - Beaten: one aligned static `State` that the rule allows by name, since pepegrillo's rule
      has no such option; and `threadlocal` statics, which break `std_io_server`'s queue, which
      its tasks share across threads.

48. **A program takes its `State` from `rawAlloc`, so a page holds memory only once it is
    written.** The owner asked on 2026-11-23 for the sink to hold less memory: in CI's run 266 it
    peaked at 321 MiB, where connect-rust grew to 54 MiB.
    - In Debug and ReleaseSafe, `Allocator.create` writes the undefined pattern over the whole
      value it returns. A program's `State` holds every buffer it will use (decision 42), so that
      write puts each page of it in memory at the start. The sink's `State` is 331 MB: 137 MB of
      server, 123 MB of router with its calls' storage, 44 MB of TLS buffers, and 28 MB of zstd and
      brotli decoders. It was 318 MiB in memory before its first connection.
    - So each program calls `rawAlloc` on its arena and casts the result to `*State`. The pages
      stay unmapped until the program first writes them. The sink starts in 6 MiB, and under the
      peak part's 64 calls of 512 spans it grew to 75 MiB on an x86-64 machine. What it holds now
      is what its connections and calls write.
    - The lint rule `state-fill` (`tools/lint/state_fill.zig`) refuses `.create(State)` in every
      tree of hand-written Zig, so a new program cannot bring the fill back.
    - What it costs: a read of a field that `main` never wrote gives zeros, not the pattern, so
      Debug no longer shows such a read as `0xaa`. Every program writes each field it reads
      before it reads it, and the tests that serve and call each example pass.
    - Beaten: building the programs ReleaseFast, which drops the fill and every safety check
      with it, where `-Drelease` builds ReleaseSafe; a smaller `State`, which would only cut the
      cost of a fill that need not happen; and a helper in the library, which would name an
      allocator in `src/` (decision 4).

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

50. **A program decodes and encodes with a `Decoder` and an `Encoder`, which take its CPU
    features once.** Ruled by the owner on 2026-11-24
    (https://github.com/c4milo/connect-zig/issues/14): a library takes the CPU features its
    program detects, and a program sets them as it starts and uses them from then on.
    - `protobuf.Decoder.init(cpu_features)` makes the value that holds `decode`, `decode_into`,
      `decode_into_use`, `merge`, `decode_json` and `decode_json_with`. Each checks a string for
      UTF-8 with those features. `protobuf.Encoder` holds `encode_json` and `encode_json_with`.
      Binary `encode` and `encoded_len` use no feature and stay free functions.
    - A decode checks each string of its input once. A repeated field's iterator and `Lazy.get`
      read bytes a decode checked, and check no string again, as they check no nested message
      again (decision 9 as amended). A view or a `Lazy` a program sets itself is the
      program's to keep well formed, as the strings of `items` are, which `encode` does not
      check either.
    - The features go down a decode in its context, the value each mode carries to each level:
      a checked decode carries a pointer to them, a stored one its `Store`, which holds the
      pointer, and a shallow one nothing. `wire.Reader` stays as it was.
    - `connect` makes a `Decoder` or an `Encoder` from the features of the call's server
      options or of its `Client`, which the program set once (decisions 10 and 51). A test, a
      benchmark and a check program use the build target's features. The lint's rule
      `target-features` refuses each other call of `target()` in `src/protobuf`.
    - Counted by `tools/perf_check.sh` on 2026-11-24, built for x86-64-v3, against `main`
      counted the same day. Binary decode took 1.1% to 3.8% more instructions: a string of 32
      octets or more now hands stdx's check runtime features, which the compiler folded when
      they were the build target's. JSON decode took 1.5% to 17.3% fewer, since a transcoded
      string is no longer checked twice. Built for the baseline CPU, x86-64-v3's features in
      place of the build target's cut large JSON decode by 15.5% and large binary decode by
      3.6%, measured that day with a patch that was not kept.

    Beaten: free functions on the build target's features, which the owner's ruling refuses; a
    `cpu_features` argument of each call, which the owner refused, since the features are set
    once; `protobuf.Codec`, a name `connect.Codec` holds; the iterator and `Lazy.get` checking
    each string again, with no features or with the decoder passed to each read; a flag in
    each `View` of the bytes a decode checked, which `Lazy` has no room for; and the features
    in `wire.Reader`, which counted within 0.5% of the context but gives every reader a field
    only a decode's strings read.

## Connect

10. **Compression comes from stdx.** gzip and zstd encode and decode; brotli decodes only, since
    stdx has no brotli encoder yet. connect-zig accepts `gzip`, `zstd`, and `br`. A program places
    the encoders it compresses with in `connect.Encoders`, and a server answers in the first
    coding the peer lists that it holds an encoder for. The zstd encoder runs at level 1 with a
    128 KiB window, which an RPC message rarely outgrows. connect-zig pins the stdx colibri
    pins, since two stdx in one binary repeat its exported symbols. Beaten: a C codec, which
    stdx exists to replace.
    Amended on 2026-11-10: base64 comes from stdx too, for proto3 JSON's bytes, Connect's error
    details, gRPC's "-bin" values, and a unary GET's message. stdx's decoder reads either alphabet
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
    Amended on 2026-11-24, ruled by the owner (https://github.com/c4milo/connect-zig/issues/18):
    each codec takes the CPU features the program passes, in `Encoders.cpu_features` and
    `Decoders.cpu_features`. Their type is stdx's `platform.CpuFeatures`, which stdx's decision
    40 as amended that day moved from `codec`. connect-zig names no type of its own for it. A
    program detects the features once with `platform.CpuFeatures.detect()`, as it does for
    `protovalidate` (decision 47). The default is `.target()`, the build target's, so a program
    that sets neither field codes as before. Under callgrind, the OTLP sink built for the
    baseline x86-64 CPU took 315.9 million instructions for 40 gzip exports of 512 spans with the
    target's features, and 269.4 million with the detected ones. gzip's CRC-32 fell from 36.2 to
    5.3 million, from a table to PCLMULQDQ, and inflate from 40.9 to 27.3 million, on its x86-64
    fast path. Valgrind runs a CPU of its own, with no AVX-512, so a real CPU may take other paths.
    connect-zig pins the stdx that colibri pins, now
    once: `protovalidate` takes `regex` from it too. Beaten: the build target's features inside
    `compress` and `decompress`, which no program can raise; a default of `.detect()`, which is
    a probe in the library; and a field of the App, which a program with no connect_colibri
    does not have.
    Amended on 2026-11-24 (https://github.com/c4milo/connect-zig/issues/14): Connect's error
    body, its end-stream message, gRPC's "-bin" trailers and a GET's query read and write their
    JSON and base64 with the same features. The server and the client take them from `Encoders`
    and `Decoders`, which each call already holds. A call a program makes itself takes them as
    its last argument, or in its `Storage`, with no default. stdx's JSON and base64 write the
    same octets on every path, so no test sees the features a call took. The lint's rule
    `target-features` refuses each call of `target()` in `src/connect` but the two defaults
    above and the tests' one constant. Beaten: a field of `Scratch`, which an encode call does
    not take; and a default of `.target()` in each `Storage`, which ruling 2 of issue 14
    refuses.
    Amended on 2026-11-24 again, as the owner asked that day: no server takes the build
    target's features by default, and a program states its features once.
    - `Encoders` and `Decoders` hold codecs alone again. The features were in both, so a
      program stated them twice, and an App with no `codings` had no place to state them: its
      routes took the build target's. A refused request's reply took them too.
    - A server's `Options` holds `cpu_features`, with no default. `accept` copies it into its
      decision: `Accepted`, where the call's `Messages` and `Reply` read it, and `Refused`,
      where `refusal_reply` reads it. So a server names its features in one place, and no call
      passes them on by hand. `compress`, `decompress`, and the client's `Response.init` take
      them as an argument.
    - A route of `connect_colibri` reads the field `cpu_features` of the program's App, as
      `protovalidate.Interceptor` does (decision 47), and as issue 14 planned. An App without
      the field stops the build, with a message that names the field. A program sets it once:
      `state.app = .{ .cpu_features = .detect() }`. `rpc.Codings` holds codecs alone.
    - The rule `target-features` holds `src/connect_colibri` too.
    - A client's `Options.cpu_features` keeps the build target's features as its default, the
      one such default left, and the rule passes that one line of that one file. A client's
      options are written for each call, 55 times in the examples, some in constant tables. A
      required field would state a CPU in each call. The client needs a value it sets once, as
      the server has its App, and that value is a new public type, which the owner rules first.
      Decision 51 is that value, `connect.Client`: it took the default and the rule's one
      passing line away the same day, and `Response.init` with them.

    Beaten: the fields in `Encoders` and `Decoders` with no default, which states the features
    twice and makes `codings` a field every App needs; a field `cpu_features` of `rpc.Codings`,
    a second place beside the one `protovalidate` reads; and a required field in a client's
    `Options`, as above.

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
    - The program passes the pool's `headers`, `body`, and `body_taken` events to the call. Each
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
    an interceptor read the call through `Call`: its protocol, codec, timeout, and request
    headers, and the response headers and trailers they add. Beaten: a runtime list of function
    pointers, which costs an indirect call and loses the `app` type; and, amended 2026-11-07, a
    `ClientCallWith(method, interceptors)` beside `ClientCall(method)`, which named two types for
    one and left no room for a client option but interceptors. Amended 2026-11-11: a server
    hook takes the call's `Context`, `AnyRequest`, and `AnyResponse`, and `Call` goes (decision
    36). Amended 2026-11-21: an interceptor may also define `on_message`, which runs in list
    order with each request message once it is decoded, and may refuse the call (decision 47).

20. **Examples share their services.** The programs in `examples/` import the ELIZA and demo
    services, the in-memory link, and its client loop from `examples/services/`, so each program
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
    server presents it over TLS for h11, h2, and h3, and its client and curl trust the CA. The
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
    runner's client mode against its reference server, over h11, h2, and h3, in cleartext and
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
    grpcio, and tonic, each pinned by its lock file, which echo every coverage case in each
    protocol, codec, and compression their library speaks, and run every stream shape, a typed
    error, a timeout, headers, and trailers. Two messages are the same when a runtime writes the
    same octets for both. Beaten: buf curl alone, which is one client; and the conformance
    runner alone, whose reference client is connect-go.
    Amended on 2026-11-09, with the client half the owner approved: the client side runs too,
    on `rpc.ClientCall` over `client.ConnectionPool` (decision 32), not on `colibri.Client`.
    `interop/` also holds servers on connect-go and grpc-go, connect-node, grpcio, and
    connect-rust, each pinned by its client's lock file. `examples/interop_client.zig` runs every
    scenario against each, in each protocol, codec, and HTTP version the server speaks, and
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
    keeps the test identity of decision 25, so curl, buf curl, and the clients of `interop/` trust
    its CA. The conformance server holds no identity and stays in cleartext, as the runner asks.
    A connection past the socket limit waits in the kernel's backlog until a socket frees, as
    colibri rules. Beaten: a server with no identity, which drops h3; and keeping our loop, a copy
    of colibri's.

32. **The library runs on any event loop.** Ruled by the owner on 2026-11-08. `connect_colibri`
    builds on colibri's protocol modules alone: `server`, `client`, and `http`, which take octets
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
    response and answers `rpc.Next`: `.message`, `.wait`, `.end`, or `.failure`. A server stream's
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
    - The signature check and base64url are chapulin's `jws` calls: RS256, ES256, and EdDSA
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
      the issuer, the audience, "exp", and "nbf". No claim is read before the signature passed.
      A token with no "exp" is refused, as OpenID Connect Core 1.0 §2 and RFC 9068 §2.2
      require one.
    - A name the module reads appears once in its object, in a header, a claims set, and a JWK.
      The RFCs let a parser refuse a second one, and the refusal leaves no two readings of one
      text.
    - The claims belong to the call (amended 2026-11-11, decision 35). `verify` writes them
      into a `Claims` the caller owns, which holds a copy of the subject and of the payload. The
      interceptor verifies into its call's values, the field `oidc`, a
      `?oidc.Claims`, which stays null on an excluded path and after a refusal. A handler reads
      `ctx.values(Values).oidc` at any callback of its call, the tenth message of a stream
      included.
    - A program reads its own claims on demand, with `Claims.string`, `integer`, and `holds`
      over the payload's copy. A string a lookup returns stays valid until the next lookup on
      the same `Claims`. A claim nobody asks for costs nothing.
    - The JSON readers take the program's CPU features (amended 2026-11-24,
      https://github.com/c4milo/connect-zig/issues/14). `VerifierOptions.cpu_features` has no
      default, and `init` copies it. `verify` writes it into the `Claims` it fills, so that a
      lookup of the program's runs with it too. A `Claims` that no `verify` filled holds
      `.none()`, and its lookups read no payload. The lint's rule `target-features` refuses each
      call of `target()` in `src/oidc` but the tests' one constant. Beaten: a parameter of each
      lookup, which a handler would have to pass at each call; and the verifier's features read
      through a pointer in `Claims`, which a call's values would hold past the verifier's
      `deinit`.
    - `Interceptor(.{ .exclude = ... })` takes its list at compile time, because a generated
      `Routes` gives one interceptor list to each method of a service. An entry is a method's
      path, or a service's prefix that ends in "/". Its `on_call` takes any call type with
      `path`, `request_header`, and `add_header`, so the module serves another transport too.
    - A refused call gets `unauthenticated`, which Connect writes as HTTP 401, and RFC 6750
      §3's `WWW-Authenticate: Bearer` challenge, with `error="invalid_token"` when the call
      carried a token.

    Limits. One issuer and one audience for each verifier, and 8 keys. An RSA key holds 2048
    to 4096 bits. A token holds 4096 characters at most, which is what a route copies of a
    request's headers. A string a lookup returns holds `claim_bytes_max` octets at most. A
    `Claims` takes about 4.4 KB of each call's values. A NumericDate with an exponent
    is refused.
    The module reads no "typ",
    "nonce", "azp", or "at_hash": those belong to the client that ran the login, not to the
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
    and the names `Local`, `Locals`, and `RequestContext`, before the call's own object took the
    name `Context`. The owner chose `Values`, connect-es's word for the same values.

    Amended on 2026-11-15, at colibri v0.17.0 (decision 45). The values live in colibri's request
    context. The route table names their type as `.Values`, colibri starts each request with its
    defaults, and `ctx.values(T)` reads them through colibri, which halts a read with another
    type. `RouteOptions.Values` goes. A table names one type for all its routes, so a table that
    joins services declares one struct with the fields of each.

36. **A handler takes the call's context, its request, and its response.** Ruled by the owner on
    2026-11-11 ("ctx, request and response split is cleaner"), as connect-go splits a call
    into a `context.Context`, a `Request`, and a `Response`. `Call` goes; it held all three.
    - `Context` is the call: its path, protocol, codec, and timeout, the counts of the messages
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

    Beaten: one object for the call, its request, and its response, as connect-es's
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
    - Cost, found on 2026-11-23: a decoded list takes more room than its octets, about 3.6
      times for an OTLP export. A run that finds no room is decoded by the route's check and
      thrown away, and decoded again by each reader. In the OTLP sink, a 512-span export past
      the default 256 KiB cost protovalidate 0.96 µs a span where 1 MiB cost 0.16 µs. The sink
      sets `storage_bytes` for its decoded exports, and `RouteOptions` and
      docs/protovalidate.md tell a program to size it so.
    - Amended on 2026-11-23, ruled by the owner: a route's storage defaults to 4 times
      `message_bytes`, `connect_colibri.constants.storage_per_message`, and a decode counts each
      message whose lists did not fit in the context's field `messages_past_storage`, when the
      context has one (design §8 step 38). Beaten: a fixed 1 MiB, which a route of small messages
      pays for each call it holds, and which a decoded message can still outgrow; and a silent
      default, which a program learns of only from a profile.
    - An iterator gives a message in place (design §8 step 16). `next` returns `?Item`: for a
      message, a pointer that holds until the next call, into `items` or into the iterator's
      own slot for a message of a view; for a number, a string, or an enum, the value. The
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
      read beat connect-zig's on medium, large, tree, and packed.

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

51. **A program's calls share one `connect.Client`, which holds its CPU features and its
    codecs.** Ruled by the owner on 2026-11-24
    (https://github.com/c4milo/connect-zig/issues/14): a program sets its CPU features as it
    starts and uses them from then on, and no library names the build target's in their place.
    - `connect.Client` holds `cpu_features`, with no default, and `encoders` and `decoders`,
      which hold no codec by default. A program makes one as it starts:
      `const client: connect.Client = .{ .cpu_features = .detect() };`.
    - The client makes each call. `request` builds a request, `write_message` writes one
      message of a streamed request, and `response` starts the read of a response. Each is a
      declaration alias of a function in `client_call.zig` or `client_response.zig`, so each
      file stays under 500 lines.
    - `connect.client.Options` holds what differs from call to call: the protocol, the codec,
      the timeout, the choice of a GET, the request's coding and its floor, and the headers.
      Each field has a default. A table of options stays constant data, and `&.{}` is a call
      with the defaults.
    - `connect_colibri.ClientCall.init` and `init_stream` take the client as their first
      argument. The call keeps a copy of it, as an `init` of colibri copies what it keeps of
      a pointer it takes (colibri decision 158 ruling 2). So a program's client may change or
      end before its calls do.
    - `connect.client.request`, `connect.client.write_message`, and
      `connect.client.Response.init` are gone, and `Options` holds no `encoders`, `decoders`,
      or `cpu_features`.
    - No type of the library holds a default of the build target's features. The rule
      `target-features` passes the test-support files alone.

    Beaten: a required `cpu_features` in each call's `Options`, which states a CPU in each of
    the examples' 55 calls, and makes a constant table of options read a value of the run;
    the default of the build target's features, which the owner's ruling refuses, and which a
    program built for a generic CPU keeps without a warning; the features of the call's
    `Context`, as a route reads its App's, which a call with no interceptor does not have
    (the decision 44 of this section), and which a program on `connect` alone has no place
    for; and a pointer to the client in each call, which saves a copy of a few words and
    makes each call depend on how long the client lives.
    The owner asked on 2026-11-24 why colibri's client does not hold these, and agreed that
    day to keep `connect.Client`. Beaten then:
    - The features in colibri's `client.Config`, which `ClientCall.init` would read from the
      pool. colibri's configuration holds none: each of its decoder pools takes them at its
      `init`. A program on `connect` alone has no pool. The codecs would stay in connect-zig,
      since colibri's client removes HTTP content codings and knows no envelope, so a program
      would state its client in two places. A route reads the program's own `App`, never
      colibri's server configuration, and a call follows it.

    Amended on 2026-11-24: colibri at 19a4b51 holds the features in `server.Config` and in
    `client.Config`, with no default (colibri decision 169,
    https://github.com/c4milo/colibri/issues/156). So a program states them to colibri too, for
    the HTTP content codings colibri codes: a server in `.engine`, with the value of its `App`,
    and a client in its pool's configuration, with the value of its `connect.Client`. No name
    of connect-zig changes, and `connect.Client` stays. A call still reads no configuration of
    a pool: `ClientCall`'s pool is any type with `request`, and a program on `connect` alone
    has none. Beaten: the App's and the `Client`'s field read from colibri's configuration,
    which makes a route and a call depend on which server or pool carries them.
    - The name `connect.client.Config`. A program makes each request through the value, as
      it does through `std.http.Client`, which a struct literal makes from an allocator and an
      `Io`, and whose `RequestOptions` hold what one request chooses. Pepegrillo's API guide
      puts std's idioms before a project's own choice.
    - What it costs: a program names colibri's `client` module, `colibri.Client`, and
      `connect.Client`, so the README and the guide say which is which. A program hands its
      features to TLS, to each decoder pool of colibri, to its `App`, and to its `Client`.
      One field of colibri's `client.Config` that its own pools read would cut that, and that
      change is colibri's.

## Validation

47. **protovalidate's rules are checked in a module of their own, `protovalidate`, from tables
    the plugin writes.** Ruled by the owner on 2026-11-21. A server that checks each request
    against the rules of its schema is common, so the library holds the check:
    [protovalidate](https://github.com/bufbuild/protovalidate) v1.2.2's
    `(buf.validate.message)`, `(buf.validate.oneof)`, and `(buf.validate.field)` options.
    - It lives in this repository. The rules are read from the plugin's request, and the check
      reads a generated message's fields, which no public contract describes. A second
      repository needs a second plugin that copies this one's names, index, and features.
    - `protovalidate` imports `protobuf` and the generated code of `validate.proto`, and no
      `connect` module. A program with no RPC validates a message. The owner expects `protobuf`
      to move to stdx one day, and a module that names no `connect` can move with it.
    - No rule is read at run time. The plugin writes a message's rules as a table,
      `pub const protovalidate: validate.Rules`, beside its `protobuf` descriptor. `validate`
      reads the table at comptime, as `encode` reads the descriptor, so a rule that a field
      lacks costs no instruction.
    - A CEL expression compiles at comptime too, in the module. Amended by the owner on
      2026-11-21: the plugin was to write each expression as a Zig function. The table already
      holds each rule's expression as text. The module parses the text at comptime, gives each
      part a type from the message's descriptor, and unfolds it into plain code, as it does for
      a standard rule (design §8 step 34).
      - A generated file stays data, which the lint of decision 17 reads as it is. A function
        that the plugin wrote would need a name for each number of its expression, and a split
        at cognitive complexity 15.
      - A table written by hand takes CEL rules as a generated one does.
      - An expression that does not parse, that names a field its message lacks, or that calls
        a function with the wrong types stops the build through `rules_error`, as a rule that
        does not fit its field does. `dyn` moves such an error to run time, as CEL states it.
      - An expression that fails at run time, such as a division by zero, ends `validate` with
        `Unevaluable`. The message is not valid and not refused: the rule gave no verdict.
      - The module compiles the CEL it has a use for, and grows by use. A function or a macro
        it does not hold stops the build with a message that names it. `map` and `filter` build
        a list, which needs room the module does not have, so they stop the build too. The
        amendment of 2026-11-22 below gives them a list that is computed as it is read.
      - A list and a map are views of a repeated field, read one element at a time and never
        copied. One expression reads at most `cel_steps_max` elements, the pairs of
        `compared_items_max`, so a macro inside a macro has a bound whatever a message holds.
        Past it `validate` ends with `TooManyItems`.
      - `&&`, `||`, `all`, and `exists` absorb a side or an element that fails when another one
        decides the result, as CEL states them.
      - The grammar is written once, over a builder (`cel_grammar.zig`). The compiler runs it
        with a builder that makes the tree in its own memory, and a test runs the same code
        at run time with a builder that writes into storage it passes. So Zig's fuzzer and
        the vectors of a Lean model check the code that reads a schema's rules. Beaten: a
        second reader for the tests, which a test would check in place of the first.
      - The reader follows the CEL language definition's lexis: a string of three quotes, a
        bytes literal's `b` before its `r`, `0x` in lower case, no line end in a string of
        single quotes, the reserved words, a keyword as no field's name, a comma after a
        list literal's last element, and a number's sign as part of its literal. It reads no
        message literal and no name that starts with ".". It reads a map literal since the
        amendment of 2026-11-22 below.
      - Where the definition gives a text two readings, the reader takes cel-go's, which
        protovalidate's libraries run. One "-" before a number is the number's sign, which a
        member starts with: "-2.5.isInf()" asks -2.5. A run of two or more is a run of
        negations of a number with no sign. Beaten: the last "-" of a run as the sign, which
        read "--9223372036854775808" where cel-go refuses it.
      - An expression has the verdict protovalidate-go gives it. `tools/cel_differential_check.sh`
        writes random rules and random messages, and compares this module's verdicts with
        protovalidate-go's: valid, invalid with the violation's message, a failure as the
        expression runs, and a rule that does not compile. Its first runs found six
        differences, and each follows cel-go now:
        - `==`, `!=`, and `in` take two values of one type: `1 == 1u` stops the build. An
          order takes two numbers of any types, as protovalidate's CEL does.
        - Behind `dyn`, `==`, `!=`, and `in` take any two values and compare them as they
          run: two values of unlike types are not equal, and two numbers compare by value.
        - A conversion of a literal that fails, such as `int('x')` and `bool('k')`, stops
          the build: cel-go computes such a conversion once, before the expression runs.
        - `uint` takes no double below zero, and `int` no double at or below the least int.
        - A duration literal holds an int64 of nanoseconds at most.
        - A macro reads a list literal, and the compiler reads a signed `duration('-3s')`.
          Both stopped the build with a compiler error before.
        Beaten: the conformance suite alone, whose cases hold few expressions and found none
        of the six. One difference stays: behind `dyn` this module compiles some expressions
        that cel-go's checker refuses, since it marks a part as dynamic where cel-go gives
        the part a type.
      - The tree holds the CEL language definition as cel-spec published it, in
        `docs/specs/cel/langdef.md`, and each CEL rule in the code cites its section.
        `docs/specs/README.md` lists where the definition is silent or gives two readings and
        the module follows cel-go. Beaten: a link to the definition, which changes under the
        code that cites it.
      - A Lean model in `spec/lean/` states the lexis and the grammar a second time, from the
        language definition and production by production, where the Zig reads every level of
        operators in one loop. Its vectors are replayed against the Zig grammar. The model
        proves no theorem yet (spec/README.md).
      - A schema of thousands of rules compiles in time that grows with them: about 7.5 ms
        for a rule. The compiler runs comptime code as an interpreter, so the module counts
        its steps (docs/performance.md, "The compiler's time"). An enum names each operator,
        each keyword, and each function once, and an enum that the compiler builds once for a
        message finds a field by its name. The typing of an expression is a constant's
        value, so the compiler computes it once. Tests hold the reading and the typing to a
        count of branches, and `tools/compile_time_check.sh` holds the whole build to a
        baseline. Not built: a plugin that writes each expression's tree beside its text,
        which would end the 4 ms the compiler takes to read the text. It changes what the
        table holds, so it waits for the owner's word.
      - The compiler reads each token once, keeps one tree for each expression's text, and
        finds a field's entry by a search of a descriptor whose numbers rise. The plugin
        raises the compiler's branch quota in a table whose literal makes more than 500
        calls, since Zig counts each call of a declaration's value against a quota of 1000.
      - The plugin still reads the predefined rules of an extension, since only its request
        holds an extension's descriptor. It writes each one's value into the table.
        - A rule message's generated type does not know an extension, so the extension's
          records lie among the message's unknown fields (decision 24). The plugin finds each
          record's extension in its request, by the rule message's name and the record's
          number, and reads the values through a `Repeated` view of that span.
        - The protobuf module gives no list of the numbers in a span. The plugin walks the
          span's tags itself, in `rules_predefined.zig`, and reads no value there. Beaten: a
          public name for the module's wire reader, for one caller, which waits for the
          owner's word.
        - A value is a scalar, a wrapper of wrappers.proto, which CEL reads as its scalar, or
          a list of them. Any other value, such as a Duration, marks the table unsupported,
          and the build stops with a message that names the extension.
        - An extension with no `(buf.validate.predefined).cel` states no rule, and the plugin
          passes over it. A field that neither the plugin's validate.proto nor an extension
          of the request states marks the table unsupported, so a rule of a later
          validate.proto never goes unchecked.
    - The table holds the generated types of `validate.proto` itself, such as
      `buf.validate.FieldRules`. The plugin reads each option with that type, and writes it as
      a Zig literal from the type's own descriptor, so the plugin names no rule. A violation's
      rule path takes each rule's number, name, and type from the generated descriptor.
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
      field's path, the rule's path, the rule's id, and a message, as `buf.validate.Violation`
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
    - `pattern` and CEL's `matches` take RE2's syntax, on stdx's `regex` module, which the
      owner chose on 2026-11-21. Amended the same day for design §8 step 35:
      - The compiler reads each pattern into a program once. A pattern that stdx refuses is a
        problem of the rules, which `rules_error` reports.
      - The pattern of CEL's `matches` is a string literal, for the same reason. cel-go reads a
        pattern each time the expression runs, so it takes a pattern from a field too. No rule
        of protovalidate's suite does that.
      - `bytes.pattern` of octets that are not UTF-8 fails as it runs, as `string(this)` fails
        in validate.proto's expression.
      - Each search runs stdx's `Searcher` in memory on the stack, with a DFA cache of
        `pattern_cache_words`. The library keeps no memory between calls, so each search
        builds its DFA's states again. Amended on 2026-11-22, ruled by the owner: each thread
        keeps one searcher for each pattern, made ready at its first check, in `threadlocal`
        memory of a size the build knows. Its DFA states depend on the pattern alone, so a
        check gives the answer a fresh searcher would, and no two threads write one. A
        pattern's memory is about 8 to 14 KiB a thread, and the email pattern's 73 KiB. It is
        zero storage the binary does not hold. The medium message's checks took 64% fewer
        instructions. Beaten: a fresh searcher for each check, 1 to 3 µs each, and a cache the
        caller passes to `validate`, which every program would size for each pattern.
      - A search takes the CPU features the program passes. Amended on 2026-11-22, ruled by the
        owner:
        - `Options.cpu_features` holds stdx's `codec.Features`, of the stdx that `regex` comes
          from. The module names no type of its own for it: the program depends on stdx at the
          commit that `build.zig.zon` pins as `stdx_regex`, with connect-zig's options, so its
          `codec` is the module that `protovalidate` imports, as colibri's decision 162 has a
          program name chapulin. The field has no default, as stdx's
          `SearcherOptions.features` and colibri's `tls.Cpu` have none. A program calls
          `codec.Features.detect()` once as it starts.
        - `Interceptor` reads the features from the App's field `cpu_features`, one field that
          each module of the program reads. An App with no such field stops the build.
        - A kept searcher is made ready again when a check passes other features, so each check
          searches with its caller's. Each check compares 12 octets to know. One pattern's text
          has one searcher on a thread, wherever a rule or an expression names it.
        - Beaten: the build target's features inside the library, as the module's codecs of
          stdx 0.1.2 take them, which never reach AVX2 in a program built for the baseline CPU;
          a probe in the library, which colibri and stdx leave to the program; a default; a
          name of the module's own for stdx's type, which the owner refused, since the program
          detects with stdx and holds stdx's type; a field of the App for each module; and the
          features of a thread's first check kept for each later check, which would search with
          features its caller did not pass.
      - stdx's `regex` came in a release that colibri does not pin yet. So `build.zig.zon`
        pins that commit a second time, as `stdx_regex`, and takes `regex` alone from it. A
        second copy of stdx's `json` would export the same kernel symbols twice, and `regex`
        exports none. The two pins become one when colibri moves to a stdx that holds
        `regex`.
      - Amended on 2026-11-24: the two pins are one. colibri at e5dd6ba pins stdx at 1df5f9f,
        which holds `regex`, and `stdx_regex` goes. `Options.cpu_features` holds stdx's
        `platform.CpuFeatures`, which stdx's decision 40 as amended that day moved from
        `codec`, and the codecs take the same value (decision 10 as amended).
      - Beaten: one pin moved to the new stdx, whose `json` and colibri's would collide at
        the link; waiting for a colibri release; and a matcher alone, which costs less on a
        text of under about 18 octets and about 375 instructions an octet past it.
    - CEL's `format` follows the CEL strings extension (`docs/specs/cel/strings.md`). Amended
      on 2026-11-22:
      - The text is a string literal and the list a list literal, so the compiler reads the
        text once and types each value alone. The values may differ in type.
      - It reads `%s`, `%d`, `%x`, and `%X`, which protovalidate's schemas use. `%f`, `%e`, `%o`,
        `%b`, and a precision stop the build.
      - The run writes the text into the free part of the report's storage, and the violation
        keeps it at the storage's end. A text with no room ends `validate` as a full report
        does. So the library holds no buffer of its own.
      - Beaten: a buffer on the stack for each rule, which bounds a message by a constant and
        costs a fill on each call; and a public scratch passed to `validate`, which every
        program would size.
    - CEL's `filter(x, p)`, `map(x, t)`, and `map(x, p, t)` give a lazy list. Amended on
      2026-11-22:
      - The list holds its source and the values of the expression's names. Each read of an
        element takes the source's next element, or a map's next key, and runs the predicate and
        the transform on it. So the list needs no room, and its length has no bound but the
        expression's count of steps.
      - `size`, `in`, an index, and the macros read it as any other list. Each read runs the
        expressions again, so a rule that reads one list twice computes it twice.
      - A key that two entries of a map hold is read once. A failure of the predicate or the
        transform fails the read, as it fails the macro in CEL.
      - `map(x, t)` of a list literal or of a predefined rule's list keeps the array it gave
        before, whose length the compiler knows.
      - Beaten: a list in the free part of the report's storage, which copies each element and
        bounds the list by the room; and a buffer on the stack, which bounds it by a constant.
    - CEL's `+` of two strings or two bytes values, and `string` of a number or a bool, write
      their text where `format` writes its own. Amended on 2026-11-22:
      - A part whose value holds no text gives back what it wrote once its value is known. A
        reader of a list that writes its elements, such as `map(x, string(x))`, gives back each
        element's text once it is done with the element. So the room bounds the text that one
        part of an expression holds at a time, and not the text of a whole run.
      - `+` of two lists joins them as they are read, as `filter` and `map` give a list.
      - Beaten: a rope of the two sides, which every function of strings would read as one;
        and the room given back only when the rule ends, which a macro over a long list fills.
    - CEL's timestamps and durations follow cel-go: `timestamp(string)` reads RFC 3339 as Go
      does, arithmetic fails where cel-go's checked arithmetic fails, and the `get` functions
      take a zone. Amended on 2026-11-22:
      - A zone is `UTC` or a fixed offset. A zone's name needs the IANA time zone database,
        which the library does not hold. A literal name stops the build, and a name read from
        a field fails the expression.
      - `string` of a timestamp writes UTC, as a `google.protobuf.Timestamp` holds no zone.
      - Beaten: the database compiled into the library, some 400 KB that each program would
        carry and that would age with each release of the database; and the database read from
        the system, which is I/O.
    - cel-spec's conformance suite runs against the code that a rule's expression compiles into.
      Amended on 2026-11-22:
      - `tools/cel_conformance_check.sh` reads the suite of cel-spec v0.25.3, the release of
        `docs/specs/cel`, and runs each test that declares no variables and builds no message:
        1,819 of 2,504. A rule's names are its own, so the check declares none.
      - 1,045 pass. 742 differ for a reason that `tools/cel_conformance/known.txt` gives: an
        extension that protovalidate's CEL environment does not turn on, a function of the
        strings extension other than `format`, and parts of the language the module does not
        build: a map literal, a message literal, an empty list literal, a list of two types,
        and `==` of two lists. 29 turn the type check off, which a rule always has.
      - The same day the owner asked for the largest of those parts: map literals, `[]`, and
        `==` of two lists. The module builds them, `==` of two maps too, and 1,142 pass.
      - The owner then asked for a list or a map literal of two element types, such as
        `[1, 'a']`, which cel-go types `list(dyn)`. The compiler knows each element's type, so
        such a literal is a Zig tuple (`cel_mixed.zig`). Its size, `in`, `==`, `type`, `%s` of
        `format`, an index the build knows, and `all`, `exists`, and `exists_one` unfold for
        each element, and a macro reads its variable as behind `dyn`. An index the build does
        not know, and `filter` and `map` of such a literal, give no one type, and stop the
        build. 1,174 pass. Beaten: a union of CEL's types for each element, whose every read
        is a switch at run time, where the build knows each element's type.
      - Its first run found four differences, and each follows cel-go now: a double compares
        with an integer as the integer made a double; a side of `&&` or `||` behind `dyn` that
        holds no bool fails and is absorbed; a list takes a uint and a whole double as its
        index behind `dyn`; and `%s` of `format` writes a timestamp, a duration, and a type. A
        function that no library declares stops the build behind `dyn` too, and `%%` writes
        one `%`.
      - Beaten: the suite's tests with variables, which a runner would declare one by one, and
        a differential check alone, whose generator writes only what it was taught.
    - protovalidate's conformance harness v1.2.2 runs against `zig build
      protovalidate-executor`. The harness sends each case as an Any beside a
      `FileDescriptorSet`. The library has no dynamic message, so the executor holds the
      suite's generated messages and finds a case's type by its URL, as decision 21 does.

    Beaten: a repository of its own, for the reasons above; a CEL interpreter at run time, as
    every other protovalidate library has, which needs an allocator and messages read through
    reflection (decisions 4 and 6); a Zig function that the plugin writes for each CEL
    expression, which puts a CEL compiler in the plugin and code in each generated file; rule tables written by hand in the library, a second copy
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
      `conformance/protobuf_testee.zig`, for the proto3, proto2, and edition 2023 test messages,
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
    - The routed call (design §8 step 23) leaves out the socket, TLS, and HTTP/2.
      `tools/fullstack_check.sh` measures them. h2load sends OTLP's `TraceService/Export` over
      gRPC, TLS 1.3, and h2 to connect-zig's OTLP sink and to OpenTelemetry's Collector v0.165.0,
      which the script downloads pinned by SHA-256.
    - The Collector runs its OTLP receiver into its `nop` exporter, with no processor. The sink,
      `tools/otlp_sink`, decodes each export, counts its spans, and drops it. So each server reads
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
      conventions for Kubernetes, HTTP, gRPC, databases, and Kafka, and 2% are errors.
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
    - Amended on 2026-11-23, ruled by the owner: five halvings, not three, so a rate is known
      within 1/64 of it, between 0.6% and 1.6% of the rate held. Three left a gap of 2.5% to
      6.2%, wider than a cost of a few percent, such as validation's or a coding's. The report
      gives each server's gap as its resolution, and the chart draws it as a whisker. A cost is
      compared as CPU a span at the highest rate both servers held: a span costs less CPU as
      the rate rises, 2.25 µs on connect-zig at 35,600 spans a second and 1.36 µs at 712,000 in
      run 243.
    - Amended again on 2026-11-23: a call refused in a step's first 2 s fails no step, as a
      latency there counts in no p99. Each step opens its 516 connections again, and the calls
      queued behind their TLS handshakes arrive at once. A server that queues them shows it as
      latency there; connect-zig's sink, which refuses a call past its 64, showed it as refusals,
      and run 248's climbs ended there: 229,202 spans a second over TLS with uncompressed exports,
      where gzip's held 747,584, and every refusal fell 0.11 to 0.26 s into its step. The report
      gives the held step's refusals in its first seconds in a column of their own.
    - Amended a third time on 2026-11-23, after a review of the method: the climb's load is
      `tools/fullstack/load`, a program of this repository on h2, tokio, and rustls, in place of
      oha. It opens its 516 connections once and keeps them across the climb, as the agents keep
      theirs. So a step holds no TLS handshake, every call counts, and the 2 s that each step
      left out goes, with its column. It sends each class's 32 variants of its export in turn,
      so a decoder does not read the same octets on every call. It offers AES-128-GCM alone, as
      h2load does at the peak, and the report names the suite its connections ran. It offers it
      in TLS 1.3 and in TLS 1.2: Vector's gRPC listener speaks TLS 1.2 alone, and answered run
      265's offer of TLS 1.3 alone with a protocol_version alert, so Vector ran no climb there. It
      keeps oha's open schedule: each connection sends at ticks of its own, each class spreads
      its ticks over the interval, and a call's latency runs from its tick. Before each step it
      opens again a connection the server closed, and the report counts them. Beaten: oha, which
      opens its connections again at each step, sends one body, and pins no suite. In a 4-CPU
      container, its two cores were 18% busy where connect-zig held 712,000 spans a second.
    - Amended a fourth time on 2026-11-23, after the same review: each server climbs in three
      rounds, each on a new process. One climb's rate moved by up to 38% between CI runs on
      x86-64, so a single climb could not tell a cost of a few percent from the runner. The first
      round climbs from the lowest rate. Each later round runs a step of 5 s at half the rate held
      before, then brackets it at 0.8 and 1.2 times and halves the gap four times, so it costs
      about half a climb. Round r runs the servers in their order rotated by r - 1, so a drift of
      the runner does not always fall on the same server. The reports give the median round, the
      range, and each ratio of two servers round by round, since one round runs both near in
      time. Two rates whose intervals over the rounds overlap read as rates the rounds cannot
      tell apart. The compression part runs three rounds of each coding, and each receiver's first
      climb alone steps up from the lowest rate. To hold the 90 minutes of a CI job, the peak and
      the climbs in cleartext run in checks of their own, `fullstack-peak` and
      `fullstack-cleartext`, on x86-64 alone, and draw no chart. Beaten:
      three whole climbs, which do not fit a job, and three runs of the job, whose runners differ.
    - Amended a fifth time on 2026-11-23: after its rounds, each server runs one step of 60 s at
      the median rate it held, on a new process, after a step at half of it, and the report says
      whether it held. A rate that a step of 10 s held by chance then shows. The report also gives
      the most spans a second a step of the first round held with p99 at most 10 ms, a latency an
      interactive caller would accept, beside the rate at the climb's 100 ms. The compression part
      runs no long step: its rates compare codings, and its 90 minutes hold no more.
    - Amended on 2026-11-17: the `fullstack` and `bench-compare` checks draw the README's charts
      from their own output, and CI keeps them with the run for 90 days, as `charts-<check>-<arch>`.
      A person copies a chosen run's charts to `docs/images`, so the README still names one run.
      Beaten: CI that commits the charts, which needs write access, and moves the README's numbers
      with each runner's CPU model.
    - Amended on 2026-11-25, on the owner's choice: the benchmarks, `bench-compare`,
      `validate-compare`, and the `fullstack` checks, run on each tag alone, and no longer on
      each push. The job `charts` then commits each chart the tag's run drew to `docs/images` on
      main, with the workflow's token. The README and `docs/benchmarks.md` quote no measured
      number and point at the charts, each of which names its run, so the text no longer moves
      with a runner's CPU model. A push loses these checks as gates: a wrong answer or a changed
      octet shows at the next tag. Beaten: the charts of every push, which a person copied, and
      CI that commits charts while the text still quotes their numbers.
    - Vector and Rotel run as they ship, with Nagle's algorithm on. Each passes its accepted
      sockets to tonic itself, and neither sets TCP_NODELAY, so their p99 stays near 40 ms, Linux's
      delayed ACK, from a low rate. colibri and Go set TCP_NODELAY. Beaten on 2026-11-17: a
      preloaded library that sets it on each accepted socket. In an arm64 container it cut their
      p99 at 1.5 exports a connection a second from 42 ms to 5 ms, but did not raise the rate
      either held: Rotel 9.5 and 7.75 exports a connection a second, Vector 3 and 2.875.
    - Slack, whose fleet the model takes its size from, publishes no rate of spans. So the model
      states each core's rate, and the fleet's rate divided by it gives the cores a tier needs.
      The 516 connections, the mix, and the 100 ms limit were chosen on 2026-11-17.
    - oha v1.16.0 is pinned by SHA-256, the digest GitHub states for each release asset. Removed
      on 2026-11-23 with oha, as amended above: Cargo.lock pins the load's crates.
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
      climb runs in cleartext h2, for connect-zig, the Collector, and Rotel. Rotel counts its spans
      in its internal metrics, which it sends by OTLP every 10 seconds; its release build has no
      metrics endpoint. A second Collector takes them and shows them to Prometheus. Beaten: a TLS
      proxy before Rotel, which the climb would measure too, and Rotel's log of each call, which
      costs it CPU that the other servers do not pay.
    - Amended on 2026-11-20, ruled by the owner: CI runs on GitHub's Ubuntu 26.04 images,
      `ubuntu-26.04` and `ubuntu-26.04-arm`, as colibri, stdx, and chapulin do. The image moves
      the numbers of `bench-compare` and `fullstack`, so a lab branch ran one commit on both
      arm64 images, each a Neoverse-N2 on kernel 7.0 (run 44664572054). connect-zig did not
      move: its codec's median time was 1.001 times 24.04's, and it held 729,722 spans a second
      over TLS against 729,752. The other servers gained on 26.04: connect-go 10%, the Collector
      9%, Vector 7%, and connect-rust 3.5% in the climb over TLS, and connect-rust's routed call
      took 11% less time. So the charts' ratios to them shrink a little. Each chart after this
      names a run on 26.04. Python 3.14 on 26.04 also needed the cp314 wheels of grpcio and
      grpcio-tools in `interop/python/requirements.txt`, and the coverage check now names its
      upb environment after the Python too, since the dependency cache is kept per architecture.

46. **The full-stack benchmark loads receivers on connect-go and connect-rust beside the sink.**
    Ruled by the owner on 2026-11-18, for issue 7.
    - The routed call (design §8 step 23) compares connect-zig with connect-go and connect-rust in
      memory, with no socket, TLS, or HTTP/2. The full stack (decision 44) puts sockets, TLS, and
      HTTP/2 in, beside OTLP products with pipelines of their own. Neither shows how much of the
      library's lead survives the transport.
    - So two receivers join the full-stack check: `tools/fullstack/connect-go`, on connect-go
      and `net/http`, and `tools/fullstack/connect-rust`, on connect-rust's `connectrpc` server,
      hyper, and rustls. Each serves TraceService/Export over TLS with the test identity, counts
      each export's spans, and drops it, as `tools/otlp_sink` does. connect-go decodes each export
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
    - Amended on 2026-11-23, ruled by the owner: two more receivers validate each export against
      OpenTelemetry's span rules, written as protovalidate rules in `tools/fullstack/validate`
      (its README lists them). `otlp-sink-validate` is the sink with `protovalidate.Interceptor`
      (decision 47). connect-rust with `validate` checks each request with protovalidate-buffa
      0.8.0, on the view it decodes. Both join the peak part and the climb over TLS, and must
      refuse an export whose trace ID is 3 octets with `invalid_argument`. The chart
      `fullstack-validate.svg` sets each beside the receiver that does not validate. Beaten:
      protovalidate in connect-zig alone, which gives its cost and no scale to read it on.
    - Amended again on 2026-11-23, ruled by the owner: connect-go joins with protovalidate-go
      v1.4.1, the third pair of the chart. The three Connect receivers also run both loads with
      exports in no coding and in gzip, zstd, and brotli, over TLS and in cleartext h2, in two
      checks of their own, `fullstack-compression` and `fullstack-compression-cleartext`: the two
      transports in one job pass the 60 minutes a CI job had. stdx's encoders write every export,
      as a connect-zig client places them. connect-go reads zstd with klauspost/compress and
      brotli with andybalholm/brotli, and connect-rust brotli with the `brotli` crate, since
      neither library holds those codings. Beaten: the Collector and Vector in the compression
      checks, which would hold each job past 90 minutes.
    - The compression checks send the production model's exports at peak too: the peak's own
      export repeats its values, compresses 14.7 times where the production model's compresses
      7.5, and so gives a decoder less work than real spans do. Each round of the peak rotates the
      order of the codings and the receivers, and each receiver climbs its codings in an order of
      its own, so a runner that slows over a job does not always slow the same coding. Each
      coding is drawn as a share of the same receiver uncompressed, net of the TLS and HTTP/2 a
      smaller export saves. Beaten: one axis for the three libraries, on which connect-go's
      costs hid the differences between connect-zig's codings.
    - Amended on 2026-11-23, after a review of the method, on three baselines. The peak part runs
      connect-go a second time with GOGC=off and GOMEMLIMIT=320MiB, about the memory connect-zig's
      sink sets aside when it starts, so Go's collector runs only as its heap nears that. Without
      it, connect-go held a tenth of the sink's memory, and its collector paid for the difference.
      Decision 48 then cut the sink's peak in that part to 75 MiB, and the limit followed it to
      75MiB.
      The routed call's Go and Rust programs leave the building of a request out of the timed
      calls, as the Zig side replays a head it built once: Go copies a request httptest built
      once into a writer it clears, and Rust clones a head the builder made once. In a 4-CPU
      container Go's small call fell from 7 to 11 µs to 2 to 4 µs, and Rust's by about 10%.
      `tools/bench_check.sh` runs Zig, Go, and Rust in three rounds, each in an order rotated by
      one, and gives each cell the median round. Beaten: one run of each language after the other,
      on which a runner that drifts slows the last.

49. **The Python, Go, Rust, and JavaScript of `bench/` and `tools/` keep cognitive complexity 15
    and files of 500 lines.** Asked for by the owner on 2026-11-23.
    - `zig build lint` holds each Zig function to 15, in `bench/` and `tools/` too. The programs
      and scripts that run the benchmarks and the checks are in four more languages, and no check
      read them. Eleven functions were over 15: a chart's reader scored 35, and the Go validation
      benchmark's `run` scored 27.
    - `tools/complexity_check.sh` scores each function of `bench/` and `tools/` by SonarSource's
      method, as the Zig scorer does: complexipy for Python, gocognit for Go, rust-code-analysis
      for Rust, and eslint's sonarjs plugin for JavaScript. Each tool is pinned in
      `tools/complexity`. It skips each `gen/`.
    - complexipy scores functions alone, so a script that does its work at its top level escapes
      it. `tools/complexity/top_level.py` refuses control flow there, and each script runs its work
      from `main()`.
    - No tool scores a shell script, so ShellCheck alone reads them (`tools/scripts_check.sh`).
    - Each file of the four languages keeps 500 lines too. `zig build lint` runs pepegrillo's
      file-length rule over them a second time, as `file-length-scripts`, beside its first run
      over the Zig and the shell scripts. It skips each `gen/`, and the `target/`, `node_modules/`,
      `__pycache__/`, and virtual environment that a build or an install fills.
    - Beaten: clippy's `cognitive_complexity` lint, which scored 7 for a Rust function that the
      other tools score 17 and 18 in their languages, and which needs each crate built with its
      descriptor sets and protoc. Ruff's rule C901, which counts paths and not nesting. The clients
      and servers of `interop/` stay outside the check: they test interoperability, not speed.
