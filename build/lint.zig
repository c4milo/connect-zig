//! `zig build lint` and `zig build lint-commits`, from pepegrillo, which is lazy and requested only
//! when connect-zig is the root build (docs/decisions.md entry 15).
const std = @import("std");

/// CLAUDE.md, Conventions: the cognitive-complexity threshold. Never raised.
const cognitive_complexity_max = "15";

/// The directories the complexity score and the lint rules read.
const source_directories = [_][]const u8{ "src", "tools", "build", "examples" };

/// The Markdown files at the root, which the markdown rule reads beside `docs/`.
const root_documents = [_][]const u8{ "README.md", "CLAUDE.md" };

const commit_lint_range = "origin/main..HEAD";

/// Adds the lint steps and returns `lint`, or null while pepegrillo is not fetched yet.
pub fn add(b: *std.Build) ?*std.Build.Step {
    const dependency = b.lazyDependency("pepegrillo", .{}) orelse return null;
    const pepegrillo = dependency.module("pepegrillo");

    const complexity = b.addExecutable(.{ .name = "cognitive_complexity", .root_module = tool(b, pepegrillo, "tools/cognitive_complexity.zig") });
    const complexity_run = b.addRunArtifact(complexity);
    complexity_run.addArgs(&.{ "--max", cognitive_complexity_max });
    complexity_run.addFileArg(b.path("build.zig"));
    for (source_directories) |directory| complexity_run.addDirectoryArg(b.path(directory));

    const rules = b.addExecutable(.{ .name = "lint", .root_module = tool(b, pepegrillo, "tools/lint/main.zig") });
    const rules_run = b.addRunArtifact(rules);
    rules_run.addArg("build.zig");
    for (source_directories) |directory| rules_run.addArg(directory);
    rules_run.addArg("docs");
    for (root_documents) |document| rules_run.addArg(document);
    rules_run.setCwd(b.path("."));
    rules_run.has_side_effects = true;
    rules_run.step.dependOn(&complexity_run.step);

    const tool_tests = b.addRunArtifact(b.addTest(.{ .name = "lint-rules", .root_module = tool(b, pepegrillo, "tools/lint/main.zig") }));
    const step = b.step("lint", "Score cognitive complexity, then run the lint rules");
    step.dependOn(&rules_run.step);
    step.dependOn(&tool_tests.step);

    const commits = b.addExecutable(.{ .name = "commit_lint", .root_module = tool(b, pepegrillo, "tools/commit_lint.zig") });
    const commits_run = b.addRunArtifact(commits);
    commits_run.addArgs(&.{ "--range", commit_lint_range });
    commits_run.setCwd(b.path("."));
    commits_run.has_side_effects = true;
    b.step("lint-commits", "Check the commit messages of " ++ commit_lint_range).dependOn(&commits_run.step);
    return step;
}

fn tool(b: *std.Build, pepegrillo: *std.Build.Module, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "pepegrillo", .module = pepegrillo }},
    });
}
