//! The ELIZA example (decision 41): connectrpc.eliza.v1.ElizaService, and a client that calls it
//! in memory over h11, h2 and h3.
//!
//! - `zig build run` runs the client against the service; `zig build test` does the same, and
//!   fails on a wrong answer.
//! - `zig build serve -- [port]` serves ELIZA on a socket, over TLS, for curl and buf curl.
//! - `zig build plugin` installs connect-zig's plugin, and `buf generate` then writes gen/ from
//!   proto/.
//! - The package exports `eliza`, the generated code, and `eliza_service`, the handlers, for a
//!   project that serves ELIZA beside its own services.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const release = optimize == .ReleaseSafe;
    // A project with no Rotor that serves ELIZA (decision 32) passes `.rotor = false`, so that
    // this project's connect-zig is its own.
    const rotor = b.option(bool, "rotor", "Build on Rotor, which the in-memory rounds and `serve` need") orelse true;
    // A project that codes ELIZA's messages with no colibri, such as `sans_io_call`, passes
    // `.colibri = false` (decision 52), so the `eliza` module takes its connect-zig.
    const with_colibri = b.option(bool, "colibri", "Build connect-zig with colibri, which the rounds and `serve` need") orelse true;
    // Zig keys a dependency by the options a request names, so the option is named only when it
    // is false: a project that names none gets this request's package.
    const connect_zig = if (with_colibri)
        b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = rotor })
    else
        b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = rotor, .colibri = false });
    const harness = b.dependency("harness", .{ .target = target, .release = release, .rotor = rotor });
    const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
    b.step("plugin", "Install connect-zig's protoc plugin to zig-out/bin").dependOn(&plugin.step);

    const eliza = b.addModule("eliza", .{
        .root_source_file = b.path("gen/connectrpc/eliza/v1/eliza.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_zig", .module = connect_zig.module("connect_zig") },
        },
    });
    const service = b.addModule("eliza_service", .{
        .root_source_file = b.path("src/service/service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_zig", .module = connect_zig.module("connect_zig") },
            .{ .name = "eliza", .module = eliza },
        },
    });
    const exe = b.addExecutable(.{ .name = "eliza", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_zig", .module = connect_zig.module("connect_zig") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "eliza", .module = eliza },
            .{ .name = "eliza_service", .module = service },
        },
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the client against the ELIZA service").dependOn(&run.step);
    b.step("test", "Run the example, which fails on a wrong answer").dependOn(&run.step);

    // The same routes on a socket, to play with.
    const server = b.addExecutable(.{ .name = "eliza-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_zig", .module = connect_zig.module("connect_zig") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "eliza", .module = eliza },
            .{ .name = "eliza_service", .module = service },
        },
    }) });
    b.installArtifact(server);
    const serve = b.addRunArtifact(server);
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve ELIZA on a socket: zig build serve -- [port]").dependOn(&serve.step);
}
