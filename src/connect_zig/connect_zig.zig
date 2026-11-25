//! connect-zig's module (decision 52): the one module a program and its generated code import.
//! It names the library's modules, stdx's `platform`, and the generated code of validate.proto
//! and descriptor.proto.
//!
//! By default it also names colibri's modules, and `connect_colibri` and `oidc` over them, so a
//! program serves and calls RPCs on colibri. A program that passes `.colibri = false` to
//! connect-zig gets the module without them: it codes and checks messages, or runs the protocol
//! on an HTTP library of its own, and links no chapulin.
const options = @import("connect_zig_options");

pub const protobuf = @import("protobuf");
pub const connect = @import("connect");
pub const protovalidate = @import("protovalidate");
pub const platform = @import("platform");
pub const buf_validate_validate = @import("buf_validate_validate");
pub const google_protobuf_descriptor = @import("google_protobuf_descriptor");
pub const connect_colibri = if (options.colibri) @import("connect_colibri") else without_colibri("connect_colibri");
/// chapulin builds the `jws` calls of `oidc` for a host target alone (decision 34).
pub const oidc = if (options.oidc) @import("oidc") else @compileError("oidc needs colibri's chapulin, on an arm64 target with NEON or an x86-64 target with SSE2 (decisions 34 and 52)");
pub const server = if (options.colibri) @import("colibri").server else without_colibri("server");
pub const client = if (options.colibri) @import("colibri").client else without_colibri("client");
pub const http = if (options.colibri) @import("colibri").http else without_colibri("http");
pub const tls = if (options.colibri) @import("colibri").tls else without_colibri("tls");
pub const colibri = if (options.colibri) @import("colibri") else without_colibri("colibri");

fn without_colibri(comptime name: []const u8) noreturn {
    @compileError(name ++ " is colibri's: pass .colibri = true to connect-zig's dependency (decision 52)");
}

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "protobuf",        "connect", "protovalidate", "platform", "buf_validate_validate", "google_protobuf_descriptor",
        "connect_colibri", "oidc",    "server",        "client",   "http",                  "tls",
        "colibri",
    });
}

test "with colibri, each name of colibri is the module, not the refusal" {
    // Each name is evaluated here, so one that `without_colibri` gives stops the build. The
    // `connect_colibri` file also defines chapulin's hook in a test binary.
    if (!options.colibri) return;
    const std = @import("std");
    try std.testing.expect(@hasDecl(connect_colibri, "Route"));
    try std.testing.expect(@hasDecl(server, "Router"));
    try std.testing.expect(@hasDecl(client, "ConnectionPool"));
    try std.testing.expect(@hasDecl(http, "Field"));
    try std.testing.expect(@hasDecl(tls, "Cpu"));
    try std.testing.expect(@hasDecl(colibri, "Server"));
    // `oidc` defines the hook too, so this test leaves it to the oidc example.
}
