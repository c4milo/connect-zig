//! The programs of the two checks that write a schema as they run (decision 47):
//!
//! - `zig build compile-time-subject -Dcompile-time=<folder>` builds the program whose build
//!   `tools/compile_time_check.sh` times: it validates one message of the schema's rules.
//! - `zig build cel-differential-runner -Dcel-differential=<folder>` builds the program that
//!   `tools/cel_differential_check.sh` runs beside protovalidate-go.
//!
//! Each check writes its schema's generated code into its folder, so a step exists only in a
//! build that names the folder.
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
}

/// A program over the generated code of one schema, which it imports as `schema`.
fn program(b: *std.Build, graph: Graph, name: []const u8, source: []const u8, generated: []const u8) *std.Build.Step.Compile {
    const schema = b.createModule(.{
        .root_source_file = .{ .cwd_relative = generated },
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "protovalidate", .module = graph.protovalidate },
        },
    });
    return b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "protovalidate", .module = graph.protovalidate },
            .{ .name = "schema", .module = schema },
        },
    }) });
}
