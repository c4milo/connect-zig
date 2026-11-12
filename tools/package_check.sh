#!/bin/sh
# Builds a small project that depends on connect-zig as a fetched package, as the README's "Use
# it in your project" writes it. `zig fetch` keeps only the files that `.paths` of
# `build.zig.zon` names. So a file that the build needs and the list omits fails here, and
# nowhere else: each other check builds the whole tree.
# The project imports the three library modules and installs the plugin. It needs the network,
# for the packages connect-zig depends on.
set -eu
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
# The tracked files, as the working tree holds them.
git ls-files -z | tar --null -T - -czf "${scratch}/connect-zig.tar.gz"
project="${scratch}/project"
mkdir -p "${project}/src"
cat > "${project}/build.zig.zon" <<'ZON'
.{
    .name = .project,
    .version = "0.0.0",
    .fingerprint = 0x2fb3d0eea704f920,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
ZON
cat > "${project}/build.zig" <<'ZIG'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const connect_zig = b.dependency("connect_zig", .{ .target = target });
    const program = b.addExecutable(.{
        .name = "project",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
                .{ .name = "connect", .module = connect_zig.module("connect") },
                .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            },
        }),
    });
    b.installArtifact(program);
    b.installArtifact(connect_zig.artifact("protoc-gen-connect-zig"));
}
ZIG
cat > "${project}/src/main.zig" <<'ZIG'
const std = @import("std");
const protobuf = @import("protobuf");
const connect = @import("connect");
const rpc = @import("connect_colibri");

/// chapulin's one hook, which a program that links colibri's `tls` defines.
export fn ch_assert_fail(condition: [*:0]const u8, file: [*:0]const u8, line: c_int) noreturn {
    std.debug.panic("chapulin assertion failed: {s} ({s}:{d})", .{ condition, file, line });
}

pub fn main() !void {
    // A message through the protobuf module, and a type of each other module, whose size the
    // compiler computes only when it builds the module.
    var buffer: [32]u8 = undefined;
    const stamp: protobuf.wkt.Timestamp = .{ .seconds = 7 };
    const octets = try protobuf.encode(protobuf.wkt.Timestamp, &stamp, &buffer);
    const sizes = [_]usize{ octets.len, @sizeOf(connect.server.Reply), @sizeOf(rpc.Context) };
    for (sizes) |size| std.debug.assert(size != 0);
    std.debug.print("the package builds: {d} modules\n", .{sizes.len});
}
ZIG
cd "${project}"
zig fetch --save=connect_zig "file://${scratch}/connect-zig.tar.gz"
zig build
zig-out/bin/project
test -x zig-out/bin/protoc-gen-connect-zig
echo "connect-zig builds as a fetched package"
