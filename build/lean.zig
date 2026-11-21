//! `zig build lean [-- write]`: pepegrillo's lake runner over the Lean model in spec/lean/, then
//! the check that the vector file the Zig tests replay is what the model gives
//! (spec/README.md). It is not part of `zig build test`: it needs lake, from a Lean
//! release, which `tools/lean_check.sh` installs.
//!
//! `zig build cel-vectors-replay` builds the program that replays a file of the model's
//! vectors against the Zig grammar. `tools/lean_check.sh` runs it over expressions that the
//! model writes from a seed.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

pub fn add(b: *std.Build, graph: Graph) void {
    add_replay(b, graph);
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

/// The replay program, over the CEL reader as a program runs it: `src/protovalidate/cel_reader.zig`
/// is the root of a module of its own, which no package exports.
fn add_replay(b: *std.Build, graph: Graph) void {
    const reader = b.createModule(.{
        .root_source_file = b.path("src/protovalidate/cel_reader.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
    });
    const exe = b.addExecutable(.{ .name = "cel-vectors-replay", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/cel_vectors/replay.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{.{ .name = "cel_reader", .module = reader }},
    }) });
    b.step("cel-vectors-replay", "Build the program that replays the Lean model's vectors against the Zig grammar").dependOn(&b.addInstallArtifact(exe, .{}).step);
}
