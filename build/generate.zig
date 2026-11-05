const std = @import("std");
pub fn add(b: *std.Build, plugin: *std.Build.Step.Compile) void {
    _ = b;
    _ = plugin;
}
pub fn add_check(b: *std.Build, plugin: *std.Build.Step.Compile) *std.Build.Step {
    _ = plugin;
    return b.step("generate-check", "Check committed generated code");
}
