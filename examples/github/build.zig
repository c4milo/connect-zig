//! The GitHub-style example (decision 41): github.v1.RepositoryService and github.v1.IssueService,
//! and a client that calls them in memory over h2 and h3, as a real client would.
//!
//! - `zig build run` runs the client against the services; `zig build test` does the same, and
//!   fails on a wrong answer. It runs the service's unit tests too.
//! - `zig build serve -- [port]` serves both services on a socket, over TLS, for curl and buf
//!   curl.
//! - `zig build plugin` installs connect-zig's plugin, and `buf generate` then writes gen/ from
//!   proto/.
//! - The package exports `github`, the generated code, and `github_service`, the handlers and
//!   their interceptors, for a project that serves these services beside its own.
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

    const github = b.addModule("github", .{
        .root_source_file = b.path("gen/github/v1/github.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
        },
    });
    const service = b.addModule("github_service", .{
        .root_source_file = b.path("src/service/service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "github", .module = github },
        },
    });
    const exe = b.addExecutable(.{ .name = "github", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "client", .module = connect_zig.module("client") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "github", .module = github },
            .{ .name = "github_service", .module = service },
        },
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the client against the GitHub-style services").dependOn(&run.step);
    // The service's tests, over the service's files and the harness, whose hook chapulin needs.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/service/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "github", .module = github },
        },
    }) });
    const service_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the service's tests and the example, which fails on a wrong answer");
    test_step.dependOn(&service_tests.step);
    test_step.dependOn(&run.step);

    // The same routes on a socket, to play with.
    const server = b.addExecutable(.{ .name = "github-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "github", .module = github },
            .{ .name = "github_service", .module = service },
        },
    }) });
    b.installArtifact(server);
    const serve = b.addRunArtifact(server);
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve both services on a socket: zig build serve -- [port]").dependOn(&serve.step);
}
