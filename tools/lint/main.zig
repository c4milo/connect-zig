//! connect-zig's lint: pepegrillo's generic rules configured for this tree (CLAUDE.md, Commands).
//!
//! Run: `zig build lint`, which passes build.zig and the source directories.
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const rules = lint.rules;

/// The plugin is an executable that reads stdin, writes stdout and uses `init.arena`
/// (docs/decisions.md entry 4), so the heap and I/O rules skip it.
const library_scope: lint.scope.Scope = .{
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

/// CLAUDE.md, Conventions: no clock and no randomness, anywhere in `src/`.
pub const determinism = rules.forbidden_references.Rule(.{
    .name = "determinism",
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .prefixes = &.{ "std.time", "std.Random", "std.crypto.random", "std.Io.Clock" },
    .reason = "time is a value the caller passes (docs/decisions.md entry 3)",
});

/// CLAUDE.md, Conventions: every loop is bounded.
pub const unbounded_loop = rules.unbounded_loop.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "examples" } },
    .forever = .unless_bounded_break,
    .length_read = true,
    .bound = .{ .segments = &.{"constants"}, .last_segment_suffixes = &.{"_max"} },
    .messages = .{
        .forever_without_break = "while (true) has no break; nothing ends the loop",
        .forever_without_bound = "while (true) breaks on no named limit; bound it with a constants.zig value",
        .length_read = "the condition reads {[read]s} against a literal and the loop names no limit",
    },
});

/// CLAUDE.md, Conventions: a file stays at or under 500 lines, generated code included: the plugin
/// splits a long output into a file for each declaration.
pub const file_length = rules.file_length.Rule(.{
    .scope = .{ .extensions = &.{ ".zig", ".sh" } },
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
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "examples", "tools", "build" } },
    .mode = .parent_or_absolute,
});

/// CLAUDE.md, Conventions: every limit is a named constant, never an inline literal, in the
/// library and in the code the plugin writes.
pub const magic_numbers = rules.magic_numbers.Rule(.{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{ "src", "examples/gen" },
        .exclude_basenames = &.{"constants.zig"},
    },
});

/// The library keeps no state every thread shares.
pub const global_state = rules.global_state.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "examples/gen" } },
});

/// A container-level `var` states its alignment, which Zig 0.16's x86_64 backend needs.
pub const static_alignment = rules.static_alignment.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "examples" } },
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

const Linter = lint.Linter(.{
    heap,            io,                      determinism,   unbounded_loop, file_length,      markdown,
    relative_import, relative_import_outside, magic_numbers, global_state,   static_alignment,
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
