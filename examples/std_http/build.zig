//! The std_http example (decision 52): ELIZA's service on Zig's `std.http.Server`, called with
//! `std.http.Client`, over HTTP/1.1 on a loopback socket. connect-zig runs the protocol and
//! colibri runs nothing: the program asks for connect-zig with `.colibri = false`, so it links no
//! chapulin.
//!
//! - `zig build run` starts the server, makes three calls with the client, and checks each
//!   answer; `zig build test` does the same, and fails on a wrong answer.
//! - `zig build serve -- [port]` serves ELIZA's `Say` and `Introduce`, for curl and buf curl.
//! - HTTP/1.1 carries no trailers that `std.http` reads, so the program speaks Connect and
//!   gRPC-Web, which carry the status in the body, and not gRPC.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const release = optimize == .ReleaseSafe;
    // The eliza project asks for connect-zig with these options, so Zig gives both requests one
    // package (decision 41).
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = true, .colibri = false });
    const eliza = b.dependency("eliza", .{ .target = target, .release = release, .colibri = false });
    const exe = b.addExecutable(.{ .name = "std_http", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_zig", .module = connect_zig.module("connect_zig") },
            .{ .name = "eliza", .module = eliza.module("eliza") },
        },
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Serve ELIZA on std.http and call it with std.http.Client").dependOn(&run.step);
    b.step("test", "Run the example, which fails on a wrong answer").dependOn(&run.step);
    const serve = b.addRunArtifact(exe);
    serve.addArg("serve");
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve ELIZA on std.http: zig build serve -- [port]").dependOn(&serve.step);
}
