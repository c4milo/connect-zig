//! The sans_io_call example (decision 41): two calls of the ELIZA service through the `connect`
//! module alone, with no network and no HTTP library.
//!
//! - `zig build run` runs the program; `zig build test` does the same, and fails on a wrong
//!   answer.
//! - The ELIZA schema belongs to the eliza example. This project depends on that project by path
//!   and imports its module `eliza`, the generated code.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const release = optimize == .ReleaseSafe;
    // The program needs no Rotor. The eliza project asks for connect-zig with these three options,
    // so Zig gives both requests one package, and `connect` is one module (decision 41).
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = true });
    const eliza = b.dependency("eliza", .{ .target = target, .release = release });
    // With connect-zig's options, so its `platform` is the module connect-zig imports.
    const stdx = b.dependency("stdx", .{ .target = target, .release = release });
    const exe = b.addExecutable(.{ .name = "sans_io_call", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform", .module = stdx.module("platform") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "eliza", .module = eliza.module("eliza") },
        },
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run Connect and gRPC-Web calls through the connect module alone").dependOn(&run.step);
    b.step("test", "Run the example, which fails on a wrong answer").dependOn(&run.step);
}
