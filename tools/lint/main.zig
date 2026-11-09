//! connect-zig's lint: pepegrillo's generic rules configured for this tree (CLAUDE.md, Commands).
//!
//! Run: `zig build lint`, which passes build.zig and the source directories.
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const rules = lint.rules;

/// The plugin is an executable that reads stdin, writes stdout and uses `init.arena`
/// (docs/decisions.md entry 4), so the heap and I/O rules skip it.
const library_scope: lint.Scope = .{
    .extensions = &.{lint.paths.zig_extension},
    .include_directories = &.{"src"},
    .exclude_directories = &.{"src/protoc_gen"},
};

/// CLAUDE.md, Conventions: no `Allocator` in the library.
pub const heap = rules.forbidden_references.Rule(.{
    .name = "heap",
    .scope = library_scope,
    .prefixes = &.{ "std.heap", "std.testing.allocator", "std.testing.failing_allocator" },
    .parameter_check = .{ .type_segment = "Allocator", .description = "an allocator parameter" },
    .reason = "the library allocates nothing (docs/decisions.md entry 4)",
});

/// CLAUDE.md, Conventions: the library makes no system call.
pub const io = rules.forbidden_references.Rule(.{
    .name = "io",
    .scope = library_scope,
    .prefixes = &.{ "std.posix", "std.os", "std.c", "std.fs", "std.net", "std.process", "std.Thread", "std.Io.File", "std.Io.Dir" },
    .reason = "the library owns no I/O (docs/decisions.md entry 3)",
});

/// Decision 32: the library runs on any event loop, so it names neither Rotor nor colibri's
/// `colibri` module, whose `Server` and `Client` own a Rotor loop.
pub const layering = rules.forbidden_references.Rule(.{
    .name = "layering",
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .prefixes = &.{ "rotor", "colibri" },
    .resolve_file_aliases = true,
    .reason = "the library runs on any event loop (docs/decisions.md entry 32)",
});

/// CLAUDE.md, Conventions: no clock and no randomness, anywhere in `src/`.
pub const determinism = rules.forbidden_references.Rule(.{
    .name = "determinism",
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .prefixes = &.{ "std.time", "std.Random", "std.crypto.random", "std.Io.Clock" },
    .reason = "time is a value the caller passes (docs/decisions.md entry 3)",
});

/// CLAUDE.md, Conventions: every loop is bounded.
pub const unbounded_loop = rules.unbounded_loop.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "examples", "bench", "conformance" } },
    .forever = .unless_bounded_break,
    .length_read = true,
    .bound = .{ .segments = &.{"constants"}, .last_segment_suffixes = &.{"_max"} },
    .messages = .{
        .forever_without_break = "while (true) has no break; nothing ends the loop",
        .forever_without_bound = "while (true) breaks on no named limit; bound it with a constants.zig value",
        .length_read = "the condition reads {[read]s} against a literal and the loop names no limit",
    },
});

/// CLAUDE.md, Conventions: a file stays at or under 500 lines. Generated code is one file per
/// .proto file, whatever its length, as other generators write it (decision 17).
pub const file_length = rules.file_length.Rule(.{
    .scope = .{ .extensions = &.{ ".zig", ".sh" }, .exclude_basename_suffixes = &.{".pb.zig"} },
    .message_suffix = "; split the file",
});

/// CLAUDE.md, Conventions: a module reaches another by the name the build gives it. Inside `src/`
/// a file stays in its module's directory; elsewhere no path climbs with `../`.
pub const relative_import = rules.relative_import.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .mode = .leaves_subsystem,
});
pub const relative_import_outside = rules.relative_import.Rule(.{
    .name = "relative-import-outside",
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "examples", "tools", "build", "bench", "conformance" } },
    .mode = .parent_or_absolute,
});

/// CLAUDE.md, Conventions: every limit is a named constant, never an inline literal, in the
/// library and in the code the plugin writes.
pub const magic_numbers = rules.magic_numbers.Rule(.{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{ "src", "examples/gen", "bench/gen", "conformance/gen" },
        .exclude_basenames = &.{"constants.zig"},
    },
});

/// The library keeps no state every thread shares.
pub const global_state = rules.global_state.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "examples/gen", "bench/gen", "conformance/gen" } },
});

/// A container-level `var` states its alignment, which Zig 0.16's x86_64 backend needs.
pub const static_alignment = rules.static_alignment.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "examples", "bench", "conformance" } },
});

/// CLAUDE.md, Conventions: every Markdown file renders on GitHub as written.
pub const markdown = rules.markdown.Rule(.{
    .scope = .{ .extensions = &.{".md"} },
    .pseudo_list_item = true,
    .code_span_pipe = true,
    .fence_language = true,
    .table_columns = true,
    .trailing_whitespace = true,
});

/// The Zig code this tree writes by hand or generates, which the remaining rules read.
const zig_tree: lint.Scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "examples", "tools", "build", "bench", "conformance" } };

/// A `defer` goes above any statement that can fail, so what the block acquired is released.
pub const defer_order = rules.defer_order.Rule(.{ .scope = zig_tree });

/// A function's local array is not set to `undefined`, which Debug and ReleaseSafe fill on each
/// call: the library, the examples and the benchmark take that memory from their caller instead.
pub const undefined_fill = rules.undefined_fill.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "examples", "bench", "conformance" } },
    .stop_at_testing_import = true,
    // A copy of colibri's examples/link.zig, kept as colibri wrote it.
    .allowed = &.{
        .{ .path = "examples/services/link.zig", .variable = "events" },
    },
});

/// A socket, a file or a loop opened with `try` is closed before a later statement can fail.
pub const unreleased_acquire = rules.unreleased_acquire.Rule(.{
    .scope = zig_tree,
    .acquire_prefixes = &.{ "open", "listen", "init" },
    .read_assignments = true,
});

/// No unresolved marker ships: open work is a GitHub issue (CLAUDE.md, Conventions).
pub const denied_words = rules.denied_words.Rule(.{
    // This file names the words to deny them. conformance/proto is connectrpc's copy, kept as
    // connectrpc wrote it.
    .scope = .{
        .extensions = &.{ lint.paths.zig_extension, ".md", ".sh", ".yml", ".proto" },
        .exclude_paths = &.{"tools/lint/main.zig"},
        .exclude_directories = &.{"conformance/proto"},
    },
    .words = &.{ "TODO", "FIXME", "XXX", "HACK" },
    .word_label = "unresolved marker",
});

const Linter = lint.Linter(.{
    heap,        io,              determinism,             unbounded_loop, file_length,  markdown,
    layering,    relative_import, relative_import_outside, magic_numbers,  global_state, static_alignment,
    defer_order, undefined_fill,  unreleased_acquire,      denied_words,
});

pub fn main(init: std.process.Init) !void {
    return Linter.main(init);
}

const testing = std.testing;
const harness = lint.harness;

test "the heap rule refuses an allocator in the library and not in the plugin" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 = "const std = @import(\"std\");\nfn f(a: std.mem.Allocator) void { _ = a; }\n";
    const library = try harness.run(arena, heap, "src/connect/code.zig", source);
    try testing.expect(library.len == 1);
    const plugin = try harness.run(arena, heap, "src/protoc_gen/main.zig", source);
    try testing.expect(plugin.len == 0);
}

test "the determinism rule refuses a clock read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source: [:0]const u8 = "const std = @import(\"std\");\nconst t = std.time.nanoTimestamp;\n";
    const findings = try harness.run(arena_state.allocator(), determinism, "src/connect/timeout.zig", source);
    try testing.expect(findings.len == 1);
}

test "undefined-fill reports a large local array and passes the copy of colibri's link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 = "const T = struct { a: u64 };\nfn f() void {\n    var events: [16]T = undefined;\n    _ = &events;\n}\n";
    try testing.expect((try harness.run(arena, undefined_fill, "src/connect/reply.zig", source)).len == 1);
    try testing.expect((try harness.run(arena, undefined_fill, "examples/services/link.zig", source)).len == 0);
}

test "denied-words refuses an unresolved marker in prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), denied_words, "docs/design.md", "Fix this later. todo: split it\n");
    try testing.expect(findings.len == 1);
}

test "defer-order refuses a defer under a statement that can fail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source: [:0]const u8 = "fn f() !void {\n    const a = try open();\n    try flush();\n    defer close(a);\n}\n";
    try testing.expect((try harness.run(arena_state.allocator(), defer_order, "src/connect/x.zig", source)).len == 1);
}

test "the conformance programs are read as the examples are" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fill: [:0]const u8 = "const T = struct { a: u64 };\nfn f() void {\n    var events: [16]T = undefined;\n    _ = &events;\n}\n";
    const loop: [:0]const u8 = "fn f(go: bool) void {\n    while (true) {\n        if (go) break;\n    }\n}\n";
    const global: [:0]const u8 = "const std = @import(\"std\");\nvar io: std.Io = undefined;\n";
    const climb: [:0]const u8 = "const a = @import(\"../src/connect/code.zig\");\n";
    try testing.expect((try harness.run(arena, undefined_fill, "conformance/echo.zig", fill)).len == 1);
    try testing.expect((try harness.run(arena, unbounded_loop, "conformance/echo.zig", loop)).len == 1);
    try testing.expect((try harness.run(arena, static_alignment, "conformance/client.zig", global)).len == 1);
    try testing.expect((try harness.run(arena, relative_import_outside, "conformance/echo.zig", climb)).len == 1);
    const late: [:0]const u8 = "fn f() !void {\n    const a = try open();\n    try flush();\n    defer close(a);\n}\n";
    try testing.expect((try harness.run(arena, defer_order, "conformance/server.zig", late)).len == 1);
    // The code buf generates for the suite keeps the rules of generated code (decision 17).
    const shared: [:0]const u8 = "var calls: u32 align(4) = 0;\n";
    try testing.expect((try harness.run(arena, global_state, "conformance/gen/a.pb.zig", shared)).len == 1);
    try testing.expect((try harness.run(arena, magic_numbers, "conformance/gen/a.pb.zig", "fn f() u32 {\n    return 300;\n}\n")).len == 1);
}
