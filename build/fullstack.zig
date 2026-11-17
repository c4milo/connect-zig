//! The server of the full-stack benchmark (design §8 step 28, decision 44): `otlp-sink`, which
//! `tools/fullstack_check.sh` loads over TLS and h2 beside OpenTelemetry's Collector.
//! `zig build otlp-sink` installs it to zig-out/bin, and `zig build run-otlp-sink -- [port]`
//! starts it.
//!
//! It reads the generated code of examples/otlp/gen, as `zig build test-generated` reads the
//! examples' code, and `count_spans` of the example's receiver.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

pub fn add(b: *std.Build, graph: Graph) void {
    // The sink runs colibri's TLS, which a program defines chapulin's hook for, on Rotor: a host
    // target alone builds it, as the interop server.
    if (graph.oidc == null) return;
    const gen = "examples/otlp/gen/opentelemetry/proto/";
    const common = generated(b, graph, gen ++ "common/v1/common.pb.zig", &.{});
    const resource = generated(b, graph, gen ++ "resource/v1/resource.pb.zig", &.{.{ .name = "opentelemetry_proto_common_v1_common", .module = common }});
    const trace = generated(b, graph, gen ++ "trace/v1/trace.pb.zig", &.{
        .{ .name = "opentelemetry_proto_common_v1_common", .module = common },
        .{ .name = "opentelemetry_proto_resource_v1_resource", .module = resource },
    });
    const otlp = generated(b, graph, gen ++ "collector/trace/v1/trace_service.pb.zig", &.{.{ .name = "opentelemetry_proto_trace_v1_trace", .module = trace }});
    const otlpstore = generated(b, graph, "examples/otlp/gen/otlpstore/v1/otlpstore.pb.zig", &.{.{ .name = "opentelemetry_proto_collector_trace_v1_trace_service", .module = otlp }});
    const service = b.createModule(.{
        .root_source_file = b.path("examples/otlp/src/service/service.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "connect", .module = graph.connect },
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "connect_colibri", .module = graph.connect_colibri },
            .{ .name = "otlp", .module = otlp },
            .{ .name = "otlpstore", .module = otlpstore },
        },
    });
    const exe = b.addExecutable(.{ .name = "otlp-sink", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/otlp_sink/main.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "connect", .module = graph.connect },
            .{ .name = "connect_colibri", .module = graph.connect_colibri },
            .{ .name = "server", .module = graph.colibri.module("server") },
            .{ .name = "colibri", .module = graph.colibri.module("colibri") },
            .{ .name = "tls", .module = graph.colibri.module("tls") },
            .{ .name = "platform", .module = graph.platform },
            .{ .name = "test_identity", .module = b.createModule(.{ .root_source_file = b.path("examples/harness/tls/identity.zig"), .target = graph.target, .optimize = graph.optimize }) },
            .{ .name = "hooks", .module = b.createModule(.{ .root_source_file = b.path("examples/harness/src/hooks.zig"), .target = graph.target, .optimize = graph.optimize }) },
            .{ .name = "otlp", .module = otlp },
            .{ .name = "otlp_service", .module = service },
        },
    }) });
    const install = b.addInstallArtifact(exe, .{});
    b.step("otlp-sink", "Install the full-stack benchmark's OTLP server to zig-out/bin").dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run-otlp-sink", "Serve the OTLP sink on a TCP socket: zig build run-otlp-sink -- [port]").dependOn(&run.step);
}

/// A generated module, with the modules its header names.
fn generated(b: *std.Build, graph: Graph, path: []const u8, imports: []const std.Build.Module.Import) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path(path), .target = graph.target, .optimize = graph.optimize });
    module.addImport("protobuf", graph.protobuf);
    module.addImport("connect", graph.connect);
    for (imports) |import| module.addImport(import.name, import.module);
    return module;
}
