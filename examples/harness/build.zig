//! The examples' harness (decision 41): a package, not an example. It exports `harness`, the
//! in-memory rounds and the server of `zig build serve`, and `test_identity`, the test-only TLS
//! identity (decision 25). Each example
//! that runs in memory depends on it by path. `zig build test` runs its tests.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    // A project with no Rotor (decision 32) passes `.rotor = false`, and takes no module of the
    // harness, which runs on Rotor. Each project passes connect-zig the same options as the
    // projects it depends on, or Zig builds a second connect-zig.
    const rotor_wanted = b.option(bool, "rotor", "Build on Rotor, which the in-memory rounds and `serve` need") orelse true;
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = optimize == .ReleaseSafe, .rotor = rotor_wanted });
    // colibri asks for Rotor with these two options, so Zig gives both requests one package.
    const rotor = b.dependency("rotor", .{ .target = target, .release = optimize == .ReleaseSafe });
    // connect-zig asks stdx with these options when it builds colibri, so Zig gives both requests
    // one stdx, and the program links one chapulin (connect-zig decision 34).
    const stdx = b.dependency("stdx", .{ .target = target, .release = optimize == .ReleaseSafe, .crypto = true });
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
            .{ .name = "connect_zig", .module = connect_zig.module("connect_zig") },
            .{ .name = "rotor", .module = rotor.module("rotor") },
            .{ .name = "stdx", .module = stdx.module("stdx") },
            .{ .name = "test_identity", .module = identity },
        },
    });
    const tests = b.addTest(.{ .root_module = harness });
    b.step("test", "Run the harness's tests").dependOn(&b.addRunArtifact(tests).step);
}
