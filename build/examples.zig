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
