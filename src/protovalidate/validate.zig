//! `validate`: one message against the rules of its schema (decision 47).
const std = @import("std");
const assert = std.debug.assert;
const table = @import("table.zig");
const report_file = @import("report.zig");
const walk_file = @import("walk.zig");
const message_file = @import("message.zig");
const check_file = @import("check.zig");

pub const Options = walk_file.Options;
pub const Error = walk_file.Error;

/// Checks `message` against the rules of `T` and of each message it holds, and writes each
/// violation into `report`. It returns `Invalid` when the message breaks a rule: the report
/// then holds each violation it had room for, after those it held before, and is marked
/// truncated when it had no room for one. A type with no rule passes.
///
/// A rule the module has no check for stops the build, with the message `rules_error` gives.
pub fn validate(comptime T: type, message: *const T, options: Options, report: *report_file.Report) Error!void {
    comptime if (check_file.rules_error(T)) |problem| @compileError("protovalidate: " ++ problem);
    if (comptime !table.has_rules(T)) return;
    const before = report.count;
    var walk: walk_file.Walk = .{ .report = report, .options = &options };
    message_file.check(T, message, &walk, null) catch |fault| switch (fault) {
        error.ReportFull => {
            assert(report.truncated);
            return error.Invalid;
        },
        else => |failure| return failure,
    };
    assert(walk.depth == 0);
    if (report.count != before) return error.Invalid;
}
