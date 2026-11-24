//! target-features: a library takes the CPU features the program detects, and never names the
//! build target's in their place (the owner's ruling of 2026-11-22,
//! https://github.com/c4milo/connect-zig/issues/14).
//!
//! The JSON readers and writers and the base64 coders of stdx write the same octets on every path,
//! so no test sees which features a call took. The rule reads the text: it reports each line of
//! code in its scope that calls `target()`, written as `platform.CpuFeatures.target()`, through an
//! alias, through `@import("platform")` in place, or as the declaration literal `.target()`.
//! A comment is no call. The scope leaves out the test-support files, whose one constant gives
//! the tests the target's features. One line of one file passes: the default of
//! `connect.client.Options.cpu_features`, which stays until a client sets its features once
//! (decision 10 as amended).
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const report = lint.report;

/// The call the rule refuses.
const refused_call = "target()";
/// The one line that may call it, and the one file that may hold the line: the default of a
/// client's options (decision 10 as amended).
const ruled_default = "cpu_features: platform.CpuFeatures = .target(),";
const ruled_default_file = "src/connect/client_call.zig";
/// What starts a comment line.
const comment_start = "//";

/// The rule over the files of `scope`: a type with the `name` and `check` the driver dispatches to.
pub fn Rule(comptime scope: lint.Scope) type {
    return struct {
        pub const name = "target-features";

        pub fn check(context: *report.Context, file: *const report.File) !void {
            if (!scope.applies(file.path)) return;
            var lines: lint.LineIterator = .{ .source = file.source };
            while (lines.next()) |line| {
                const code = std.mem.trim(u8, line.text, " \t");
                if (std.mem.startsWith(u8, code, comment_start)) continue;
                if (std.mem.eql(u8, code, ruled_default) and std.mem.endsWith(u8, file.path, ruled_default_file)) continue;
                const index = std.mem.indexOf(u8, line.text, refused_call) orelse continue;
                try context.findings.add(file.path, line.number, index + 1, name, "{s}{s}", .{
                    "a library takes the CPU features the program detects, not the build target's ",
                    "(https://github.com/c4milo/connect-zig/issues/14)",
                });
            }
        }
    };
}

const testing = std.testing;

const library: lint.Scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src/connect"} };

fn findings_of(source: [:0]const u8, path: []const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const found = try lint.harness.run(arena_state.allocator(), Rule(library), path, source);
    return found.len;
}

test "the target-features rule refuses each way to call target()" {
    const refused = [_][:0]const u8{
        "const f = platform.CpuFeatures.target();\n",
        "const f = Features.target();\n",
        "const f = @import(\"platform\").CpuFeatures.target();\n",
        "fn f() void {\n    call(.{ .cpu_features = .target() });\n}\n",
        "const S = struct {\n    options: platform.CpuFeatures = .target(),\n};\n",
    };
    for (refused) |source| try testing.expectEqual(1, try findings_of(source, "src/connect/code.zig"));
}

test "the target-features rule passes the ruled default in its file alone, comments, and other files" {
    const ruled: [:0]const u8 = "const S = struct {\n    cpu_features: platform.CpuFeatures = .target(),\n};\n";
    try testing.expectEqual(0, try findings_of(ruled, ruled_default_file));
    try testing.expectEqual(1, try findings_of(ruled, "src/connect/code.zig"));
    try testing.expectEqual(0, try findings_of("/// The default is `.target()`.\nconst f = 1;\n", "src/connect/code.zig"));
    try testing.expectEqual(0, try findings_of("const f = cpu_features;\n", "src/connect/code.zig"));
    try testing.expectEqual(0, try findings_of("const f = platform.CpuFeatures.target();\n", "src/protobuf/code.zig"));
}
