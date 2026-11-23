//! state-fill: a program allocates its `State` with `rawAlloc`, never with `create` (decision 48).
//!
//! In Debug and ReleaseSafe, `Allocator.create` writes the undefined pattern over the whole
//! value it returns. A program's `State` holds every buffer the program will use, so that write
//! makes each of its pages resident at the start: 318 MiB of the OTLP sink's 331 MB, before one
//! connection. `rawAlloc` returns the pages untouched, and the kernel maps each one when the
//! program first writes it. The rule reports each line that calls `.create(State)`.
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const report = lint.report;

/// The call the rule refuses.
const refused_call = ".create(State)";

/// The rule over the files of `scope`: a type with the `name` and `check` the driver dispatches to.
pub fn Rule(comptime scope: lint.Scope) type {
    return struct {
        pub const name = "state-fill";

        pub fn check(context: *report.Context, file: *const report.File) !void {
            if (!scope.applies(file.path)) return;
            var lines: lint.LineIterator = .{ .source = file.source };
            while (lines.next()) |line| {
                const index = std.mem.indexOf(u8, line.text, refused_call) orelse continue;
                try context.findings.add(file.path, line.number, index + 1, name, "{s}{s}", .{
                    "a program's State comes from rawAlloc, not create, which fills it with the ",
                    "undefined pattern and makes every page resident (docs/decisions.md entry 48)",
                });
            }
        }
    };
}

const testing = std.testing;

const programs: lint.Scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"examples"} };

test "the state-fill rule refuses create(State) and passes rawAlloc" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const filled: [:0]const u8 = "fn f(a: A) !void {\n    const state = try a.create(State);\n    _ = state;\n}\n";
    const found = try lint.harness.run(arena, Rule(programs), "examples/eliza/src/main.zig", filled);
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(2, found[0].line);
    const raw: [:0]const u8 = "fn f(a: A) !void {\n    const memory = a.rawAlloc(@sizeOf(State), .of(State), @returnAddress());\n    _ = memory;\n}\n";
    const passed = try lint.harness.run(arena, Rule(programs), "examples/eliza/src/main.zig", raw);
    try testing.expectEqual(0, passed.len);
}

test "the state-fill rule reads only its scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const filled: [:0]const u8 = "const state = try a.create(State);\n";
    const found = try lint.harness.run(arena_state.allocator(), Rule(programs), "src/connect/code.zig", filled);
    try testing.expectEqual(0, found.len);
}
