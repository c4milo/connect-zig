//! `zig build conformance-server` and `zig build conformance-client` build the conformance server
//! and client of conformance/ and install them to zig-out/bin, where `tools/conformance_check.sh`
//! runs each under the connectrpc conformance runner (design §8 step 7). `zig build
//! test-conformance` runs their unit tests.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

/// The generated code of conformance/gen, which names its files by the module of each .proto.
const generated_directory = "conformance/gen/connectrpc/conformance/v1/";

/// Adds the server's steps and returns the step that runs its unit tests.
pub fn add(b: *std.Build, graph: Graph) *std.Build.Step {
    const config = generated(b, graph, "config", &.{});
    const config_import: std.Build.Module.Import = .{ .name = "connectrpc_conformance_v1_config", .module = config };
    const service = generated(b, graph, "service", &.{config_import});
    const server_compat = generated(b, graph, "server_compat", &.{config_import});
    const service_import: std.Build.Module.Import = .{ .name = "connectrpc_conformance_v1_service", .module = service };
    const client_compat = generated(b, graph, "client_compat", &.{ config_import, service_import });
    const imports = [_]std.Build.Module.Import{
        .{ .name = "protobuf", .module = graph.protobuf },
        .{ .name = "connect", .module = graph.connect },
        .{ .name = "connect_colibri", .module = graph.connect_colibri },
        .{ .name = "server", .module = graph.colibri.module("server") },
        .{ .name = "http", .module = graph.colibri.module("http") },
        .{ .name = "colibri", .module = graph.colibri.module("colibri") },
        .{ .name = "tls", .module = graph.colibri.module("tls") },
        config_import,
        service_import,
        .{ .name = "connectrpc_conformance_v1_server_compat", .module = server_compat },
        .{ .name = "connectrpc_conformance_v1_client_compat", .module = client_compat },
        .{ .name = "client", .module = graph.colibri.module("client") },
    };
    const exe = b.addExecutable(.{ .name = "conformance-server", .root_module = b.createModule(.{
        .root_source_file = b.path("conformance/server.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &imports,
    }) });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    b.step("conformance-server", "Build the conformance server into zig-out/bin").dependOn(&install.step);

    // The client half (design §8 step 7): connect-zig's client against the runner's reference
    // server.
    const client_exe = b.addExecutable(.{ .name = "conformance-client", .root_module = b.createModule(.{
        .root_source_file = b.path("conformance/client.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &imports,
    }) });
    const client_install = b.addInstallArtifact(client_exe, .{});
    b.getInstallStep().dependOn(&client_install.step);
    b.step("conformance-client", "Build the conformance client into zig-out/bin").dependOn(&client_install.step);

    const unit = b.addTest(.{ .name = "conformance", .root_module = b.createModule(.{
        .root_source_file = b.path("conformance/conformance_test.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &imports,
    }) });
    const run = b.addRunArtifact(unit);
    const step = b.step("test-conformance", "Run the conformance server's unit tests alone");
    step.dependOn(&run.step);
    // The test step also builds the server, so a change that breaks it fails `zig build test`.
    step.dependOn(&install.step);
    step.dependOn(&client_install.step);
    return step;
}

fn generated(b: *std.Build, graph: Graph, comptime name: []const u8, extra: []const std.Build.Module.Import) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(generated_directory ++ name ++ ".pb.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
    });
    module.addImport("protobuf", graph.protobuf);
    module.addImport("connect", graph.connect);
    for (extra) |import| module.addImport(import.name, import.module);
    return module;
}
