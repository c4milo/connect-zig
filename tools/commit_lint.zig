//! connect-zig's commit-message rules: CLAUDE.md, Commits, as a configuration of pepegrillo's
//! linter. Run: `zig build lint-commits`.
const std = @import("std");
const pepegrillo = @import("pepegrillo");

/// The scopes of CLAUDE.md, Commits: the module graph of docs/design.md §3, and the tooling.
const scopes = [_][]const u8{ "protobuf", "connect", "connect-colibri", "oidc", "plugin", "examples", "build", "ci", "docs" };

pub const config: pepegrillo.commit.Config = .{
    .scope_admits_digits = false,
    .known_scopes = &scopes,
    .unknown_scope_reason = "is not one of the scopes CLAUDE.md names",
    .third_person_forms = &.{ "adds", "fixes", "updates", "removes", "implements", "splits", "renames", "moves", "makes", "drops" },
    // Verbs whose own spelling ends as a past tense or a gerund does.
    .imperative_exceptions = &.{ "embed", "seed", "feed", "exceed", "proceed", "succeed", "string", "bring", "ring", "sing", "spring", "swing", "wring", "cling", "fling", "sting" },
    // The session link each commit made with Claude Code carries (CLAUDE.md, Commits).
    .trailer_keys = &.{ "Co-Authored-By", "Claude-Session", "Signed-off-by", "Refs", "Closes" },
};

pub fn main(init: std.process.Init) !void {
    return pepegrillo.commit.main(init, config);
}
