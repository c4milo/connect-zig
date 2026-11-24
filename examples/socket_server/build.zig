//! The socket server (decision 41): the service of each example project, under one router, on a
//! real socket. `zig build serve -- [port]` runs it; `zig build test` builds it.
//! `tools/interop_check.sh` calls it with curl and buf curl.
const std = @import("std");

/// The example projects whose services the server serves, and the modules each exports.
const services = [_]struct { project: []const u8, modules: []const []const u8 }{
    .{ .project = "eliza", .modules = &.{ "eliza", "eliza_service" } },
    .{ .project = "streaming", .modules = &.{"streaming_service"} },
    .{ .project = "interceptors", .modules = &.{"interceptors_service"} },
    .{ .project = "errors", .modules = &.{"errors_service"} },
    .{ .project = "github", .modules = &.{"github_service"} },
    .{ .project = "oidc", .modules = &.{"account_service"} },
    .{ .project = "otlp", .modules = &.{ "otlp", "otlp_service" } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const release = optimize == .ReleaseSafe;
    // Each project asks connect-zig with these options, so the build holds one connect-zig.
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = true });
    const harness = b.dependency("harness", .{ .target = target, .release = release });
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    for ([_][]const u8{ "connect", "connect_colibri", "server", "oidc" }) |name| module.addImport(name, connect_zig.module(name));
    module.addImport("harness", harness.module("harness"));
    // stdx, with connect-zig's options, so its `platform` is the module connect-zig imports.
    module.addImport("platform", b.dependency("stdx", .{ .target = target, .release = release }).module("platform"));
    for (services) |service| {
        const project = b.dependency(service.project, .{ .target = target, .release = release });
        for (service.modules) |name| module.addImport(name, project.module(name));
    }
    const exe = b.addExecutable(.{ .name = "eliza-server", .root_module = module });
    b.installArtifact(exe);
    const serve = b.addRunArtifact(exe);
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve every example's service on a socket: zig build serve -- [port]").dependOn(&serve.step);
    b.step("test", "Build the server").dependOn(&exe.step);
}
