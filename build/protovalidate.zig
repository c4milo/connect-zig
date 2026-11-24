//! `zig build protovalidate-executor` builds the program that protovalidate's conformance
//! harness tests, and installs it to zig-out/bin, where
//! `tools/protovalidate_conformance_check.sh` runs the harness against it (decision 47).
//!
//! The program holds the generated code of each schema of the suite, in
//! conformance/protovalidate/gen. Each generated file is a module under the name the plugin
//! gives its .proto file, and its header names the modules it imports (design §8 step 6), so
//! this file reads the folder and builds the modules from the headers.
const std = @import("std");

const Graph = @import("graph.zig").Graph;

/// The folder `tools/generate_check.sh` writes the suite's code into.
const generated_directory = "conformance/protovalidate/gen";
/// The folder of the suite's cases within it: each file there holds messages the harness sends.
const cases_prefix = "buf/validate/conformance/cases/";
const generated_suffix = ".pb.zig";
/// The line of a generated file's header that names the modules the build gives it.
const modules_line_start = "//! The build gives this file the modules ";
/// The longest generated file the build reads the header of.
const generated_len_max = 16 * 1024 * 1024;

const Generated = struct {
    /// The module name: the .proto file's path with each octet that is no letter or digit as "_".
    name: []const u8,
    /// Whether the file holds cases' messages.
    case: bool,
    module: *std.Build.Module,
    /// The modules its header names.
    imports: []const []const u8,
};

/// Adds the executor's steps and returns the step that builds it, which `zig build test` runs so
/// a change that breaks the executor fails there.
pub fn add(b: *std.Build, graph: Graph) *std.Build.Step {
    const generated = generated_modules(b, graph);
    const root = b.createModule(.{
        .root_source_file = b.path("conformance/protovalidate_executor.zig"),
        .target = graph.target,
        .optimize = graph.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = graph.protobuf },
            .{ .name = "protovalidate", .module = graph.protovalidate },
            .{ .name = "platform", .module = graph.platform },
            .{ .name = "harness", .module = find(generated, "buf_validate_conformance_harness_harness").module },
            .{ .name = "cases", .module = cases_module(b, graph, generated) },
        },
    });
    const exe = b.addExecutable(.{ .name = "protovalidate-executor", .root_module = root });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    b.step("protovalidate-executor", "Build the program protovalidate's conformance harness tests into zig-out/bin").dependOn(&install.step);
    return &install.step;
}

/// A module for each generated file of the folder, with the imports its header names.
fn generated_modules(b: *std.Build, graph: Graph) []const Generated {
    const io = b.graph.io;
    const arena = b.graph.arena;
    var directory = b.build_root.handle.openDir(io, generated_directory, .{ .iterate = true }) catch |failure| std.debug.panic("{s}: {t}", .{ generated_directory, failure });
    defer directory.close(io);
    var walker = directory.walk(arena) catch @panic("OOM");
    var list: std.ArrayList(Generated) = .empty;
    while (walker.next(io) catch |failure| std.debug.panic("{s}: {t}", .{ generated_directory, failure })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, generated_suffix)) continue;
        const text = directory.readFileAlloc(io, entry.path, arena, .limited(generated_len_max)) catch |failure| std.debug.panic("{s}: {t}", .{ entry.path, failure });
        list.append(arena, generated_file(b, graph, arena.dupe(u8, entry.path) catch @panic("OOM"), text)) catch @panic("OOM");
    }
    // The folder's order is the file system's: the build names the modules in one order always.
    std.mem.sort(Generated, list.items, {}, by_name);
    link(graph, list.items);
    return list.items;
}

/// One generated file as a module, with the names its header imports.
fn generated_file(b: *std.Build, graph: Graph, path: []const u8, text: []const u8) Generated {
    const arena = b.graph.arena;
    return .{
        .name = module_name(arena, path),
        .case = std.mem.startsWith(u8, path, cases_prefix),
        .module = b.createModule(.{ .root_source_file = b.path(b.pathJoin(&.{ generated_directory, path })), .target = graph.target, .optimize = graph.optimize }),
        .imports = imports_of(arena, text),
    };
}

/// Gives each module the modules its header names.
fn link(graph: Graph, generated: []const Generated) void {
    for (generated) |file| {
        for (file.imports) |import| file.module.addImport(import, resolve(graph, generated, import));
    }
}

fn by_name(_: void, a: Generated, b: Generated) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// "buf/validate/conformance/cases/bool.pb.zig" becomes "buf_validate_conformance_cases_bool",
/// as the plugin's `names.import_name` writes it.
fn module_name(arena: std.mem.Allocator, path: []const u8) []const u8 {
    const name = arena.dupe(u8, path[0 .. path.len - generated_suffix.len]) catch @panic("OOM");
    for (name) |*octet| {
        if (!std.ascii.isAlphanumeric(octet.*)) octet.* = '_';
    }
    return name;
}

/// The modules a generated file's header names: "protobuf, protovalidate, a_b_c."
fn imports_of(arena: std.mem.Allocator, text: []const u8) []const []const u8 {
    const start = std.mem.indexOf(u8, text, modules_line_start) orelse @panic("a generated file's header names no modules");
    const rest = text[start + modules_line_start.len ..];
    const line = rest[0 .. std.mem.indexOf(u8, rest, ".\n") orelse @panic("a generated file's header does not end")];
    var list: std.ArrayList([]const u8) = .empty;
    var names = std.mem.splitSequence(u8, line, ", ");
    while (names.next()) |name| list.append(arena, arena.dupe(u8, name) catch @panic("OOM")) catch @panic("OOM");
    return list.items;
}

/// The module a header names: one of the library's, or another generated file's.
fn resolve(graph: Graph, generated: []const Generated, name: []const u8) *std.Build.Module {
    if (std.mem.eql(u8, name, "protobuf")) return graph.protobuf;
    if (std.mem.eql(u8, name, "connect_zig")) return graph.connect_zig_core;
    if (std.mem.eql(u8, name, "connect")) return graph.connect;
    if (std.mem.eql(u8, name, "protovalidate")) return graph.protovalidate;
    if (graph.protovalidate.import_table.get(name)) |module| return module;
    return find(generated, name).module;
}

fn find(generated: []const Generated, name: []const u8) Generated {
    for (generated) |file| {
        if (std.mem.eql(u8, file.name, name)) return file;
    }
    std.debug.panic("no generated module named {s}", .{name});
}

/// A module that names every module of the suite's cases, which the executor reads each
/// message type from: `pub const modules = .{ @import("a"), @import("b") };`.
fn cases_module(b: *std.Build, graph: Graph, generated: []const Generated) *std.Build.Module {
    const arena = b.graph.arena;
    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(arena, "//! The modules of protovalidate's conformance cases, which build/protovalidate.zig lists.\npub const modules = .{\n") catch @panic("OOM");
    for (generated) |file| {
        if (file.case) text.print(arena, "    @import(\"{s}\"),\n", .{file.name}) catch @panic("OOM");
    }
    text.appendSlice(arena, "};\n") catch @panic("OOM");
    const module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("protovalidate_cases.zig", text.items),
        .target = graph.target,
        .optimize = graph.optimize,
    });
    for (generated) |file| {
        if (file.case) module.addImport(file.name, file.module);
    }
    return module;
}
