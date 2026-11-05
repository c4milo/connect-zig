# connect-zig

[Connect RPC](https://connectrpc.com/) for Zig 0.16. It holds:

- `protobuf`: the protobuf binary encoding and the proto3 JSON mapping, over generated structs,
  with no allocator. Decoding copies nothing.
- `connect`: the Connect, gRPC and gRPC-Web protocols as functions over header values and body
  bytes. It does no I/O and reads no clock.
- `connect_colibri`: Connect servers and clients over
  [colibri](https://github.com/c4milo/colibri)'s h11, h2 and h3.
- `protoc-gen-connect-zig`: the protoc plugin that `buf generate` runs.

The status of each part is in [docs/design.md](docs/design.md) §8.

## Use it

Add the package to `build.zig.zon`, then import the modules by name:

```zig
const connect_zig = b.dependency("connect_zig", .{ .target = target });
module.addImport("protobuf", connect_zig.module("protobuf"));
module.addImport("connect", connect_zig.module("connect"));
module.addImport("connect_colibri", connect_zig.module("connect_colibri"));
```

## License

Apache-2.0. See [LICENSE](LICENSE).
