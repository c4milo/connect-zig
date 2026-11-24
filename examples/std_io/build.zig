//! The std.Io example (decisions 32 and 41): the ELIZA service on colibri's `server.Engine`, and
//! a client on `client.ConnectionPool`, each driven over Zig 0.16's `std.Io`, with no Rotor.
//!
//! - `zig build serve -- [port]` serves ELIZA on a TCP socket, in cleartext over h11 and h2.
//! - `zig build run` starts that server on port 0 and calls it over TCP; `zig build test` does
//!   the same, and fails on a wrong answer.
//!
//! The project serves the service of the eliza project, and takes chapulin's hook from the
//! harness.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const release = optimize == .ReleaseSafe;
    // No Rotor: neither program runs on it (decision 32). The eliza project and the harness take
    // the same `.rotor = false`, so the build holds one connect-zig.
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = false });
    const eliza_project = b.dependency("eliza", .{ .target = target, .release = release, .rotor = false });
    const harness = b.dependency("harness", .{ .target = target, .release = release, .rotor = false });
    // With connect-zig's options, so its `platform` is the module connect-zig imports.
    const stdx = b.dependency("stdx", .{ .target = target, .release = release });
    const eliza = eliza_project.module("eliza");
    const eliza_service = eliza_project.module("eliza_service");
    // chapulin's hook alone: the `harness` module runs on Rotor.
    const hooks = harness.module("hooks");

    const server = b.addExecutable(.{ .name = "std-io-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/server/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "hooks", .module = hooks },
            .{ .name = "eliza", .module = eliza },
            .{ .name = "eliza_service", .module = eliza_service },
        },
    }) });
    b.installArtifact(server);
    const serve = b.addRunArtifact(server);
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve ELIZA over std.Io: zig build serve -- [port]").dependOn(&serve.step);

    const check = b.addExecutable(.{ .name = "std_io", .root_module = b.createModule(.{
        .root_source_file = b.path("src/client/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "client", .module = connect_zig.module("client") },
            .{ .name = "hooks", .module = hooks },
            .{ .name = "eliza", .module = eliza },
            .{ .name = "eliza_service", .module = eliza_service },
        },
    }) });
    // The self-check starts the server binary it is given.
    const run = b.addRunArtifact(check);
    run.addArtifactArg(server);
    b.step("run", "Call the std.Io server over TCP, with no Rotor").dependOn(&run.step);
    b.step("test", "Run the self-check, which fails on a wrong answer").dependOn(&run.step);
}
