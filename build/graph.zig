//! The modules and options of the build that build/ helpers share.
const std = @import("std");

pub const Graph = struct {
    protobuf: *std.Build.Module,
    connect: *std.Build.Module,
    connect_colibri: *std.Build.Module,
    public_names: *std.Build.Module,
    colibri: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};
