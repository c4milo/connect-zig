//! The programs of the three checks that write a schema or cases as they run (decision 47):
//!
//! - `zig build compile-time-subject -Dcompile-time=<folder>` builds the program whose build
//!   `tools/compile_time_check.sh` times: it validates one message of the schema's rules.
//! - `zig build cel-differential-runner -Dcel-differential=<folder>` builds the program that
//!   `tools/cel_differential_check.sh` runs beside protovalidate-go.
//! - `zig build cel-conformance-runner -Dcel-conformance=<folder>` builds the program that
//!   `tools/cel_conformance_check.sh` runs over cel-spec's conformance suite.
//!
//! Each check writes its schema's generated code, or its cases, into its folder, so a step
//! exists only in a build that names the folder.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

pub fn add(b: *std.Build, graph: Graph) void {
    const nonce = b.option(u64, "nonce", "A number that differs for each timed build, so that none is read from the cache") orelse 0;
    if (b.option([]const u8, "compile-time", "The folder tools/compile_time_check.sh wrote its schema's code into")) |folder| {
        const options = b.addOptions();
        options.addOption(u64, "nonce", nonce);
        const exe = program(b, graph, "compile-time-subject", "tools/compile_time/subject.zig", b.pathJoin(&.{ folder, "gen/timed/v1/timed.pb.zig" }));
        exe.root_module.addImport("options", options.createModule());
        b.step("compile-time-subject", "Build the program whose build tools/compile_time_check.sh times").dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    if (b.option([]const u8, "cel-differential", "The folder tools/cel_differential_check.sh wrote its schema's code into")) |folder| {
        const exe = program(b, graph, "cel-differential-runner", "tools/cel_differential/runner.zig", b.pathJoin(&.{ folder, "gen/diff/v1/diff.pb.zig" }));
        b.step("cel-differential-runner", "Build the program tools/cel_differential_check.sh runs beside protovalidate-go").dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    if (b.option([]const u8, "cel-conformance", "The folder tools/cel_conformance_check.sh wrote its cases into")) |folder| {
        const exe = conformance_runner(b, graph, b.pathJoin(&.{ folder, "cases.zig" }));
        b.step("cel-conformance-runner", "Build the program tools/cel_conformance_check.sh runs over cel-spec's conformance suite").dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}

/// The program over `src/protovalidate/cel_expression.zig`, the module `cel_expression`, which
/// takes the imports of the module `protovalidate`, and over the cases the check wrote.
fn conformance_runner(b: *std.Build, graph: Graph, generated: []const u8) *std.Build.Step.Compile {
    const expression = b.createModule(.{
        .root_source_file = b.path("src/protovalidate/cel_expression.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
    });
    var imports = graph.protovalidate.import_table.iterator();
    while (imports.next()) |entry| expression.addImport(entry.key_ptr.*, entry.value_ptr.*);
    const cases = b.createModule(.{ .root_source_file = .{ .cwd_relative = generated }, .target = graph.target, .optimize = graph.optimize });
    return b.addExecutable(.{ .name = "cel-conformance-runner", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/cel_conformance/runner.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "cel_expression", .module = expression },
            .{ .name = "stdx", .module = graph.stdx },
            .{ .name = "cases", .module = cases },
        },
    }) });
}

/// A program over the generated code of one schema, which it imports as `schema`.
fn program(b: *std.Build, graph: Graph, name: []const u8, source: []const u8, generated: []const u8) *std.Build.Step.Compile {
    const schema = b.createModule(.{
        .root_source_file = .{ .cwd_relative = generated },
        .target = graph.target,
        .optimize = graph.optimize,
        // The code imports `connect_zig`, and the program serves no RPC (decision 52).
        .imports = &.{.{ .name = "connect_zig", .module = graph.connect_zig_core }},
    });
    return b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "protovalidate", .module = graph.protovalidate },
            .{ .name = "stdx", .module = graph.stdx },
            .{ .name = "schema", .module = schema },
        },
    }) });
}
