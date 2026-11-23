//! The server of the full-stack benchmark (design §8 step 28, decision 44): `otlp-sink`, which
//! `tools/fullstack_check.sh` loads over TLS and h2 beside OpenTelemetry's Collector.
//! `zig build otlp-sink` installs it to zig-out/bin, and `zig build run-otlp-sink -- [port]`
//! starts it.
//!
//! It reads the generated code of examples/otlp/gen, as `zig build test-generated` reads the
//! examples' code, and `count_spans` of the example's receiver. `zig build otlp-sink-validate`
//! installs `otlp-sink-validate`, the same sink over tools/fullstack/validate/gen, whose spans
//! carry OTLP's rules, which `protovalidate.Interceptor` checks before each `Export`. `zig build
//! otlp-sink-compression` installs the sink of the compression part, which holds more calls at
//! once (tools/otlp_sink/constants.zig, `requests_compression`). `zig build otlp-compress` installs the program that writes the compression part's exports in each coding,
//! and `zig build otlp-validate-cost` the program that times validation by the route's storage.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

pub fn add(b: *std.Build, graph: Graph) void {
    // The sink runs colibri's TLS, which a program defines chapulin's hook for, on Rotor: a host
    // target alone builds it, as the interop server.
    if (graph.oidc == null) return;
    const plain = sink(b, graph, "otlp-sink", "examples/otlp/gen/opentelemetry/proto/", .plain);
    b.step("otlp-sink", "Install the full-stack benchmark's OTLP server to zig-out/bin").dependOn(&b.addInstallArtifact(plain, .{}).step);
    const run = b.addRunArtifact(plain);
    if (b.args) |args| run.addArgs(args);
    b.step("run-otlp-sink", "Serve the OTLP sink on a TCP socket: zig build run-otlp-sink -- [port]").dependOn(&run.step);
    // The same sink over tools/fullstack/validate's schema, whose spans carry OTLP's rules, with
    // `protovalidate.Interceptor` around `Export`.
    const validating = sink(b, graph, "otlp-sink-validate", "tools/fullstack/validate/gen/opentelemetry/proto/", .validate);
    b.step("otlp-sink-validate", "Install the OTLP sink that validates each export to zig-out/bin").dependOn(&b.addInstallArtifact(validating, .{}).step);
    // The same sink with room for more calls at once, for the compression part.
    const for_compression = sink(b, graph, "otlp-sink-compression", "examples/otlp/gen/opentelemetry/proto/", .compression);
    b.step("otlp-sink-compression", "Install the OTLP sink of the compression part, with room for more calls at once, to zig-out/bin").dependOn(&b.addInstallArtifact(for_compression, .{}).step);
    const compress = b.addExecutable(.{ .name = "otlp-compress", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/otlp_compress/main.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{.{ .name = "connect", .module = graph.connect }},
    }) });
    b.step("otlp-compress", "Install the program that compresses the full-stack check's exports to zig-out/bin").dependOn(&b.addInstallArtifact(compress, .{}).step);
    const gen = "tools/fullstack/validate/gen/opentelemetry/proto/";
    const common = generated(b, graph, gen ++ "common/v1/common.pb.zig", &.{});
    const resource = generated(b, graph, gen ++ "resource/v1/resource.pb.zig", &.{.{ .name = "opentelemetry_proto_common_v1_common", .module = common }});
    const trace = generated(b, graph, gen ++ "trace/v1/trace.pb.zig", &.{
        .{ .name = "opentelemetry_proto_common_v1_common", .module = common },
        .{ .name = "opentelemetry_proto_resource_v1_resource", .module = resource },
    });
    const otlp = generated(b, graph, gen ++ "collector/trace/v1/trace_service.pb.zig", &.{.{ .name = "opentelemetry_proto_trace_v1_trace", .module = trace }});
    const cost = b.addExecutable(.{ .name = "otlp-validate-cost", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/otlp_sink/validate_cost.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "protovalidate", .module = graph.protovalidate },
            .{ .name = "otlp", .module = otlp },
        },
    }) });
    b.step("otlp-validate-cost", "Install the profile of validation in the OTLP sink").dependOn(&b.addInstallArtifact(cost, .{}).step);
}

/// Each sink the build installs: the plain one, the one that validates each export, and the one
/// of the compression part, which holds more calls at once (tools/otlp_sink/constants.zig).
const Kind = enum { plain, validate, compression };

/// The sink of `kind` over the generated code of `gen`.
fn sink(b: *std.Build, graph: Graph, name: []const u8, comptime gen: []const u8, kind: Kind) *std.Build.Step.Compile {
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
    const options = b.addOptions();
    options.addOption(bool, "validate", kind == .validate);
    options.addOption(bool, "compression", kind == .compression);
    return b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path("tools/otlp_sink/main.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "connect", .module = graph.connect },
            .{ .name = "connect_colibri", .module = graph.connect_colibri },
            .{ .name = "protovalidate", .module = graph.protovalidate },
            .{ .name = "server", .module = graph.colibri.module("server") },
            .{ .name = "colibri", .module = graph.colibri.module("colibri") },
            .{ .name = "tls", .module = graph.colibri.module("tls") },
            .{ .name = "platform", .module = graph.platform },
            .{ .name = "test_identity", .module = b.createModule(.{ .root_source_file = b.path("examples/harness/tls/identity.zig"), .target = graph.target, .optimize = graph.optimize }) },
            .{ .name = "hooks", .module = b.createModule(.{ .root_source_file = b.path("examples/harness/src/hooks.zig"), .target = graph.target, .optimize = graph.optimize }) },
            .{ .name = "otlp", .module = otlp },
            .{ .name = "otlp_service", .module = service },
            .{ .name = "sink_options", .module = options.createModule() },
        },
    }) });
}

/// A generated module, with the modules its header names.
fn generated(b: *std.Build, graph: Graph, path: []const u8, imports: []const std.Build.Module.Import) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path(path), .target = graph.target, .optimize = graph.optimize });
    module.addImport("protobuf", graph.protobuf);
    module.addImport("connect", graph.connect);
    // The validated schema's code names `protovalidate`, and OpenTelemetry's names none.
    module.addImport("protovalidate", graph.protovalidate);
    for (imports) |import| module.addImport(import.name, import.module);
    return module;
}
