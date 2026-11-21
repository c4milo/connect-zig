//! One CEL expression, from its text to its value: the parser, the typing and the code it
//! unfolds into, behind three calls. `problem_of` is what `rules_error` asks; `Type` and `run`
//! are for an expression that has no problem.
const std = @import("std");
const constants = @import("../constants.zig");
const parser = @import("cel_parse.zig");
const node_file = @import("cel_node.zig");
const check = @import("cel_check.zig");
const evaluation = @import("cel_eval.zig");
const type_file = @import("cel_type.zig");
const Scope = type_file.Scope;

/// What stops `text` from being compiled for the names of `scope`, or null. The problem starts
/// with the expression, so a message with many rules shows which one is wrong.
pub fn problem_of(comptime text: []const u8, comptime scope: Scope) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
        const node = switch (parser.parse(text)) {
            .node => |node| node,
            .problem => |problem| return "`" ++ text ++ "`: " ++ problem,
        };
        return switch (check.type_of(&node, scope)) {
            .ok => null,
            .problem => |problem| "`" ++ text ++ "`: " ++ problem,
        };
    }
}

fn tree_of(comptime text: []const u8) node_file.Node {
    comptime {
        @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
        return parser.parse(text).node;
    }
}

/// The type of the value `text` gives.
pub fn Type(comptime text: []const u8, comptime scope: Scope) type {
    comptime {
        @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
        return evaluation.Result(&tree_of(text), scope);
    }
}

/// The value of `text` for `values`, a tuple with one value for each name of `scope`.
pub fn run(comptime text: []const u8, comptime scope: Scope, values: anytype, env: *const type_file.Env) type_file.Error!Type(text, scope) {
    const node = comptime tree_of(text);
    return evaluation.eval(&node, scope, values, env);
}
