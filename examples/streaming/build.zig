//! The streaming example (decision 41): streaming.v1.StreamingService, and a client that calls
//! each of its streams in memory over h11, h2 and h3.
//!
//! - `zig build run` runs the client against the service; `zig build test` does the same, and
//!   fails on a wrong answer.
//! - `zig build serve -- [port]` serves the streaming service on a socket, over TLS, for curl and
//!   buf curl.
//! - `zig build plugin` installs connect-zig's plugin, and `buf generate` then writes gen/ from
//!   proto/.
//! - The package exports `streaming`, the generated code, and `streaming_service`, the handlers,
//!   for a project that serves the streaming service beside its own services.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const release = optimize == .ReleaseSafe;
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = true });
    const harness = b.dependency("harness", .{ .target = target, .release = release });
    const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
    b.step("plugin", "Install connect-zig's protoc plugin to zig-out/bin").dependOn(&plugin.step);

    const streaming = b.addModule("streaming", .{
        .root_source_file = b.path("gen/streaming/v1/streaming.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
        },
    });
    const service = b.addModule("streaming_service", .{
        .root_source_file = b.path("src/service/service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "streaming", .module = streaming },
        },
    });
    const exe = b.addExecutable(.{ .name = "streaming", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "client", .module = connect_zig.module("client") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "streaming", .module = streaming },
            .{ .name = "streaming_service", .module = service },
        },
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the client against the streaming service").dependOn(&run.step);
    b.step("test", "Run the example, which fails on a wrong answer").dependOn(&run.step);

    // The same routes on a socket, to play with.
    const server = b.addExecutable(.{ .name = "streaming-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "streaming", .module = streaming },
            .{ .name = "streaming_service", .module = service },
        },
    }) });
    b.installArtifact(server);
    const serve = b.addRunArtifact(server);
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve the streaming service on a socket: zig build serve -- [port]").dependOn(&serve.step);
}
