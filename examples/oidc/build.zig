//! The OpenID Connect example (decision 41): account.v1.AccountService behind `oidc.Interceptor`,
//! a test issuer that signs tokens, and a client that calls the service in memory over h2 and h3.
//!
//! - `zig build run` runs the client against the service; `zig build test` does the same, and
//!   fails on a wrong answer.
//! - `zig build serve -- [port]` serves the account service on a socket, over TLS, for curl and
//!   buf curl.
//! - `zig build plugin` installs connect-zig's plugin, and `buf generate` then writes gen/ from
//!   proto/.
//! - The package exports `account`, the generated code, and `account_service`, the handlers with
//!   the test issuer, for a project that serves the account service beside its own services.
//! - connect-zig has an `oidc` module on a host target alone (decision 34), so this project
//!   builds for a host target alone.
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

    const account = b.addModule("account", .{
        .root_source_file = b.path("gen/account/v1/account.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
        },
    });
    const service = b.addModule("account_service", .{
        .root_source_file = b.path("src/service/service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "oidc", .module = connect_zig.module("oidc") },
            .{ .name = "account", .module = account },
        },
    });
    const exe = b.addExecutable(.{ .name = "oidc", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "oidc", .module = connect_zig.module("oidc") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "account", .module = account },
            .{ .name = "account_service", .module = service },
        },
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the client against the account service").dependOn(&run.step);
    b.step("test", "Run the example, which fails on a wrong answer").dependOn(&run.step);

    // The same routes on a socket, to play with.
    const server = b.addExecutable(.{ .name = "oidc-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "oidc", .module = connect_zig.module("oidc") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "account", .module = account },
            .{ .name = "account_service", .module = service },
        },
    }) });
    b.installArtifact(server);
    const serve = b.addRunArtifact(server);
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve the account service on a socket: zig build serve -- [port]").dependOn(&serve.step);
}
