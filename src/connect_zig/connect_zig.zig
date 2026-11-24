//! connect-zig's module for a program that serves or calls RPCs (decision 52). It names each
//! library module, the colibri modules a program builds on, stdx's `platform`, and the generated
//! code of validate.proto and descriptor.proto. A program adds this one module, and its
//! generated code that declares a service or a rule imports it too.
//!
//! A program that codes messages alone imports `protobuf` instead: this module reaches colibri's
//! `tls`, so a program that imports it links chapulin and defines `ch_assert_fail`.
const options = @import("connect_zig_options");

pub const protobuf = @import("protobuf");
pub const connect = @import("connect");
pub const connect_colibri = @import("connect_colibri");
pub const protovalidate = @import("protovalidate");
/// chapulin builds the `jws` calls of `oidc` for a host target alone (decision 34).
pub const oidc = if (options.oidc) @import("oidc") else @compileError("oidc needs an arm64 target with NEON or an x86-64 target with SSE2 (decision 34)");
pub const server = @import("server");
pub const client = @import("client");
pub const http = @import("http");
pub const tls = @import("tls");
pub const colibri = @import("colibri");
pub const platform = @import("platform");
pub const buf_validate_validate = @import("buf_validate_validate");
pub const google_protobuf_descriptor = @import("google_protobuf_descriptor");

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "protobuf",                   "connect", "connect_colibri", "protovalidate", "oidc",     "server",
        "client",                     "http",    "tls",             "colibri",       "platform", "buf_validate_validate",
        "google_protobuf_descriptor",
    });
}

test {
    // `connect_colibri` defines chapulin's hook in a test binary, and this module's links chapulin.
    _ = connect_colibri;
}
