//! `zig build lean [-- write]`: pepegrillo's lake runner over the Lean model in spec/lean/, then
//! the check that the vector file the Zig tests replay is what the model gives
//! (spec/README.md). It is not part of `zig build test`: it needs lake, from a Lean
//! release, which `tools/lean_check.sh` installs.
const std = @import("std");

pub fn add(b: *std.Build) void {
    const dependency = b.lazyDependency("pepegrillo", .{}) orelse return;
    const program = b.addExecutable(.{ .name = "lean", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/lean.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "pepegrillo", .module = dependency.module("pepegrillo") }},
    }) });
    const run = b.addRunArtifact(program);
    if (b.args) |arguments| run.addArgs(arguments);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    b.step("lean", "Build the Lean model in spec/lean/ and check the vectors it gives").dependOn(&run.step);
}
