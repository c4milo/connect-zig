//! connect-zig's build: the module graph of docs/design.md §3, the tests, the plugin, the
//! examples and the tooling. Helpers live in build/.
//!
//! A project that depends on connect-zig takes one module, `dependency.module("connect_zig")`
//! (decision 52). It names every library module, colibri's `server`, `client`, `http`, `tls` and
//! `colibri`, stdx's `platform`, and the generated code of validate.proto and descriptor.proto.
//! `.colibri = false` leaves colibri and `oidc` out of it, so a program links no chapulin.
//! `.rotor = true` builds colibri's `.private` kinds on Rotor (decision 39).
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
    // Decision 52: whether the module `connect_zig` names colibri. A program that codes messages
    // or runs the protocol on an HTTP library of its own passes `.colibri = false`.
    const with_colibri = b.option(bool, "colibri", "Name colibri, connect_colibri and oidc in the connect_zig module, which links chapulin (decision 52)") orelse true;
    const graph = modules(b, stdx, colibri, with_colibri, target, optimize);

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

fn modules(b: *std.Build, stdx: *std.Build.Dependency, colibri: *std.Build.Dependency, with_colibri: bool, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Graph {
    const public_names = b.createModule(.{
        .root_source_file = b.path("src/public_names/public_names.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protobuf = b.createModule(.{
        .root_source_file = b.path("src/protobuf/protobuf.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json", .module = stdx.module("json") },
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "base64", .module = stdx.module("base64") },
            .{ .name = "public_names", .module = public_names },
        },
    });
    const connect = b.createModule(.{
        .root_source_file = b.path("src/connect/connect.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "json", .module = stdx.module("json") },
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "gzip", .module = stdx.module("gzip") },
            .{ .name = "zstd", .module = stdx.module("zstd") },
            .{ .name = "brotli", .module = stdx.module("brotli") },
            .{ .name = "base64", .module = stdx.module("base64") },
            .{ .name = "public_names", .module = public_names },
        },
    });
    // Decision 32: the library takes colibri's protocol modules alone, never `rotor` or the
    // `colibri` module, so any event loop can drive it. Rotor reaches the example programs only.
    const connect_colibri = b.createModule(.{
        .root_source_file = b.path("src/connect_colibri/connect_colibri.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect },
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "colibri", .module = colibri.module("colibri") },
            // stdx's type of CPU features, which a route reads from the program's context.
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "public_names", .module = public_names },
        },
    });
    const oidc = oidc_module(b, stdx, connect, public_names, target, optimize);
    const validate = protovalidate_module(b, protobuf, public_names, stdx, target, optimize);
    const exports: Exports = .{
        .protobuf = protobuf,
        .connect = connect,
        .connect_colibri = connect_colibri,
        .protovalidate = validate,
        .oidc = oidc,
        .colibri = colibri,
        .platform = stdx.module("platform"),
        .public_names = public_names,
    };
    // The package exports the module as the program asked for it. The build's own checks build
    // generated code over the module without colibri, so a check that serves no RPC links no
    // chapulin, and over the module with it in `test-connect-zig`.
    const connect_zig = connect_zig_module(b, exports, with_colibri, target, optimize);
    b.modules.put(b.graph.arena, "connect_zig", connect_zig) catch @panic("OOM");
    return .{
        .protobuf = protobuf,
        .connect = connect,
        .connect_colibri = connect_colibri,
        .oidc = oidc,
        .protovalidate = validate,
        .connect_zig = connect_zig,
        .connect_zig_core = if (with_colibri) connect_zig_module(b, exports, false, target, optimize) else connect_zig,
        .public_names = public_names,
        .colibri = colibri,
        .platform = stdx.module("platform"),
        .target = target,
        .optimize = optimize,
    };
}

const Exports = struct {
    protobuf: *std.Build.Module,
    connect: *std.Build.Module,
    connect_colibri: *std.Build.Module,
    protovalidate: *std.Build.Module,
    oidc: ?*std.Build.Module,
    colibri: *std.Build.Dependency,
    platform: *std.Build.Module,
    public_names: *std.Build.Module,
};

/// Decision 52: the module `connect_zig`. It names the library's modules and stdx's `platform`,
/// each the copy the library itself builds on, so a program and its generated code hold one copy
/// of each. With `with_colibri` it also names colibri's modules (decision 39) and those over them.
fn connect_zig_module(b: *std.Build, exports: Exports, with_colibri: bool, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "colibri", with_colibri);
    options.addOption(bool, "oidc", with_colibri and exports.oidc != null);
    const module = b.createModule(.{
        .root_source_file = b.path("src/connect_zig/connect_zig.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_zig_options", .module = options.createModule() },
            .{ .name = "protobuf", .module = exports.protobuf },
            .{ .name = "connect", .module = exports.connect },
            .{ .name = "protovalidate", .module = exports.protovalidate },
            .{ .name = "platform", .module = exports.platform },
            .{ .name = "buf_validate_validate", .module = exports.protovalidate.import_table.get("buf_validate_validate").? },
            .{ .name = "google_protobuf_descriptor", .module = exports.protovalidate.import_table.get("google_protobuf_descriptor").? },
            .{ .name = "public_names", .module = exports.public_names },
        },
    });
    if (!with_colibri) return module;
    module.addImport("connect_colibri", exports.connect_colibri);
    // colibri's package exports one module, which names each of its others (colibri decision 170).
    module.addImport("colibri", exports.colibri.module("colibri"));
    if (exports.oidc) |oidc| module.addImport("oidc", oidc);
    return module;
}

/// Decision 34: the `oidc` module, which checks a token's signature with chapulin's `jws` calls.
/// It names no colibri module, so its interceptor serves any call type. chapulin builds those
/// calls for a host target alone, so another target has no `oidc` module.
fn oidc_module(b: *std.Build, stdx: *std.Build.Dependency, connect: *std.Build.Module, public_names: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Module {
    if (!chapulin.host_object(target)) return null;
    return b.createModule(.{
        .root_source_file = b.path("src/oidc/oidc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect },
            .{ .name = "json", .module = stdx.module("json") },
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "chapulin", .module = chapulin.object(b, target).module("chapulin") },
            .{ .name = "public_names", .module = public_names },
        },
    });
}

/// Decision 47: the `protovalidate` module, and the generated code of validate.proto and of
/// descriptor.proto that it reads its rules and writes its violations with. Each generated file
/// is a module under the name the plugin gives its .proto file, so a program's generated code
/// that names a `buf.validate` type imports the same one.
fn protovalidate_module(b: *std.Build, protobuf: *std.Build.Module, public_names: *std.Build.Module, stdx: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const descriptor = b.createModule(.{
        .root_source_file = b.path("src/protovalidate/gen/google/protobuf/descriptor.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf }},
    });
    const rules = b.createModule(.{
        .root_source_file = b.path("src/protovalidate/gen/buf/validate/validate.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "google_protobuf_descriptor", .module = descriptor },
        },
    });
    return b.createModule(.{
        .root_source_file = b.path("src/protovalidate/protovalidate.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "buf_validate_validate", .module = rules },
            .{ .name = "google_protobuf_descriptor", .module = descriptor },
            .{ .name = "public_names", .module = public_names },
            // `pattern` and CEL's `matches` (design §8 step 35), and the CPU features a program
            // passes them, stdx's `platform.CpuFeatures`.
            .{ .name = "regex", .module = stdx.module("regex") },
            .{ .name = "platform", .module = stdx.module("platform") },
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
        .{ .name = "connect-zig", .module = graph.connect_zig },
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
