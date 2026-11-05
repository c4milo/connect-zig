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
   a field in every struct before any user needs it. A later step can add `unknown: View`.

6. **Decoding copies nothing.** A string or bytes field is a slice of the input. A repeated field
   is a `Repeated(T, kind)`: either `items`, which a program sets to encode, or a view of the
   enclosing message's bytes plus the field number, which an iterator reads (packed and
   unpacked). A singular message that may contain its own type is a `Lazy(T)`: encoded bytes or a
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
   message's length is written as a 5-byte padded varint and patched once the message ends,
   because a parser accepts a varint longer than it needs. Beaten: a second decoder that writes
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
    long streams at `on_writable`.

## Tooling

13. **pepegrillo is lazy.** `build.zig` requests it only when `b.pkg_hash.len == 0`, so a project
    that depends on connect-zig never fetches it, as in colibri (colibri decision 36).

14. **CI downloads Zig 0.16.0 pinned by SHA-256**, and every check a person runs is one `zig
    build` step, as in colibri's workflow (colibri decision 47).
