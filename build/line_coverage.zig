//! `zig build line-coverage`: each library module's tests, built in Debug with LLVM, whose line
//! table kcov reads in full, and run under kcov by pepegrillo's `coverage` tool
//! (tools/line_coverage/main.zig). kcov runs on Linux; `tools/line_coverage_check.sh` runs the
//! step there, in a container when the host has no kcov 43.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

pub fn add(b: *std.Build, graph: Graph, plugin: *std.Build.Step.Compile) void {
    const dependency = b.lazyDependency("pepegrillo", .{}) orelse return;
    const tool = b.addExecutable(.{ .name = "line_coverage", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/line_coverage/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "pepegrillo", .module = dependency.module("pepegrillo") }},
    }) });
    const check = b.addRunArtifact(tool);
    // Zig's own x86-64 backend writes an incomplete line table, so each binary uses LLVM.
    const modules = [_]?*std.Build.Module{ graph.protobuf, graph.connect, graph.connect_colibri, graph.oidc, graph.protovalidate, plugin.root_module, graph.public_names };
    for (modules) |each| {
        const module = each orelse continue;
        check.addArtifactArg(b.addTest(.{ .root_module = module, .use_llvm = true }));
    }
    check.setCwd(b.path("."));
    check.has_side_effects = true;
    b.step("line-coverage", "Count the lines of each module that its tests run, under kcov (Linux)").dependOn(&check.step);
}
