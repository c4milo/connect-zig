//! connect-zig's lint: pepegrillo's generic rules configured for this tree (CLAUDE.md, Commands).
//!
//! Run: `zig build lint`, which passes build.zig and the source directories.
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const rules = lint.rules;

/// The plugin is an executable that reads stdin, writes stdout and uses `init.arena`
/// (docs/decisions.md entry 4), so the heap and I/O rules skip it. A directory matches at any
/// depth, so `src` names each example project's `src/` too: a program owns its memory, sockets,
/// clock and loop, so the library's rules skip `examples` (decision 42).
const library_scope: lint.Scope = .{
    .extensions = &.{lint.paths.zig_extension},
    .include_directories = &.{"src"},
    .exclude_directories = &.{ "src/protoc_gen", "examples" },
};

/// The library's `src/`, and no example project's.
const library_tree: lint.Scope = .{
    .extensions = &.{lint.paths.zig_extension},
    .include_directories = &.{"src"},
    .exclude_directories = &.{"examples"},
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
    .scope = library_tree,
    .prefixes = &.{ "rotor", "colibri" },
    .resolve_file_aliases = true,
    .reason = "the library runs on any event loop (docs/decisions.md entry 32)",
});

/// CLAUDE.md, Conventions: no clock and no randomness, anywhere in `src/`.
pub const determinism = rules.forbidden_references.Rule(.{
    .name = "determinism",
    .scope = library_tree,
    .prefixes = &.{ "std.time", "std.Random", "std.crypto.random", "std.Io.Clock" },
    .reason = "time is a value the caller passes (docs/decisions.md entry 3)",
});

/// The owner's ruling of 2026-11-22 (https://github.com/c4milo/connect-zig/issues/14): `protobuf`,
/// `connect` and `oidc` take the program's CPU features, and their tests take the target's from
/// the one constant of a test-support file.
pub const target_features = @import("target_features.zig").Rule(.{
    .extensions = &.{lint.paths.zig_extension},
    .include_directories = &.{ "src/protobuf", "src/connect", "src/oidc" },
    .exclude_basenames = &.{ "codec_test_support.zig", "test_support.zig" },
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

/// Decision 49: the Python, Go, Rust, and JavaScript of `bench/` and `tools/` keep the same 500
/// lines. A generator writes each `gen/`, and a build or an install fills `target/`,
/// `node_modules/`, `__pycache__/`, and a virtual environment, so the rule skips them.
pub const file_length_scripts = rules.file_length.Rule(.{
    .name = "file-length-scripts",
    .scope = .{
        .extensions = &.{ ".py", ".go", ".rs", ".js", ".mjs" },
        .include_directories = &.{ "bench", "tools" },
        .exclude_directories = &.{ "gen", "target", "node_modules", "__pycache__", ".venv" },
    },
    .message_suffix = "; split the file",
});

/// CLAUDE.md, Conventions: a module reaches another by the name the build gives it. Inside `src/`
/// a file stays in its module's directory; elsewhere no path climbs with `../`.
pub const relative_import = rules.relative_import.Rule(.{
    .scope = library_tree,
    .mode = .leaves_subsystem,
});
pub const relative_import_outside = rules.relative_import.Rule(.{
    .name = "relative-import-outside",
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "examples", "tools", "build", "bench", "conformance" } },
    .mode = .parent_or_absolute,
});

/// CLAUDE.md, Conventions: every limit is a named constant, never an inline literal, in the
/// library, in the code the plugin writes, and in every program of the tree (decision 42). A
/// directory matches at any depth, so `src` and `gen` name each example project's too.
pub const magic_numbers = rules.magic_numbers.Rule(.{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{ "src", "gen", "bench", "conformance", "tools" },
        .exclude_basenames = &.{"constants.zig"},
        // colibri's in-memory links, kept as colibri wrote them.
        .exclude_paths = &.{ "examples/harness/src/link.zig", "examples/harness/src/link_datagram.zig" },
    },
});

/// The library keeps no state every thread shares, and a program allocates its one `State` at
/// startup (decision 42).
pub const global_state = rules.global_state.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "gen", "bench", "conformance", "tools" } },
});

/// A container-level `var` states its alignment, which Zig 0.16's x86_64 backend needs.
pub const static_alignment = rules.static_alignment.Rule(.{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{ "src", "examples", "bench", "conformance" } },
});

/// CLAUDE.md, Conventions: every Markdown file renders on GitHub as written.
pub const markdown = rules.markdown.Rule(.{
    // docs/specs holds each specification as its publisher wrote it (docs/specs/README.md).
    .scope = .{ .extensions = &.{".md"}, .exclude_paths = &.{ "docs/specs/cel/langdef.md", "docs/specs/cel/strings.md" } },
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
        .{ .path = "examples/harness/src/link.zig", .variable = "events" },
        // The storage that a pattern's `compile` fills, which runs at compile time alone.
        .{ .path = "src/protovalidate/pattern.zig", .variable = "storage" },
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
    // connectrpc wrote it, and examples/otlp/proto/opentelemetry is OpenTelemetry's (decision 40),
    // as is tools/fullstack/validate/proto/opentelemetry, with the rules of its README added.
    // src/protovalidate/proto and conformance/protovalidate/proto are protovalidate's and
    // protobuf's, and conformance/protovalidate/gen is the code of the latter, whose schemas
    // name a field with one of the words (decision 47).
    .scope = .{
        .extensions = &.{ lint.paths.zig_extension, ".md", ".sh", ".yml", ".proto" },
        .exclude_paths = &.{ "tools/lint/main.zig", "docs/specs/cel/langdef.md", "docs/specs/cel/strings.md" },
        .exclude_directories = &.{ "conformance/proto", "examples/otlp/proto/opentelemetry", "tools/fullstack/validate/proto/opentelemetry", "src/protovalidate/proto", "conformance/protovalidate/proto", "conformance/protovalidate/gen" },
    },
    .words = &.{ "TODO", "FIXME", "XXX", "HACK" },
    .word_label = "unresolved marker",
});

/// Decision 48: a program allocates its `State` without the undefined pattern, which would make
/// each of its pages resident at the start. The rule reads every program of this tree, but its
/// own file, which spells the call it refuses.
pub const state_fill = @import("state_fill.zig").Rule(.{
    .extensions = &.{lint.paths.zig_extension},
    .include_directories = &.{ "src", "examples", "tools", "build", "bench", "conformance" },
    .exclude_paths = &.{"tools/lint/state_fill.zig"},
});

const Linter = lint.Linter(.{
    heap,            io,              determinism,             unbounded_loop, file_length,  markdown,
    layering,        relative_import, relative_import_outside, magic_numbers,  global_state, static_alignment,
    defer_order,     undefined_fill,  unreleased_acquire,      denied_words,   state_fill,   file_length_scripts,
    target_features,
});

pub fn main(init: std.process.Init) !void {
    return Linter.main(init);
}

const testing = std.testing;
const harness = lint.harness;

test {
    _ = @import("state_fill.zig");
    _ = @import("target_features.zig");
}

/// A source of `count` lines, each `x = 1`, in the arena.
fn lines_of(arena: std.mem.Allocator, count: usize) ![:0]const u8 {
    var source: std.ArrayList(u8) = .empty;
    for (0..count) |_| try source.appendSlice(arena, "x = 1\n");
    return source.toOwnedSliceSentinel(arena, 0);
}

test "the file-length rule reads the scripts of bench and tools, at 500 lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const over = try lines_of(arena, 501);
    const at = try lines_of(arena, 500);
    try testing.expectEqual(1, (try harness.run(arena, file_length_scripts, "tools/fullstack/climb.py", over)).len);
    try testing.expectEqual(1, (try harness.run(arena, file_length_scripts, "bench/go/main.go", over)).len);
    try testing.expectEqual(1, (try harness.run(arena, file_length_scripts, "tools/fullstack/load/src/main.rs", over)).len);
    try testing.expectEqual(1, (try harness.run(arena, file_length_scripts, "bench/validate/node/main.js", over)).len);
    try testing.expectEqual(0, (try harness.run(arena, file_length_scripts, "tools/fullstack/climb.py", at)).len);
}

test "the file-length rule skips generated code, builds, and the interop clients" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const over = try lines_of(arena, 501);
    try testing.expectEqual(0, (try harness.run(arena, file_length_scripts, "bench/go/gen/bench/v1/bench.pb.go", over)).len);
    try testing.expectEqual(0, (try harness.run(arena, file_length_scripts, "bench/rust/target/release/build/out.rs", over)).len);
    try testing.expectEqual(0, (try harness.run(arena, file_length_scripts, "bench/validate/node/node_modules/a.js", over)).len);
    try testing.expectEqual(0, (try harness.run(arena, file_length_scripts, "interop/connect-rust/src/main.rs", over)).len);
}

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
    try testing.expect((try harness.run(arena, undefined_fill, "examples/harness/src/link.zig", source)).len == 0);
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
