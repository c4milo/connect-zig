//! connect-zig's module (decision 52): the one module a program and its generated code import.
//! It names the library's modules, the type of the CPU features a program detects, and the
//! generated code of validate.proto and descriptor.proto.
//!
//! By default it also names colibri, and `connect_colibri` and `oidc` over it, so a
//! program serves and calls RPCs on colibri. A program that passes `.colibri = false` to
//! connect-zig gets the module without them: it codes and checks messages, or runs the protocol
//! on an HTTP library of its own, and links no chapulin.
const options = @import("connect_zig_options");

pub const protobuf = @import("protobuf");
pub const connect = @import("connect");
pub const protovalidate = @import("protovalidate");
/// The CPU features a program detects once, as it starts, and passes to each call that codes or
/// checks a message. stdx's type: connect-zig exports no other part of stdx.
pub const CpuFeatures = @import("stdx").platform.CpuFeatures;
pub const buf_validate_validate = @import("buf_validate_validate");
pub const google_protobuf_descriptor = @import("google_protobuf_descriptor");
pub const connect_colibri = if (options.colibri) @import("connect_colibri") else without_colibri("connect_colibri");
/// chapulin builds the `jws` calls of `oidc` for a host target alone (decision 34).
pub const oidc = if (options.oidc) @import("oidc") else @compileError("oidc needs colibri's chapulin, on an arm64 target with NEON or an x86-64 target with SSE2 (decisions 34 and 52)");
pub const colibri = if (options.colibri) @import("colibri") else without_colibri("colibri");

comptime {
    // With colibri, the module links chapulin's objects, and chapulin's module exports their hook,
    // `ch_assert_fail`, from a comptime block that Zig runs only when something references it.
    // colibri's root references it, and this reference runs colibri's root whenever a program
    // reaches this module, even a test that names no colibri type (colibri decision 172).
    if (options.colibri) _ = colibri;
}

fn without_colibri(comptime name: []const u8) noreturn {
    @compileError(name ++ " is colibri's: pass .colibri = true to connect-zig's dependency (decision 52)");
}

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "protobuf",        "connect", "protovalidate", "CpuFeatures", "buf_validate_validate", "google_protobuf_descriptor",
        "connect_colibri", "oidc",    "colibri",
    });
}

test "with colibri, each name of colibri is the module, not the refusal" {
    // Each name is evaluated here, so one that `without_colibri` gives stops the build.
    if (!options.colibri) return;
    const std = @import("std");
    try std.testing.expect(@hasDecl(connect_colibri, "Route"));
    try std.testing.expect(@hasDecl(colibri, "Server"));
    if (options.oidc) try std.testing.expect(@hasDecl(oidc, "Verifier"));
}
