//! `zig build bench`: the protobuf runtime's benchmark in bench/, built ReleaseFast.
//! Arguments after `--` reach the program: `zig build bench -- --quick` runs it as a smoke test.
//!
//! The library's own build offers Debug and ReleaseSafe alone. The benchmark builds its own copy
//! of the protobuf module, and the generated code of bench/gen, in ReleaseFast. stdx's build
//! offers ReleaseSafe at most, so the benchmark copies the stdx modules it imports, and the
//! objects of their vector kernels, in ReleaseFast too: the JSON numbers then count no stdx
//! assertion, as they count none of connect-zig's.
const std = @import("std");

const optimize: std.builtin.OptimizeMode = .ReleaseFast;

pub fn add(b: *std.Build, public_names: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const stdx = b.dependency("stdx", .{ .target = target, .release = true });
    var copies: Copies = .empty;
    const protobuf = b.createModule(.{
        .root_source_file = b.path("src/protobuf/protobuf.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json", .module = release_fast(b, &copies, stdx.module("json")) },
            .{ .name = "codec", .module = release_fast(b, &copies, stdx.module("codec")) },
            .{ .name = "base64", .module = release_fast(b, &copies, stdx.module("base64")) },
            .{ .name = "public_names", .module = public_names },
        },
    });
    const messages = b.createModule(.{
        .root_source_file = b.path("bench/gen/bench/v1/bench.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf }},
    });
    const exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            // `--instructions` talks to callgrind through client requests, which ReleaseFast drops
            // unless the module asks for them. Natively each is a few instructions outside the loops.
            .valgrind = true,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf },
                .{ .name = "bench_v1", .module = messages },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    run.has_side_effects = true;
    // tools/perf_check.sh runs the program under valgrind, so it needs the binary itself.
    b.step("install-bench", "Install the benchmark program into zig-out/bin").dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.step("bench", "Benchmark the protobuf runtime, ReleaseFast: zig build bench -- [--quick] [--write <dir>]").dependOn(&run.step);

    // `zig build costs`: the costs table of docs/performance.md, timed on the machine that runs it.
    const costs = b.addExecutable(.{
        .name = "costs",
        .root_module = b.createModule(.{ .root_source_file = b.path("bench/costs.zig"), .target = target, .optimize = optimize }),
    });
    const costs_run = b.addRunArtifact(costs);
    costs_run.has_side_effects = true;
    b.step("costs", "Time a cache hit, a memory read, a mispredict, a copy and a system call, ReleaseFast").dependOn(&costs_run.step);
}

/// Each module copied so far, by its original: a module two others import is copied once, as a
/// file may belong to one module of a compilation alone.
const Copies = std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module);

/// A copy of a dependency's `module` in ReleaseFast: its root, its target, its imports copied the
/// same way, and each object it links, which holds a vector kernel built for one CPU level. A
/// module with no mode of its own, such as an options module, is shared as it is. The original
/// stays as the dependency built it, since `zig build test -Drelease` shares that instance.
fn release_fast(b: *std.Build, copies: *Copies, module: *std.Build.Module) *std.Build.Module {
    if (module.optimize == null) return module;
    if (copies.get(module)) |copied| return copied;
    const copy = b.createModule(.{
        .root_source_file = module.root_source_file,
        .target = module.resolved_target,
        .optimize = optimize,
    });
    copies.put(b.allocator, module, copy) catch @panic("out of memory");
    for (module.import_table.keys(), module.import_table.values()) |name, imported| {
        copy.addImport(name, release_fast(b, copies, imported));
    }
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |compile| copy.addObject(b.addObject(.{
            .name = compile.name,
            .root_module = release_fast(b, copies, compile.root_module),
            .use_llvm = compile.use_llvm,
        })),
        else => std.debug.panic("stdx's {s} links an object the benchmark cannot copy", .{@tagName(object)}),
    };
    return copy;
}
