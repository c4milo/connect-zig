//! The examples' harness (decision 41): a package, not an example. It exports `harness`, the
//! in-memory rounds and the server of `zig build serve`, and `test_identity`, the test-only TLS
//! identity (decision 25). Each example
//! that runs in memory depends on it by path. `zig build test` runs its tests.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    // A project with no Rotor (decision 32) passes `.rotor = false`, and takes `hooks` alone: the
    // `harness` module runs on Rotor. Each project passes connect-zig the same options as the
    // projects it depends on, or Zig builds a second connect-zig.
    const rotor_wanted = b.option(bool, "rotor", "Build on Rotor, which the in-memory rounds and `serve` need") orelse true;
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = optimize == .ReleaseSafe, .rotor = rotor_wanted });
    // colibri asks for Rotor with these two options, so Zig gives both requests one package.
    const rotor = b.dependency("rotor", .{ .target = target, .release = optimize == .ReleaseSafe });
    const identity = b.addModule("test_identity", .{
        .root_source_file = b.path("tls/identity.zig"),
        .target = target,
        .optimize = optimize,
    });
    const harness = b.addModule("harness", .{
        .root_source_file = b.path("src/harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "client", .module = connect_zig.module("client") },
            .{ .name = "tls", .module = connect_zig.module("tls") },
            .{ .name = "colibri", .module = connect_zig.module("colibri") },
            .{ .name = "rotor", .module = rotor.module("rotor") },
            .{ .name = "test_identity", .module = identity },
        },
    });
    // chapulin's hook alone, for a program with no Rotor.
    _ = b.addModule("hooks", .{ .root_source_file = b.path("src/hooks.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = harness });
    b.step("test", "Run the harness's tests").dependOn(&b.addRunArtifact(tests).step);
}
