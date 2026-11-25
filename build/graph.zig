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
    /// The module `connect_zig` without colibri, which the build's own generated code imports,
    /// so a check that serves no RPC links no chapulin (decision 52).
    connect_zig_core: *std.Build.Module,
    public_names: *std.Build.Module,
    colibri: *std.Build.Dependency,
    /// stdx's one module, whose `platform` probes the CPU for a program's TLS values (colibri
    /// decision 97). It is the instance colibri builds on, so a program holds one copy of stdx.
    stdx: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};
