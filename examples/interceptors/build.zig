//! The interceptors example (decision 41): interceptors.v1.WhoamiService behind two server
//! interceptors, and a client with interceptors of its own that calls it in memory over h2 and
//! h3.
//!
//! - `zig build run` runs the client against the service; `zig build test` does the same, and
//!   fails on a wrong answer.
//! - `zig build serve -- [port]` serves Whoami on a socket, over TLS, for curl and buf curl.
//! - `zig build plugin` installs connect-zig's plugin, and `buf generate` then writes gen/ from
//!   proto/.
//! - The package exports `interceptors`, the generated code, and `interceptors_service`, the
//!   handler and its interceptors, for a project that serves Whoami beside its own services.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const release = optimize == .ReleaseSafe;
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = true });
    const harness = b.dependency("harness", .{ .target = target, .release = release });
    // With connect-zig's options, so its `platform` is the module connect-zig imports.
    const stdx = b.dependency("stdx", .{ .target = target, .release = release });
    const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
    b.step("plugin", "Install connect-zig's protoc plugin to zig-out/bin").dependOn(&plugin.step);

    const interceptors = b.addModule("interceptors", .{
        .root_source_file = b.path("gen/interceptors/v1/interceptors.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
        },
    });
    const service = b.addModule("interceptors_service", .{
        .root_source_file = b.path("src/service/service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "interceptors", .module = interceptors },
        },
    });
    const exe = b.addExecutable(.{ .name = "interceptors", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "client", .module = connect_zig.module("client") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "interceptors", .module = interceptors },
            .{ .name = "interceptors_service", .module = service },
        },
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the client against the Whoami service").dependOn(&run.step);
    b.step("test", "Run the example, which fails on a wrong answer").dependOn(&run.step);

    // The same routes on a socket, to play with.
    const server = b.addExecutable(.{ .name = "interceptors-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "interceptors", .module = interceptors },
            .{ .name = "interceptors_service", .module = service },
        },
    }) });
    b.installArtifact(server);
    const serve = b.addRunArtifact(server);
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve Whoami on a socket: zig build serve -- [port]").dependOn(&serve.step);
}
