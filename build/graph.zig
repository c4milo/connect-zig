//! The modules and options of the build that build/ helpers share.
const std = @import("std");

pub const Graph = struct {
    protobuf: *std.Build.Module,
    connect: *std.Build.Module,
    connect_colibri: *std.Build.Module,
    /// Null off a host target, where chapulin builds no `jws` calls (decision 34).
    oidc: ?*std.Build.Module,
    /// The check of a message against its schema's rules (decision 47). Its generated modules
    /// are its imports `buf_validate_validate` and `google_protobuf_descriptor`.
    protovalidate: *std.Build.Module,
    /// The one module a program that serves or calls RPCs adds (decision 52).
    connect_zig: *std.Build.Module,
    /// What the build's own generated code takes as `connect_zig`: the modules generated code
    /// names, with no colibri, so a check that serves no RPC links no chapulin (decision 52).
    generated_imports: *std.Build.Module,
    public_names: *std.Build.Module,
    colibri: *std.Build.Dependency,
    /// stdx's CPU probe, which a program's TLS values take (colibri decision 97).
    platform: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};
