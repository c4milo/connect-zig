//! The OTLP example (decision 40): OpenTelemetry's trace receiver, `TraceService/Export` of
//! opentelemetry-proto, and `SpanStore/Received`, which reads back what it kept.
//!
//! - `zig build run` exports a trace and reads it back, in memory over h2, h11 and h3; `zig build
//!   test` does the same, and fails on a wrong answer.
//! - `zig build serve -- [port]` serves the receiver on a socket, over TLS, for an OpenTelemetry
//!   SDK's exporter.
//! - `zig build plugin` installs connect-zig's plugin, and `buf generate` then writes gen/ from
//!   proto/.
//! - The package exports the generated modules and `otlp_service`, for a project that serves the
//!   receiver beside its own services.
const std = @import("std");

/// The generated modules: each module's name, its file under gen/, and the generated modules its
/// header names, by their module names there.
const generated = [_]struct { name: []const u8, path: []const u8, imports: []const [2][]const u8 }{
    .{ .name = "otlp_common", .path = "opentelemetry/proto/common/v1/common.pb.zig", .imports = &.{} },
    .{ .name = "otlp_resource", .path = "opentelemetry/proto/resource/v1/resource.pb.zig", .imports = &.{.{ "opentelemetry_proto_common_v1_common", "otlp_common" }} },
    .{ .name = "otlp_trace", .path = "opentelemetry/proto/trace/v1/trace.pb.zig", .imports = &.{ .{ "opentelemetry_proto_common_v1_common", "otlp_common" }, .{ "opentelemetry_proto_resource_v1_resource", "otlp_resource" } } },
    .{ .name = "otlp", .path = "opentelemetry/proto/collector/trace/v1/trace_service.pb.zig", .imports = &.{.{ "opentelemetry_proto_trace_v1_trace", "otlp_trace" }} },
    .{ .name = "otlpstore", .path = "otlpstore/v1/otlpstore.pb.zig", .imports = &.{.{ "opentelemetry_proto_collector_trace_v1_trace_service", "otlp" }} },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Assertions stay on, as in connect-zig: Debug, or ReleaseSafe with `-Drelease`.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const release = optimize == .ReleaseSafe;
    const connect_zig = b.dependency("connect_zig", .{ .target = target, .release = release, .rotor = true });
    const harness = b.dependency("harness", .{ .target = target, .release = release });
    const plugin = b.addInstallArtifact(connect_zig.artifact("protoc-gen-connect-zig"), .{});
    b.step("plugin", "Install connect-zig's protoc plugin to zig-out/bin").dependOn(&plugin.step);

    // Each generated module, in the order the headers need them.
    inline for (generated) |file| {
        const module = b.addModule(file.name, .{ .root_source_file = b.path("gen/" ++ file.path), .target = target, .optimize = optimize });
        module.addImport("connect_zig", connect_zig.module("connect_zig"));
        inline for (file.imports) |import| module.addImport(import[0], b.modules.get(import[1]).?);
    }
    const service = b.addModule("otlp_service", .{
        .root_source_file = b.path("src/service/service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect_zig", .module = connect_zig.module("connect_zig") },
            .{ .name = "otlp", .module = b.modules.get("otlp").? },
            .{ .name = "otlpstore", .module = b.modules.get("otlpstore").? },
        },
    });
    const check = program(b, connect_zig, harness, service, "otlp", "src/main.zig", target, optimize);
    const run = b.addRunArtifact(check);
    b.step("run", "Export a trace and read it back, in memory").dependOn(&run.step);
    b.step("test", "Run the example, which fails on a wrong answer").dependOn(&run.step);
    const server = program(b, connect_zig, harness, service, "otlp-server", "src/serve.zig", target, optimize);
    const serve = b.addRunArtifact(server);
    if (b.args) |args| serve.addArgs(args);
    b.step("serve", "Serve the receiver on a socket: zig build serve -- [port]").dependOn(&serve.step);
}

fn program(b: *std.Build, connect_zig: *std.Build.Dependency, harness: *std.Build.Dependency, service: *std.Build.Module, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
    module.addImport("connect_zig", connect_zig.module("connect_zig"));
    for ([_][]const u8{ "otlp", "otlp_trace", "otlp_common", "otlpstore" }) |import| module.addImport(import, b.modules.get(import).?);
    module.addImport("otlp_service", service);
    module.addImport("harness", harness.module("harness"));
    const exe = b.addExecutable(.{ .name = name, .root_module = module });
    b.installArtifact(exe);
    return exe;
}
