//! `zig build examples` builds and runs every program in examples/, and `zig build example-<name>`
//! runs one. Each checks what arrived and exits with an error otherwise (design §8 step 5).
//! `zig build run-eliza-server -- [port]` serves the ELIZA and demo services on a TCP socket.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

pub fn add(b: *std.Build, graph: Graph) *std.Build.Step {
    const step = b.step("examples", "Build and run every example");
    // The converter tools/coverage_check.sh runs against buf convert; `zig build` installs it.
    const coverage_module = generated(b, graph, "examples/gen/coverage/v1/coverage.pb.zig", &.{});
    const coverage = b.addExecutable(.{ .name = "coverage", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/coverage.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "coverage", .module = coverage_module },
            .{ .name = "editions", .module = generated(b, graph, "examples/gen/editions/v1/editions.pb.zig", &.{}) },
            .{ .name = "legacy", .module = generated(b, graph, "examples/gen/legacy/v1/legacy.pb.zig", &.{}) },
        },
    }) });
    b.installArtifact(coverage);
    const rotor_dependency = b.lazyDependency("rotor", .{ .target = graph.target, .release = graph.optimize == .ReleaseSafe }) orelse return step;
    const rotor = rotor_dependency.module("rotor");
    const eliza = generated(b, graph, "examples/gen/connectrpc/eliza/v1/eliza.pb.zig", &.{});
    // The kitchen-sink messages, which reach shared.proto's through its module (decision 17).
    const shared = generated(b, graph, "examples/gen/kitchen/v1/shared.pb.zig", &.{});
    const kitchen = generated(b, graph, "examples/gen/kitchen/v1/kitchen.pb.zig", &.{.{ .name = "kitchen_v1_shared", .module = shared }});
    for ([_]Small{
        .{ .name = "protobuf_messages", .description = "Encode and decode generated messages in binary and JSON" },
        .{ .name = "sans_io_call", .description = "Run Connect and gRPC-Web calls through the connect module alone" },
    }) |small| {
        const exe = b.addExecutable(.{ .name = small.name, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{small.name})),
            .target = graph.target,
            .optimize = graph.optimize,
            .imports = &.{
                .{ .name = "protobuf", .module = graph.protobuf },
                .{ .name = "connect", .module = graph.connect },
                .{ .name = "eliza", .module = eliza },
                .{ .name = "kitchen", .module = kitchen },
            },
        }) });
        const small_run = b.addRunArtifact(exe);
        b.step(b.fmt("example-{s}", .{small.name}), small.description).dependOn(&small_run.step);
        step.dependOn(&small_run.step);
    }

    // The test-only TLS identity of the h3 rounds (decision 25), a module of its own so that
    // `@embedFile` reaches its PEM files.
    const test_identity = b.createModule(.{ .root_source_file = b.path("examples/testdata/tls/identity.zig"), .target = graph.target, .optimize = graph.optimize });
    const services: Services = .{
        .eliza = eliza,
        .demo = generated(b, graph, "examples/gen/demo/v1/demo.pb.zig", &.{}),
        .rotor = rotor,
        .test_identity = test_identity,
    };
    for ([_]Small{
        .{ .name = "eliza", .description = "Run the ELIZA example over colibri's h2 and h11" },
        .{ .name = "interceptors", .description = "Run calls through server and client interceptors" },
        .{ .name = "streaming", .description = "Run bidirectional, client and server streams" },
        .{ .name = "errors", .description = "Run calls that fail with typed error details" },
    }) |linked| {
        const exe = program(b, graph, linked.name, b.fmt("examples/{s}.zig", .{linked.name}), services);
        const run = b.addRunArtifact(exe);
        b.step(b.fmt("example-{s}", .{linked.name}), linked.description).dependOn(&run.step);
        step.dependOn(&run.step);
    }

    const socket_server = program(b, graph, "eliza-server", "examples/socket_server.zig", services);
    socket_server.root_module.addImport("socket_loop", socket_loop(b, graph, rotor));
    b.installArtifact(socket_server);
    const serve = b.addRunArtifact(socket_server);
    if (b.args) |args| serve.addArgs(args);
    b.step("run-eliza-server", "Serve ELIZA on a TCP socket: zig build run-eliza-server -- [port]").dependOn(&serve.step);
    return step;
}

/// An example that needs no HTTP library: its name, which is its file's, and what it shows.
const Small = struct { name: []const u8, description: []const u8 };

fn generated(b: *std.Build, graph: Graph, path: []const u8, extra: []const std.Build.Module.Import) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path(path), .target = graph.target, .optimize = graph.optimize });
    module.addImport("protobuf", graph.protobuf);
    module.addImport("connect", graph.connect);
    for (extra) |import| module.addImport(import.name, import.module);
    return module;
}

/// The socket loop the example socket server and the conformance server share (decision 22).
pub fn socket_loop(b: *std.Build, graph: Graph, rotor: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("examples/services/socket_loop.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "server", .module = graph.colibri.module("server") },
            .{ .name = "rotor", .module = rotor },
        },
    });
}

/// The modules a program over colibri imports beyond the library's own.
const Services = struct {
    eliza: *std.Build.Module,
    demo: *std.Build.Module,
    rotor: *std.Build.Module,
    test_identity: *std.Build.Module,
};

fn program(b: *std.Build, graph: Graph, name: []const u8, path: []const u8, services: Services) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = graph.target,
            .optimize = graph.optimize,
            .imports = &.{
                .{ .name = "protobuf", .module = graph.protobuf },
                .{ .name = "connect", .module = graph.connect },
                .{ .name = "connect_colibri", .module = graph.connect_colibri },
                .{ .name = "server", .module = graph.colibri.module("server") },
                .{ .name = "client", .module = graph.colibri.module("client") },
                .{ .name = "tls", .module = graph.colibri.module("tls") },
                .{ .name = "test_identity", .module = services.test_identity },
                .{ .name = "eliza", .module = services.eliza },
                .{ .name = "demo", .module = services.demo },
                .{ .name = "rotor", .module = services.rotor },
            },
        }),
    });
}
