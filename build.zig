//! connect-zig's build: the module graph of docs/design.md §3, the tests, the plugin, the
//! examples and the tooling. Helpers live in build/.
//!
//! A project that depends on connect-zig reaches the library modules by name:
//! `dependency.module("protobuf")`, `"connect"` and `"connect_colibri"`.
const std = @import("std");
const assert = std.debug.assert;
const lint = @import("build/lint.zig");
const examples = @import("build/examples.zig");
const generate = @import("build/generate.zig");

pub const Graph = struct {
    protobuf: *std.Build.Module,
    connect: *std.Build.Module,
    connect_colibri: *std.Build.Module,
    public_names: *std.Build.Module,
    colibri: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on in production (CLAUDE.md, Conventions), so the build offers Debug and
    // ReleaseSafe alone, as colibri and stdx do: `-Drelease` selects ReleaseSafe.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    assert(optimize == .Debug or optimize == .ReleaseSafe);
    const release = optimize == .ReleaseSafe;

    const stdx = b.dependency("stdx", .{ .target = target, .release = release });
    const colibri = b.dependency("colibri", .{ .target = target, .release = release });
    const graph = modules(b, stdx, colibri, target, optimize);

    const plugin = b.addExecutable(.{
        .name = "protoc-gen-connect-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protoc_gen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protobuf", .module = graph.protobuf },
                .{ .name = "public_names", .module = graph.public_names },
            },
        }),
    });
    b.installArtifact(plugin);

    // Everything below is connect-zig's own build. A project that depends on it stops here,
    // before the tooling requests pepegrillo (docs/decisions.md entry 15).
    if (b.pkg_hash.len != 0) return;

    const test_step = b.step("test", "Run the lint, then every module's unit tests and the examples");
    add_unit_tests(b, graph, plugin, test_step);
    test_step.dependOn(examples.add(b, graph));
    test_step.dependOn(generate.add(b, graph.protobuf, graph.connect, target, optimize));
    if (lint.add(b)) |lint_step| test_step.dependOn(lint_step);
}

fn modules(b: *std.Build, stdx: *std.Build.Dependency, colibri: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Graph {
    const public_names = b.createModule(.{
        .root_source_file = b.path("src/public_names/public_names.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protobuf = b.addModule("protobuf", .{
        .root_source_file = b.path("src/protobuf/protobuf.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json", .module = stdx.module("json") },
            .{ .name = "codec", .module = stdx.module("codec") },
            .{ .name = "public_names", .module = public_names },
        },
    });
    const connect = b.addModule("connect", .{
        .root_source_file = b.path("src/connect/connect.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "json", .module = stdx.module("json") },
            .{ .name = "codec", .module = stdx.module("codec") },
            .{ .name = "gzip", .module = stdx.module("gzip") },
            .{ .name = "zstd", .module = stdx.module("zstd") },
            .{ .name = "brotli", .module = stdx.module("brotli") },
            .{ .name = "public_names", .module = public_names },
        },
    });
    const connect_colibri = b.addModule("connect_colibri", .{
        .root_source_file = b.path("src/connect_colibri/connect_colibri.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect },
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "server", .module = colibri.module("server") },
            .{ .name = "client", .module = colibri.module("client") },
            .{ .name = "http", .module = colibri.module("http") },
            .{ .name = "public_names", .module = public_names },
        },
    });
    return .{
        .protobuf = protobuf,
        .connect = connect,
        .connect_colibri = connect_colibri,
        .public_names = public_names,
        .colibri = colibri,
        .target = target,
        .optimize = optimize,
    };
}

fn add_unit_tests(b: *std.Build, graph: Graph, plugin: *std.Build.Step.Compile, test_step: *std.Build.Step) void {
    const targets = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "protobuf", .module = graph.protobuf },
        .{ .name = "connect", .module = graph.connect },
        .{ .name = "connect-colibri", .module = graph.connect_colibri },
        .{ .name = "public-names", .module = graph.public_names },
        .{ .name = "plugin", .module = plugin.root_module },
    };
    for (targets) |each| {
        const unit = b.addTest(.{ .name = each.name, .root_module = each.module });
        const run = b.addRunArtifact(unit);
        const step = b.step(b.fmt("test-{s}", .{each.name}), b.fmt("Run the {s} tests alone", .{each.name}));
        step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
}
