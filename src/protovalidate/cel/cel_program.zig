//! One CEL expression, from its text to its value: the parser, the typing and the code it
//! unfolds into, behind three calls. `problem_of` is what `rules_error` asks; `Type` and `run`
//! are for an expression that has no problem.
const std = @import("std");
const constants = @import("../constants.zig");
const parser = @import("cel_parse.zig");
const check = @import("cel_check.zig");
const evaluation = @import("cel_eval.zig");
const type_file = @import("cel_type.zig");
const Scope = type_file.Scope;

/// What stops `text` from being compiled for the names of `scope`, or null. The problem starts
/// with the expression, so a message with many rules shows which one is wrong.
pub fn problem_of(comptime text: []const u8, comptime scope: Scope) ?[]const u8 {
    return switch (Checked(text, scope).typed) {
        .ok => null,
        .problem => |problem| problem,
    };
}

/// The type of the value `text` gives.
pub fn Type(comptime text: []const u8, comptime scope: Scope) type {
    return Checked(text, scope).typed.ok.type;
}

/// One expression's parse and typing for one scope, which the compiler computes once.
///
/// The compiler answers a call from its memory when it has answered the same call before. It
/// keeps no answer of a function that raises its branch quota, nor of a function that calls
/// one (docs/performance.md). So the quota is raised in `typed_of` alone, which this
/// constant's value calls once. `problem_of`, `Type` and each part's typing in
/// `cel_check.zig` raise no quota, and the compiler answers each of them once.
fn Checked(comptime text: []const u8, comptime scope: Scope) type {
    return struct {
        const typed: type_file.Typed = typed_of(text, scope);
    };
}

fn typed_of(comptime text: []const u8, comptime scope: Scope) type_file.Typed {
    comptime {
        @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
        switch (parser.parse(text)) {
            .node => {},
            .problem => |problem| return .{ .problem = "`" ++ text ++ "`: " ++ problem },
        }
        return switch (check.type_of(parser.tree_of(text), scope)) {
            .ok => |ok| .{ .ok = ok },
            .problem => |problem| .{ .problem = "`" ++ text ++ "`: " ++ problem },
        };
    }
}

/// The value of `text` for `values`, a tuple with one value for each name of `scope`.
pub fn run(comptime text: []const u8, comptime scope: Scope, values: anytype, env: *type_file.Env) type_file.Error!Type(text, scope) {
    return evaluation.eval(comptime parser.tree_of(text), scope, values, env);
}
