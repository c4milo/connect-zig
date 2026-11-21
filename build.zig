//! connect-zig's build: the module graph of docs/design.md §3, the tests, the plugin, the
//! examples and the tooling. Helpers live in build/.
//!
//! A project that depends on connect-zig reaches the library modules by name:
//! `dependency.module("protobuf")`, `"connect"`, `"connect_colibri"`, `"protovalidate"` and, on
//! a host target, `"oidc"`. It reaches colibri's `"server"`, `"client"`, `"http"`, `"tls"` and
//! `"colibri"` the same way, and `.rotor = true` builds colibri's `.private` kinds on Rotor
//! (decision 39). `"buf_validate_validate"` and `"google_protobuf_descriptor"` are the generated
//! code of validate.proto and descriptor.proto, under the names the plugin gives them (decision
//! 47).
const std = @import("std");
const assert = std.debug.assert;
const lint = @import("build/lint.zig");
const examples = @import("build/examples.zig");
const checks = @import("build/checks.zig");
const bench = @import("build/bench.zig");
const conformance = @import("build/conformance.zig");
const chapulin = @import("build/chapulin.zig");
const line_coverage = @import("build/line_coverage.zig");
const lean = @import("build/lean.zig");
const fullstack = @import("build/fullstack.zig");
const protovalidate = @import("build/protovalidate.zig");
const schema_programs = @import("build/schema_programs.zig");

const Graph = @import("build/graph.zig").Graph;

/// Decision 39: the colibri modules the package exports under colibri's own names, so a program
/// builds its router, its server and its client on the colibri that `connect_colibri` uses.
const colibri_exports = [_][]const u8{ "server", "client", "http", "tls", "colibri" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on in production (CLAUDE.md, Conventions), so the build offers Debug and
    // ReleaseSafe alone, as colibri and stdx do: `-Drelease` selects ReleaseSafe.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    assert(optimize == .Debug or optimize == .ReleaseSafe);
    const release = optimize == .ReleaseSafe;

    const stdx = b.dependency("stdx", .{ .target = target, .release = release });
    // colibri's `.private` kind of `colibri.Server`, which the example and conformance servers
    // use, runs on Rotor (colibri decision 159). connect-zig's own build asks for it, and a
    // program asks with `.rotor = true` (decision 39). The library never needs Rotor (decision 32).
    const rotor = b.option(bool, "rotor", "Build colibri's .private kinds of colibri.Server and colibri.Client, on Rotor (decision 39)") orelse (b.pkg_hash.len == 0);
    const colibri = b.dependency("colibri", .{ .target = target, .release = release, .rotor = rotor });
    const graph = modules(b, stdx, colibri, target, optimize);
    for (colibri_exports) |name| {
        b.modules.put(b.graph.arena, name, colibri.module(name)) catch @panic("OOM");
    }

    const plugin = b.addExecutable(.{
        .name = "protoc-gen-connect-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protoc_gen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protobuf", .module = graph.protobuf },
                // The types of protovalidate's options, which the plugin reads (decision 47).
                .{ .name = "buf_validate_validate", .module = graph.protovalidate.import_table.get("buf_validate_validate").? },
                .{ .name = "public_names", .module = graph.public_names },
            },
        }),
    });
    b.installArtifact(plugin);
    // The plugin alone: `tools/generate_check.sh` builds it so, since a generated file that no
    // longer compiles must not keep the plugin that rewrites it from being built.
    b.step("plugin", "Build the protoc plugin alone into zig-out/bin").dependOn(&b.addInstallArtifact(plugin, .{}).step);

    // Everything below is connect-zig's own build. A project that depends on it stops here,
    // before the tooling requests pepegrillo (docs/decisions.md entry 15).
    if (b.pkg_hash.len != 0) return;

    const test_step = b.step("test", "Run the lint, then every module's unit tests and the examples");
    add_unit_tests(b, graph, plugin, test_step);
    test_step.dependOn(examples.add(b, graph));
    test_step.dependOn(conformance.add(b, graph));
    test_step.dependOn(checks.add(b, graph));
    test_step.dependOn(protovalidate.add(b, graph));
    if (lint.add(b)) |lint_step| test_step.dependOn(lint_step);
    line_coverage.add(b, graph, plugin);
    lean.add(b, graph);
    bench.add(b, graph.public_names, target);
    fullstack.add(b, graph);
    schema_programs.add(b, graph);
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
            .{ .name = "base64", .module = stdx.module("base64") },
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
            .{ .name = "base64", .module = stdx.module("base64") },
            .{ .name = "public_names", .module = public_names },
        },
    });
    // Decision 32: the library takes colibri's protocol modules alone, never `rotor` or the
    // `colibri` module, so any event loop can drive it. Rotor reaches the example programs only.
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
        .oidc = oidc_module(b, stdx, connect, public_names, target, optimize),
        .protovalidate = protovalidate_module(b, protobuf, public_names, target, optimize),
        .public_names = public_names,
        .colibri = colibri,
        .platform = stdx.module("platform"),
        .target = target,
        .optimize = optimize,
    };
}

/// Decision 34: the `oidc` module, which checks a token's signature with chapulin's `jws` calls.
/// It names no colibri module, so its interceptor serves any call type. chapulin builds those
/// calls for a host target alone, so another target has no `oidc` module.
fn oidc_module(b: *std.Build, stdx: *std.Build.Dependency, connect: *std.Build.Module, public_names: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Module {
    if (!chapulin.host_object(target)) return null;
    return b.addModule("oidc", .{
        .root_source_file = b.path("src/oidc/oidc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect },
            .{ .name = "json", .module = stdx.module("json") },
            .{ .name = "codec", .module = stdx.module("codec") },
            .{ .name = "chapulin", .module = chapulin.object(b, target).module("chapulin") },
            .{ .name = "public_names", .module = public_names },
        },
    });
}

/// Decision 47: the `protovalidate` module, and the generated code of validate.proto and of
/// descriptor.proto that it reads its rules and writes its violations with. Each generated file
/// is a module under the name the plugin gives its .proto file, so a program's generated code
/// that names a `buf.validate` type imports the same one.
fn protovalidate_module(b: *std.Build, protobuf: *std.Build.Module, public_names: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const descriptor = b.addModule("google_protobuf_descriptor", .{
        .root_source_file = b.path("src/protovalidate/gen/google/protobuf/descriptor.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf }},
    });
    const rules = b.addModule("buf_validate_validate", .{
        .root_source_file = b.path("src/protovalidate/gen/buf/validate/validate.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "google_protobuf_descriptor", .module = descriptor },
        },
    });
    return b.addModule("protovalidate", .{
        .root_source_file = b.path("src/protovalidate/protovalidate.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "buf_validate_validate", .module = rules },
            .{ .name = "google_protobuf_descriptor", .module = descriptor },
            .{ .name = "public_names", .module = public_names },
        },
    });
}

fn add_unit_tests(b: *std.Build, graph: Graph, plugin: *std.Build.Step.Compile, test_step: *std.Build.Step) void {
    const targets = [_]struct { name: []const u8, module: ?*std.Build.Module }{
        .{ .name = "protobuf", .module = graph.protobuf },
        .{ .name = "connect", .module = graph.connect },
        .{ .name = "connect-colibri", .module = graph.connect_colibri },
        .{ .name = "oidc", .module = graph.oidc },
        .{ .name = "protovalidate", .module = graph.protovalidate },
        .{ .name = "public-names", .module = graph.public_names },
        .{ .name = "plugin", .module = plugin.root_module },
    };
    for (targets) |each| {
        const module = each.module orelse continue;
        const unit = b.addTest(.{ .name = each.name, .root_module = module });
        const run = b.addRunArtifact(unit);
        const step = b.step(b.fmt("test-{s}", .{each.name}), b.fmt("Run the {s} tests alone", .{each.name}));
        step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
}
