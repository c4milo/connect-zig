//! The README's "Use it in your project", as a project (decision 41): GreetService, a server on
//! `colibri.Server` and a client on `colibri.Client`, both on Rotor and over TLS.
//!
//! - `zig build plugin` installs connect-zig's plugin; `buf generate` then writes gen/ from
//!   proto/; `zig build` builds `greet-server` and `greet-client`.
//! - `zig build test` runs `check.sh`, which starts the server and calls it over h11, h2 and h3.
//!   `-Didentity=<dir>` names the folder of chain.pem, key.pem and ca.pem it serves and trusts:
//!   the examples' test identity by default (decision 25).
//!
//! `tools/package_check.sh` builds this project against a fetched copy of connect-zig.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const identity = b.option([]const u8, "identity", "The folder of chain.pem, key.pem and ca.pem that `zig build test` uses") orelse "../harness/tls";
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = optimize == .ReleaseSafe, .rotor = true });
    // connect-zig asks for stdx with these three options, so Zig gives both requests one package:
    // the client's TLS value holds stdx's `crypto.Context` (colibri decision 175).
    const stdx = b.dependency("stdx", .{ .target = target, .release = optimize == .ReleaseSafe, .crypto = true });
    // The plugin alone, which `buf generate` runs before the programs can build.
    const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
    b.step("plugin", "Install connect-zig's protoc plugin to zig-out/bin").dependOn(&plugin.step);

    const greet = b.createModule(.{ .root_source_file = b.path("gen/greet/v1/greet.pb.zig"), .target = target, .optimize = optimize });
    greet.addImport("connect_zig", connect_zig.module("connect_zig"));
    const server = program(b, connect_zig, greet, "greet-server", "src/server.zig", target, optimize);
    const client = program(b, connect_zig, greet, "greet-client", "src/client.zig", target, optimize);
    client.root_module.addImport("stdx", stdx.module("stdx"));
    const check = b.addSystemCommand(&.{"sh"});
    check.addFileArg(b.path("check.sh"));
    check.addArtifactArg(server);
    check.addArtifactArg(client);
    check.addArg(identity);
    b.step("test", "Start the server and call it over h11, h2 and h3").dependOn(&check.step);
}

fn program(b: *std.Build, connect_zig: *std.Build.Dependency, greet: *std.Build.Module, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
    // One module names the library's, colibri's and stdx's `platform` (decision 52).
    module.addImport("connect_zig", connect_zig.module("connect_zig"));
    module.addImport("greet_v1", greet);
    const exe = b.addExecutable(.{ .name = name, .root_module = module });
    b.installArtifact(exe);
    return exe;
}
