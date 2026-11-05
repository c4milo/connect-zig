const std = @import("std");
pub fn add(b: *std.Build, graph: anytype) *std.Build.Step {
    _ = graph;
    return b.step("examples", "Build and run every example");
}
