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

10. **Compression comes from stdx.** gzip encodes and decodes. At the stdx commit pinned,
    `5fd03aa`, zstd and brotli decode only. connect-zig accepts `gzip`, `zstd` and `br`, and
    compresses with `gzip` alone until stdx ships a zstd encoder. Beaten: a C codec, which stdx
    exists to replace.

11. **Plain gRPC waits on colibri for the client.** colibri's `client.Response` holds no
    trailers, so a client cannot read `grpc-status` over h2. The server speaks gRPC now. The
    client speaks Connect for every stream type, through the end-stream message, and gRPC-Web,
    whose trailers are a body frame. Beaten: reading trailers below colibri's API, which colibri's
    rules forbid to a dependent.

12. **Streams are whole bodies in v0.** colibri's router hands a route the whole request body,
    and a route writes its response into the response memory the router pool holds. A server
    stream is therefore bounded by `response_bytes`, and a bidirectional stream is half-duplex.
    Beaten: waiting for flow control in colibri before shipping any stream. A later step writes
    long streams at `on_writable`. Decision 18 lifts the half-duplex part for type handlers.

13. **Examples run in cleartext.** The ELIZA programs speak h2 with prior knowledge and h11, and
    hold no TLS identity, so they need no certificate to run. colibri's `tls` module still links
    chapulin, so each program defines `ch_assert_fail`. Beaten: colibri's test identity, which
    colibri does not package. Decision 25 adds a round over h3, under a test identity
    of the examples' own; the cleartext rounds stay.

14. **A handler returns its error as a value.** A handler fills its response and returns null, or
    returns the `connect.RpcError` the client reads. A Zig error from a handler is a fault, which
    the route table's `error_handler` answers. Beaten: a Zig error set per handler, which cannot
    carry a message or details.

17. **Generated code passes every lint rule the tree runs, with no exemption.** Three choices
    follow from it:
    - Each message numbers its fields in a `FieldNumber` enum, and its descriptor names each
      number through it, as the magic-numbers rule asks. An enum's table names numbers through
      its tags. Hand-written messages use the same shape, through `proto.field_of`.
    - A generated file imports another by module name, never by a path with `../`, as the
      relative-import rule asks. Its header names the modules the build gives it: the module of
      `kitchen/v1/shared.proto` is `kitchen_v1_shared`.
    - A file over 500 lines is split, as the file-length rule asks: `<file>.pb.zig` re-exports
      each declaration from `<file>/<Name>.pb.zig`, and a nested one has its own piece. A single
      message of more than about 160 fields still makes one piece too long.
    Beaten: exempting `.pb.zig` from the rules, as colibri exempts its generated tables from
    magic-numbers, which would leave a project's own lint failing on the code it generates.

18. **A type handler streams full-duplex.** A client or bidirectional stream's handler may be a
    type with `on_message` and `on_end`. Its route sets no `.whole_body`, so colibri hands it the
    body as it arrives, and it passes each whole envelope on and keeps a partial one for the
    next read. Each message a `Sender` writes is flushed to the endpoint at once. Over h2 a
    client reads answers while it still sends; `tools/interop_check.sh` checks it with buf curl.
    A function handler still takes its stream whole. Beaten: a handler that blocks on a
    `Receiver`, which needs a thread or a coroutine the library does not have.

19. **Interceptors are types, chosen at compile time.** A route lists its interceptors in its
    options. Each may define `on_call`, which runs in list order and may refuse the call, and
    `on_finish`, which runs in reverse and returns the outcome the client reads. A client's
    `ExchangeWith` lists `on_request` and `on_response` interceptors the same way. A handler and
    an interceptor read the call through `Call`: its protocol, codec, timeout and request
    headers, and the response headers and trailers they add. Beaten: a runtime list of function
    pointers, which costs an indirect call and loses the `app` type.

20. **Examples share their services.** The programs in `examples/` import the ELIZA and demo
    services, the in-memory link and its client loop from `examples/services/`, so each program
    holds only its calls and its checks. The socket server serves both services. Beaten: one
    copy of the link loop per program.

21. **An Any's JSON names its type from a comptime list.** Writing or reading an Any in JSON
    needs the type its URL names. The well-known types are always in the list. A program adds
    its own with `pub const protobuf_any_types = .{ ... };` in its root file, or passes them to
    `encode_json_with` and `decode_json_with`, which a test needs since a test's root is the
    test runner. A type outside the list fails with `UnknownAnyType`. Beaten: a runtime registry,
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
    as explicit, since the runtime checks no required field. A closed enum keeps an unknown
    number as a value of its non-exhaustive enum, and `utf8_validation = NONE` is still checked:
    both are stricter than the spec asks, never looser. Beaten: refusing edition files, which
    buf generates by default for new modules.

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
    13), and gRPC success still waits on colibri's trailers over h3 (decision 11). Beaten:
    colibri's test identity, which colibri does not package; and minting an identity at each
    run, which needs openssl in every build.

## Tooling

15. **pepegrillo is lazy.** `build.zig` requests it only when `b.pkg_hash.len == 0`, so a project
    that depends on connect-zig never fetches it, as in colibri (colibri decision 36).

16. **CI downloads Zig 0.16.0 and buf 1.74.0 pinned by SHA-256**, and every check a person runs
    is one `zig build` step or one script of `tools/`, as in colibri's workflow (colibri decision
    47).
