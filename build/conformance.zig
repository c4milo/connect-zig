//! `zig build conformance-server` and `zig build conformance-client` build the conformance server
//! and client of conformance/ and install them to zig-out/bin, where `tools/conformance_check.sh`
//! runs each under the connectrpc conformance runner (design §8 step 7). `zig build
//! test-conformance` runs their unit tests. `zig build protobuf-testee` builds the program that
//! Google's protobuf conformance runner tests, which `tools/protobuf_conformance_check.sh` runs
//! (decision 38).
const std = @import("std");

const Graph = @import("graph.zig").Graph;

/// The generated code of conformance/gen, which names its files by the module of each .proto.
const generated_directory = "conformance/gen/connectrpc/conformance/v1/";

/// The generated code of the protobuf conformance suite's own protos: the runner's protocol,
/// and the test messages up to edition 2023. Each is a module under the name the program
/// imports.
const protobuf_suite = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "conformance_pb", .path = "conformance/gen/conformance/conformance.pb.zig" },
    .{ .name = "test_messages_proto3", .path = "conformance/gen/google/protobuf/test_messages_proto3.pb.zig" },
    .{ .name = "test_messages_proto2", .path = "conformance/gen/google/protobuf/test_messages_proto2.pb.zig" },
    .{ .name = "test_messages_edition2023", .path = "conformance/gen/google/protobuf/test_messages_edition2023.pb.zig" },
    .{ .name = "test_messages_proto3_editions", .path = "conformance/gen/google/protobuf/test_messages_proto3_editions.pb.zig" },
    .{ .name = "test_messages_proto2_editions", .path = "conformance/gen/google/protobuf/test_messages_proto2_editions.pb.zig" },
};

/// Adds the step that builds the protobuf conformance suite's program, and returns it.
fn add_protobuf_testee(b: *std.Build, graph: Graph) *std.Build.Step {
    const root = b.createModule(.{
        .root_source_file = b.path("conformance/protobuf_testee.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
    });
    root.addImport("protobuf", graph.protobuf);
    for (protobuf_suite) |file| {
        const module = b.createModule(.{ .root_source_file = b.path(file.path), .target = graph.target, .optimize = graph.optimize });
        module.addImport("connect_zig", graph.connect_zig_core);
        root.addImport(file.name, module);
    }
    const exe = b.addExecutable(.{ .name = "protobuf-testee", .root_module = root });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    b.step("protobuf-testee", "Build the protobuf conformance suite's program into zig-out/bin").dependOn(&install.step);
    return &install.step;
}

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
        // stdx's type of CPU features, which the server's context holds.
        .{ .name = "platform", .module = graph.platform },
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
    step.dependOn(add_protobuf_testee(b, graph));
    return step;
}

fn generated(b: *std.Build, graph: Graph, comptime name: []const u8, extra: []const std.Build.Module.Import) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(generated_directory ++ name ++ ".pb.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
    });
    module.addImport("protobuf", graph.protobuf);
    module.addImport("connect_zig", graph.connect_zig_core);
    for (extra) |import| module.addImport(import.name, import.module);
    return module;
}
