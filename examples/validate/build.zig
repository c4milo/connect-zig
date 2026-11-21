//! The validate example (decision 41): signup.v1.SignupService behind `protovalidate.Interceptor`,
//! which checks each request message against the rules of its schema, and a client that calls
//! it in memory over h2, h11 and h3.
//!
//! - `zig build run` runs the client against the service; `zig build test` does the same, and
//!   fails on a wrong answer.
//! - `zig build serve -- [port]` serves the service on a socket, over TLS, for curl and buf curl.
//! - `zig build plugin` installs connect-zig's plugin, and `buf generate` then writes gen/ from
//!   proto/.
//! - The package exports `signup`, the generated code, and `signup_service`, the handlers and
//!   their interceptor, for a project that serves the service beside its own.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const release = optimize == .ReleaseSafe;
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = true });
    const harness = b.dependency("harness", .{ .target = target, .release = release });
    const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
    b.step("plugin", "Install connect-zig's protoc plugin to zig-out/bin").dependOn(&plugin.step);

    // A generated file that holds rules names `protovalidate` in its header, beside `protobuf`
    // and `connect`.
    const signup = b.addModule("signup", .{
        .root_source_file = b.path("gen/signup/v1/signup.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "protovalidate", .module = connect_zig.module("protovalidate") },
        },
    });
    const service = b.addModule("signup_service", .{
        .root_source_file = b.path("src/service/service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect_zig.module("connect") },
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "protovalidate", .module = connect_zig.module("protovalidate") },
            .{ .name = "signup", .module = signup },
        },
    });
    const exe = b.addExecutable(.{
        .name = "validate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protobuf", .module = connect_zig.module("protobuf") },
                .{ .name = "connect", .module = connect_zig.module("connect") },
                .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
                .{ .name = "server", .module = connect_zig.module("server") },
                .{ .name = "client", .module = connect_zig.module("client") },
                // The generated code of validate.proto: the client reads an error's
                // `buf.validate.Violations` with it.
                .{ .name = "buf_validate_validate", .module = connect_zig.module("buf_validate_validate") },
                .{ .name = "harness", .module = harness.module("harness") },
                .{ .name = "signup", .module = signup },
                .{ .name = "signup_service", .module = service },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the client against the signup service").dependOn(&run.step);
    b.step("test", "Run the example, which fails on a wrong answer").dependOn(&run.step);

    // The same routes on a socket, to play with.
    const server = b.addExecutable(.{ .name = "validate-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_colibri", .module = connect_zig.module("connect_colibri") },
            .{ .name = "server", .module = connect_zig.module("server") },
            .{ .name = "harness", .module = harness.module("harness") },
            .{ .name = "signup", .module = signup },
            .{ .name = "signup_service", .module = service },
        },
    }) });
    b.installArtifact(server);
    const serve = b.addRunArtifact(server);
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve the signup service on a socket: zig build serve -- [port]").dependOn(&serve.step);
}
