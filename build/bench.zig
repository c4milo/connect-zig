//! `zig build bench`: the protobuf runtime's benchmark in bench/, built ReleaseFast.
//! Arguments after `--` reach the program: `zig build bench -- --quick` runs it as a smoke test.
//!
//! The library's own build offers Debug and ReleaseSafe alone. The benchmark builds its own copy
//! of the protobuf module, and the generated code of bench/gen, in ReleaseFast. stdx's modules
//! come from its dependency, which offers ReleaseSafe at most: the benchmark asks for that, so
//! the JSON scanner keeps its assertions.
const std = @import("std");

const optimize: std.builtin.OptimizeMode = .ReleaseFast;

pub fn add(b: *std.Build, public_names: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const stdx = b.dependency("stdx", .{ .target = target, .release = true });
    const protobuf = b.createModule(.{
        .root_source_file = b.path("src/protobuf/protobuf.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json", .module = stdx.module("json") },
            .{ .name = "codec", .module = stdx.module("codec") },
            .{ .name = "public_names", .module = public_names },
        },
    });
    const messages = b.createModule(.{
        .root_source_file = b.path("bench/gen/bench/v1/bench.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf }},
    });
    const exe = b.addExecutable(.{ .name = "bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "bench_v1", .module = messages },
        },
    }) });
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    run.has_side_effects = true;
    b.step("bench", "Benchmark the protobuf runtime, ReleaseFast: zig build bench -- [--quick] [--write <dir>]").dependOn(&run.step);
}
