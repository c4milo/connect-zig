//! `zig build bench`: the protobuf runtime's benchmark in bench/, then the routed calls of
//! bench/call_main.zig, each built ReleaseFast. `zig build bench-validate -- [--quick] <dir>`
//! times connect-zig's protovalidate over bench/validate, a program of its own too, which
//! tools/validate_compare_check.sh runs beside the other implementations. Arguments after `--` reach both programs: `zig
//! build bench -- --quick` runs them as a smoke test. The routed calls are a program of their
//! own, so their code does not change how the compiler lays out the codec's.
//!
//! The library's own build offers Debug and ReleaseSafe alone. The benchmark builds its own copy
//! of the protobuf module, and the generated code of bench/gen, in ReleaseFast. stdx's build
//! offers ReleaseSafe at most, so the benchmark copies stdx's module and the modules it names,
//! and the objects of their vector kernels, in ReleaseFast too: the JSON numbers then count no stdx
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
            .{ .name = "stdx", .module = release_fast(b, &copies, stdx.module("stdx")) },
            .{ .name = "public_names", .module = public_names },
        },
    });
    const messages = b.createModule(.{
        .root_source_file = b.path("bench/gen/bench/v1/bench.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "connect_zig", .module = without_colibri(b, &.{.{ .name = "protobuf", .module = protobuf }}, target) }},
    });
    const routed = routed_modules(b, &copies, stdx, protobuf, public_names, target);
    const exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            // `--instructions` talks to callgrind through client requests, which ReleaseFast drops
            // unless the module asks for them. Natively each is a few instructions outside the loops.
            // The judge runs on Linux; Zig refuses the request on a target valgrind does not
            // run on, such as arm64 macOS, where the benchmark must still build.
            .valgrind = if (target.result.os.tag == .linux) true else null,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf },
                .{ .name = "bench_v1", .module = messages },
            },
        }),
    });
    const call_exe = b.addExecutable(.{
        .name = "bench-call",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/call_main.zig"),
            .target = target,
            .optimize = optimize,
            .valgrind = if (target.result.os.tag == .linux) true else null,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf },
                .{ .name = "bench_v1", .module = messages },
                .{ .name = "connect", .module = routed.connect },
                .{ .name = "connect_colibri", .module = routed.connect_colibri },
                .{ .name = "colibri", .module = routed.colibri },
                .{ .name = "stdx", .module = routed.stdx },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    run.has_side_effects = true;
    // The routed calls print their rows after the codec's, so the two tables never interleave.
    const call_run = b.addRunArtifact(call_exe);
    if (b.args) |args| call_run.addArgs(args);
    call_run.has_side_effects = true;
    call_run.step.dependOn(&run.step);
    // tools/perf_check.sh runs the programs under valgrind, so it needs the binaries themselves.
    const install = b.step("install-bench", "Install the benchmark programs into zig-out/bin");
    install.dependOn(&b.addInstallArtifact(exe, .{}).step);
    install.dependOn(&b.addInstallArtifact(call_exe, .{}).step);
    // stdx, whose `regex` runs the rules and whose `platform` holds the CPU features it takes.
    install.dependOn(add_validate(b, protobuf, public_names, release_fast(b, &copies, stdx.module("stdx")), target));
    b.step("bench", "Benchmark the protobuf runtime and a routed call, ReleaseFast: zig build bench -- [--quick] [--write <dir>]").dependOn(&call_run.step);

    // `zig build costs`: the costs table of docs/performance.md, timed on the machine that runs it.
    const costs = b.addExecutable(.{
        .name = "costs",
        .root_module = b.createModule(.{ .root_source_file = b.path("bench/costs.zig"), .target = target, .optimize = optimize }),
    });
    const costs_run = b.addRunArtifact(costs);
    costs_run.has_side_effects = true;
    b.step("costs", "Time a cache hit, a memory read, a mispredict, a copy and a system call, ReleaseFast").dependOn(&costs_run.step);
}

/// `zig build bench-validate`: bench/validate_main.zig over `protovalidate` and the generated code
/// of bench/validate, each in ReleaseFast, as the root build makes them. Returns the step that
/// installs it, which `install-bench` takes for tools/perf_check.sh.
fn add_validate(b: *std.Build, protobuf: *std.Build.Module, public_names: *std.Build.Module, stdx_module: *std.Build.Module, target: std.Build.ResolvedTarget) *std.Build.Step {
    const descriptor = b.createModule(.{
        .root_source_file = b.path("src/protovalidate/gen/google/protobuf/descriptor.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf }},
    });
    const rules = b.createModule(.{
        .root_source_file = b.path("src/protovalidate/gen/buf/validate/validate.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "google_protobuf_descriptor", .module = descriptor },
        },
    });
    const protovalidate = b.createModule(.{
        .root_source_file = b.path("src/protovalidate/protovalidate.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "buf_validate_validate", .module = rules },
            .{ .name = "google_protobuf_descriptor", .module = descriptor },
            .{ .name = "public_names", .module = public_names },
            .{ .name = "stdx", .module = stdx_module },
        },
    });
    const connect_zig = without_colibri(b, &.{
        .{ .name = "protobuf", .module = protobuf },
        .{ .name = "protovalidate", .module = protovalidate },
        .{ .name = "stdx", .module = stdx_module },
        .{ .name = "buf_validate_validate", .module = rules },
        .{ .name = "google_protobuf_descriptor", .module = descriptor },
    }, target);
    const messages = b.createModule(.{
        .root_source_file = b.path("bench/validate/gen/bench/validate/v1/validate.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "connect_zig", .module = connect_zig }},
    });
    const exe = b.addExecutable(.{
        .name = "bench-validate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/validate_main.zig"),
            .target = target,
            .optimize = optimize,
            // `--instructions` talks to callgrind, as bench/main.zig does.
            .valgrind = if (target.result.os.tag == .linux) true else null,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf },
                .{ .name = "protovalidate", .module = protovalidate },
                .{ .name = "stdx", .module = stdx_module },
                .{ .name = "bench_validate_v1", .module = messages },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    run.has_side_effects = true;
    b.step("bench-validate", "Time connect-zig's protovalidate over bench/validate, ReleaseFast: zig build bench-validate -- [--quick] <dir>").dependOn(&run.step);
    const install = b.addInstallArtifact(exe, .{});
    b.step("install-bench-validate", "Install the validation benchmark into zig-out/bin").dependOn(&install.step);
    return &install.step;
}

/// The module `connect_zig` without colibri (decision 52), over the benchmark's ReleaseFast copies
/// in `imports`. Generated code imports it; a name the benchmark does not read needs no import.
fn without_colibri(b: *std.Build, imports: []const std.Build.Module.Import, target: std.Build.ResolvedTarget) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "colibri", false);
    options.addOption(bool, "oidc", false);
    const module = b.createModule(.{ .root_source_file = b.path("src/connect_zig/connect_zig.zig"), .target = target, .optimize = optimize });
    module.addImport("connect_zig_options", options.createModule());
    for (imports) |import| module.addImport(import.name, import.module);
    return module;
}

/// The modules a routed call runs (bench/call.zig), in ReleaseFast.
const Routed = struct {
    connect: *std.Build.Module,
    connect_colibri: *std.Build.Module,
    /// colibri's one module, which names its others (colibri decision 170).
    colibri: *std.Build.Module,
    /// stdx, whose `platform` holds the type of CPU features the route's context holds.
    stdx: *std.Build.Module,
};

/// `connect` and `connect_colibri` as the root build makes them, over copies of colibri's modules
/// in ReleaseFast. colibri in ReleaseSafe asks stdx with `.release = true`, as `add` does, so both
/// share one copy of stdx. The benchmark needs no Rotor.
fn routed_modules(b: *std.Build, copies: *Copies, stdx: *std.Build.Dependency, protobuf: *std.Build.Module, public_names: *std.Build.Module, target: std.Build.ResolvedTarget) Routed {
    const colibri = b.dependency("colibri", .{ .target = target, .release = true, .rotor = false });
    const colibri_module = release_fast(b, copies, colibri.module("colibri"));
    const stdx_module = release_fast(b, copies, stdx.module("stdx"));
    const connect = b.createModule(.{
        .root_source_file = b.path("src/connect/connect.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "stdx", .module = stdx_module },
            .{ .name = "public_names", .module = public_names },
        },
    });
    const connect_colibri = b.createModule(.{
        .root_source_file = b.path("src/connect_colibri/connect_colibri.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "connect", .module = connect },
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "colibri", .module = colibri_module },
            .{ .name = "stdx", .module = stdx_module },
            .{ .name = "public_names", .module = public_names },
        },
    });
    return .{ .connect = connect, .connect_colibri = connect_colibri, .colibri = colibri_module, .stdx = stdx_module };
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
