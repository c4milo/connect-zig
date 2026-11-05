//! `zig build examples` builds and runs every program in examples/, and `zig build example-<name>`
//! runs one. Each checks what arrived and exits with an error otherwise (design §8 step 5).
//! `zig build run-eliza-server -- [port]` runs the ELIZA server on a TCP socket.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

pub fn add(b: *std.Build, graph: Graph) *std.Build.Step {
    const step = b.step("examples", "Build and run every example");
    const rotor_dependency = b.lazyDependency("rotor", .{ .target = graph.target, .release = graph.optimize == .ReleaseSafe }) orelse return step;
    const rotor = rotor_dependency.module("rotor");
    const eliza = b.createModule(.{
        .root_source_file = b.path("examples/gen/connectrpc/eliza/v1/eliza.pb.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "connect", .module = graph.connect },
        },
    });
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

    const exchange = program(b, graph, "eliza", "examples/eliza/exchange.zig", eliza, rotor);
    const run = b.addRunArtifact(exchange);
    b.step("example-eliza", "Run the ELIZA example over colibri's h2 and h11").dependOn(&run.step);
    step.dependOn(&run.step);

    const socket_server = program(b, graph, "eliza-server", "examples/eliza/socket_server.zig", eliza, rotor);
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

fn program(b: *std.Build, graph: Graph, name: []const u8, path: []const u8, eliza: *std.Build.Module, rotor: *std.Build.Module) *std.Build.Step.Compile {
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
                .{ .name = "eliza", .module = eliza },
                .{ .name = "rotor", .module = rotor },
            },
        }),
    });
}
