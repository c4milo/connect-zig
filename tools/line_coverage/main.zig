//! The line coverage of the library's modules, through pepegrillo's `coverage` tool: it runs
//! each module's test binary under kcov 43, and prints the share of each module's lines that its
//! tests run, with a total. `tools/line_coverage_check.sh` runs it, and the README's badge takes
//! the total from CI's run of that check.
//!
//! Zig compiles only the functions that code references, so a function no test references has no
//! line to count: the share is of the lines the tests compile.
const std = @import("std");
const pepegrillo = @import("pepegrillo");

pub fn main(init: std.process.Init) !void {
    return pepegrillo.coverage.main(init, .{
        .directories = &.{ "src/protobuf", "src/connect", "src/connect_colibri", "src/oidc", "src/protoc_gen", "src/public_names" },
    });
}
