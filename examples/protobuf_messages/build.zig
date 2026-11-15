//! The protobuf_messages example (decision 41): generated messages through the binary encoding
//! and proto3 JSON, with no RPC at all.
//!
//! - `zig build run` runs the program; `zig build test` does the same, fails on a wrong value,
//!   and compiles the generated code of large.proto, which no program reads.
//! - `zig build plugin` installs connect-zig's plugin, and `buf generate` then writes gen/ from
//!   proto/.
//! - The package exports `kitchen`, `kitchen_v1_shared` and `large`, the generated code, for a
//!   project that reads these messages. A generated file reaches another by the module name its
//!   header states: kitchen.proto and large.proto import shared.proto as `kitchen_v1_shared`.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = optimize == .ReleaseSafe });
    const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
    b.step("plugin", "Install connect-zig's protoc plugin to zig-out/bin").dependOn(&plugin.step);

    const protobuf = connect_zig.module("protobuf");
    const connect = connect_zig.module("connect");
    const shared = b.addModule("kitchen_v1_shared", .{
        .root_source_file = b.path("gen/kitchen/v1/shared.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
        },
    });
    const kitchen = b.addModule("kitchen", .{
        .root_source_file = b.path("gen/kitchen/v1/kitchen.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "connect", .module = connect },
            .{ .name = "kitchen_v1_shared", .module = shared },
        },
    });
    const large = b.addModule("large", .{
        .root_source_file = b.path("gen/large/v1/large.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "connect", .module = connect },
            .{ .name = "kitchen_v1_shared", .module = shared },
        },
    });
    const exe = b.addExecutable(.{ .name = "protobuf_messages", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "kitchen", .module = kitchen },
        },
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Encode and decode generated messages in binary and JSON").dependOn(&run.step);

    const generated = b.addTest(.{ .name = "generated", .root_module = b.createModule(.{
        .root_source_file = b.path("src/generated_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kitchen", .module = kitchen },
            .{ .name = "kitchen_v1_shared", .module = shared },
            .{ .name = "large", .module = large },
        },
    }) });
    const test_step = b.step("test", "Run the example, which fails on a wrong value, and compile the generated code");
    test_step.dependOn(&run.step);
    test_step.dependOn(&b.addRunArtifact(generated).step);
}
