//! `zig build test-generated`: compiles the code `buf generate` wrote into examples/gen and runs
//! its round trips. `tools/generate_check.sh` compares that code with what buf writes now, which
//! needs buf, so it runs from `tools/ci.sh` and not from `zig build test` (design §8 step 6).
const std = @import("std");

pub fn add(b: *std.Build, protobuf: *std.Build.Module, connect: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    // A generated file reaches another by the module name its header states (design §8 step 6):
    // kitchen.proto and large.proto import shared.proto as `kitchen_v1_shared`.
    const shared = b.createModule(.{
        .root_source_file = b.path("examples/gen/kitchen/v1/shared.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf }},
    });
    const module = b.createModule(.{
        .root_source_file = b.path("examples/generated_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "connect", .module = connect },
            .{ .name = "kitchen_v1_shared", .module = shared },
        },
    });
    const run = b.addRunArtifact(b.addTest(.{ .name = "generated", .root_module = module }));
    const step = b.step("test-generated", "Compile the generated code of examples/gen and run its round trips");
    step.dependOn(&run.step);
    return step;
}
