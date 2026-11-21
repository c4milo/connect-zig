//! The example projects of examples/ (decision 41). Each is a Zig project of its own, so this
//! build runs its build as a child process, with this tree's package folder (`--system`) and its
//! cache. The tree then fetches each package once and compiles each module once.
//!
//! - `zig build examples` runs `zig build test` in each project.
//! - `zig build example-<name>` runs one project's `run` step.
//! - `zig build run-eliza-server -- [port]` serves every example's service on a socket, and
//!   `zig build run-std-io-server -- [port]` serves ELIZA over `std.Io`, with no Rotor.
//! - `zig build` installs both servers to zig-out/bin, where the interop checks find them.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

/// Each project, in the order a reader meets them, and what its `zig build test` checks.
const projects = [_]Project{
    .{ .name = "harness", .description = "Run the harness's tests" },
    .{ .name = "protobuf_messages", .description = "Encode and decode generated messages in binary and JSON" },
    .{ .name = "sans_io_call", .description = "Run Connect and gRPC-Web calls through the connect module alone" },
    .{ .name = "eliza", .description = "Run the ELIZA example over colibri's h2, h11 and h3" },
    .{ .name = "streaming", .description = "Run bidirectional, client and server streams" },
    .{ .name = "interceptors", .description = "Run calls through server and client interceptors" },
    .{ .name = "errors", .description = "Run calls that fail with typed error details" },
    .{ .name = "github", .description = "Run a session against a GitHub-style API" },
    .{ .name = "oidc", .description = "Run calls behind OpenID Connect bearer tokens" },
    .{ .name = "std_io", .description = "Call the std.Io server over TCP, with no Rotor" },
    .{ .name = "otlp", .description = "Export a trace to the OTLP receiver and read it back" },
    .{ .name = "quickstart", .description = "Serve the README's GreetService and call it over h11, h2 and h3" },
    .{ .name = "socket_server", .description = "Build the server of every example's service" },
    .{ .name = "validate", .description = "Run calls behind an interceptor that validates each request message" },
};

const Project = struct { name: []const u8, description: []const u8 };

pub fn add(b: *std.Build, graph: Graph) *std.Build.Step {
    const step = b.step("examples", "Run zig build test in each example project");
    // The examples run on Rotor, which this build fetches so that `--system` finds it: Zig then
    // runs the build again with the package in place.
    _ = b.lazyDependency("rotor", .{ .target = graph.target, .release = graph.optimize == .ReleaseSafe }) orelse return step;
    for (projects) |project| {
        const tested = child(b, graph, project.name, &.{"test"});
        step.dependOn(&tested.step);
        // The harness and the socket server have no self-check of their own to run.
        if (std.mem.eql(u8, project.name, "harness") or std.mem.eql(u8, project.name, "socket_server")) continue;
        const ran = child(b, graph, project.name, &.{"run"});
        if (b.args) |args| {
            ran.addArg("--");
            ran.addArgs(args);
        }
        b.step(b.fmt("example-{s}", .{project.name}), project.description).dependOn(&ran.step);
    }
    add_servers(b, graph);
    return step;
}

/// The two servers on a socket: `run-<name>` steps, and an install of each to this tree's
/// zig-out/bin.
fn add_servers(b: *std.Build, graph: Graph) void {
    const servers = [_]struct { project: []const u8, step: []const u8, description: []const u8 }{
        .{ .project = "socket_server", .step = "run-eliza-server", .description = "Serve every example's service on a socket: zig build run-eliza-server -- [port]" },
        .{ .project = "std_io", .step = "run-std-io-server", .description = "Serve ELIZA over std.Io: zig build run-std-io-server -- [port]" },
    };
    for (servers) |server| {
        const serve = child(b, graph, server.project, &.{"serve"});
        if (b.args) |args| {
            serve.addArg("--");
            serve.addArgs(args);
        }
        b.step(server.step, server.description).dependOn(&serve.step);
        const install = child(b, graph, server.project, &.{ "install", "--prefix", b.install_path });
        b.getInstallStep().dependOn(&install.step);
    }
}

/// `zig build <arguments>` in `examples/<name>`, with this tree's packages and cache, and the
/// release mode of this build.
fn child(b: *std.Build, graph: Graph, name: []const u8, arguments: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.addArgs(arguments);
    run.addArgs(&.{ "--system", b.pathFromRoot("zig-pkg") });
    run.addArgs(&.{ "--cache-dir", b.pathFromRoot(".zig-cache") });
    if (b.graph.global_cache_root.path) |path| run.addArgs(&.{ "--global-cache-dir", path });
    if (graph.optimize == .ReleaseSafe) run.addArg("-Drelease");
    run.setCwd(b.path(b.fmt("examples/{s}", .{name})));
    run.has_side_effects = true;
    return run;
}
