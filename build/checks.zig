//! The check programs of tools/ (decision 41), which are not examples:
//!
//! - `coverage`, the converter `tools/coverage_check.sh` runs against `buf convert`;
//! - `interop-server`, which `tools/interop_languages_check.sh` runs the clients of interop/
//!   against, and `zig build run-interop-server -- [port]` starts;
//! - `interop-client`, connect-zig's client against the servers of interop/, which
//!   `tools/interop_servers_check.sh` runs;
//! - `zig build test-generated`, which compiles the generated code and runs its round trips.
//!
//! `add` returns the step `zig build test` runs: the generated code's tests and the interop
//! client's.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

/// The generated modules of tools/gen, each with the modules its header names.
const Schemas = struct {
    coverage: *std.Build.Module,
    editions: *std.Build.Module,
    legacy: *std.Build.Module,
    interop: *std.Build.Module,
};

pub fn add(b: *std.Build, graph: Graph) *std.Build.Step {
    const step = b.step("checks", "Build the check programs of tools/ and run their tests");
    const coverage = generated(b, graph, "tools/gen/coverage/v1/coverage.pb.zig", &.{});
    const schemas: Schemas = .{
        .coverage = coverage,
        .editions = generated(b, graph, "tools/gen/editions/v1/editions.pb.zig", &.{}),
        .legacy = generated(b, graph, "tools/gen/legacy/v1/legacy.pb.zig", &.{}),
        .interop = generated(b, graph, "tools/gen/interop/v1/interop.pb.zig", &.{.{ .name = "coverage_v1_coverage", .module = coverage }}),
    };
    add_coverage(b, graph, schemas);
    step.dependOn(add_generated(b, graph));
    // The interop programs run colibri's TLS, which a program defines chapulin's hook for, and
    // the server runs on Rotor: a host target alone builds them, as the examples' servers.
    if (graph.oidc == null) return step;
    const hooks = b.createModule(.{ .root_source_file = b.path("examples/services/hooks.zig"), .target = graph.target, .optimize = graph.optimize });
    const test_identity = b.createModule(.{ .root_source_file = b.path("examples/testdata/tls/identity.zig"), .target = graph.target, .optimize = graph.optimize });
    add_interop_server(b, graph, schemas, hooks, test_identity);
    step.dependOn(add_interop_client(b, graph, schemas, hooks));
    return step;
}

fn add_coverage(b: *std.Build, graph: Graph, schemas: Schemas) void {
    const coverage = b.addExecutable(.{ .name = "coverage", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/coverage/main.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "coverage", .module = schemas.coverage },
            .{ .name = "editions", .module = schemas.editions },
            .{ .name = "legacy", .module = schemas.legacy },
        },
    }) });
    b.installArtifact(coverage);
}

/// `zig build test-generated`: the code `buf generate` wrote into examples/gen compiles, and its
/// messages round-trip. `tools/generate_check.sh` compares that code with what buf writes now,
/// which needs buf, so it runs from `tools/ci.sh` and not from `zig build test` (design §8 step 6).
fn add_generated(b: *std.Build, graph: Graph) *std.Build.Step {
    // A generated file reaches another by the module name its header states (design §8 step 6):
    // kitchen.proto and large.proto import shared.proto as `kitchen_v1_shared`.
    const shared = generated(b, graph, "examples/gen/kitchen/v1/shared.pb.zig", &.{});
    const shared_import: std.Build.Module.Import = .{ .name = "kitchen_v1_shared", .module = shared };
    const module = b.createModule(.{
        .root_source_file = b.path("tools/generated/generated_test.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "kitchen", .module = generated(b, graph, "examples/gen/kitchen/v1/kitchen.pb.zig", &.{shared_import}) },
            .{ .name = "eliza", .module = generated(b, graph, "examples/gen/connectrpc/eliza/v1/eliza.pb.zig", &.{}) },
            .{ .name = "large", .module = generated(b, graph, "examples/gen/large/v1/large.pb.zig", &.{shared_import}) },
        },
    });
    const run = b.addRunArtifact(b.addTest(.{ .name = "generated", .root_module = module }));
    const step = b.step("test-generated", "Compile the generated code of examples/gen and run its round trips");
    step.dependOn(&run.step);
    return step;
}

fn add_interop_server(b: *std.Build, graph: Graph, schemas: Schemas, hooks: *std.Build.Module, test_identity: *std.Build.Module) void {
    const exe = b.addExecutable(.{ .name = "interop-server", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/interop_server/main.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "connect", .module = graph.connect },
            .{ .name = "connect_colibri", .module = graph.connect_colibri },
            .{ .name = "server", .module = graph.colibri.module("server") },
            .{ .name = "colibri", .module = graph.colibri.module("colibri") },
            .{ .name = "tls", .module = graph.colibri.module("tls") },
            .{ .name = "test_identity", .module = test_identity },
            .{ .name = "hooks", .module = hooks },
            .{ .name = "coverage", .module = schemas.coverage },
            .{ .name = "interop", .module = schemas.interop },
        },
    }) });
    b.installArtifact(exe);
    const serve = b.addRunArtifact(exe);
    if (b.args) |args| serve.addArgs(args);
    b.step("run-interop-server", "Serve interop.v1 on a TCP socket: zig build run-interop-server -- [port]").dependOn(&serve.step);
}

/// `zig build interop-client` installs connect-zig's client against the servers of interop/, which
/// `tools/interop_servers_check.sh` runs. It drives its pool with the conformance client's
/// transport, over TCP with `poll` (decision 32). Returns the step that runs its unit tests,
/// which also builds it.
fn add_interop_client(b: *std.Build, graph: Graph, schemas: Schemas, hooks: *std.Build.Module) *std.Build.Step {
    const transport = b.createModule(.{
        .root_source_file = b.path("conformance/client_transport.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "client", .module = graph.colibri.module("client") },
            .{ .name = "tls", .module = graph.colibri.module("tls") },
        },
    });
    const exe = b.addExecutable(.{ .name = "interop-client", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/interop_client/main.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "connect", .module = graph.connect },
            .{ .name = "connect_colibri", .module = graph.connect_colibri },
            .{ .name = "client", .module = graph.colibri.module("client") },
            .{ .name = "tls", .module = graph.colibri.module("tls") },
            .{ .name = "client_transport", .module = transport },
            .{ .name = "hooks", .module = hooks },
            .{ .name = "coverage", .module = schemas.coverage },
            .{ .name = "interop", .module = schemas.interop },
        },
    }) });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    b.step("interop-client", "Build the client of tools/interop_servers_check.sh into zig-out/bin").dependOn(&install.step);
    const unit = b.addTest(.{ .name = "interop-client", .root_module = exe.root_module });
    const run = b.addRunArtifact(unit);
    run.step.dependOn(&install.step);
    return &run.step;
}

fn generated(b: *std.Build, graph: Graph, path: []const u8, extra: []const std.Build.Module.Import) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path(path), .target = graph.target, .optimize = graph.optimize });
    module.addImport("protobuf", graph.protobuf);
    module.addImport("connect", graph.connect);
    for (extra) |import| module.addImport(import.name, import.module);
    return module;
}
