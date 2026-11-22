//! The regular expressions of `pattern` and of CEL's `matches`, on stdx's `regex` module
//! (decision 47). A pattern is text the build knows, so the compiler reads it into a program
//! once, and a pattern stdx refuses stops the build with stdx's message. Each thread keeps one
//! searcher for each pattern, so a check reads the DFA states that earlier checks built.
const std = @import("std");
const regex = @import("regex");
const constants = @import("constants.zig");

/// Whether some part of `text` matches `pattern`. CEL language definition, "Regular
/// Expressions": "matches succeed if they match a substring of the argument". A pattern
/// states its own anchors. An octet of `text` that is not UTF-8 matches nothing. The caller
/// checked the pattern with `problem_of`, as `rules_error` does.
pub fn matches(comptime pattern: []const u8, text: []const u8) bool {
    const Kept = Searcher(pattern);
    if (!Kept.ready) {
        // No feature is named, so the searches take their 16-octet paths on every CPU: the texts
        // of a rule are short, and the library probes no CPU.
        Kept.searcher.init(&Kept.program, .{}, &Kept.memory);
        Kept.ready = true;
    }
    return Kept.searcher.is_match(text);
}

/// The searcher of `pattern` on this thread, made ready at its first check and kept (decision
/// 47, amended 2026-11-22). Its DFA states depend on the pattern alone, never on a text, so a
/// check gives the answer a fresh searcher would. Each thread holds its own, so no two threads
/// write one, and its memory is a constant size the build knows.
fn Searcher(comptime pattern: []const u8) type {
    return struct {
        const program = Compiled(pattern).result catch unreachable;
        // The searcher clears each part of its memory that it reads before it writes, as stdx's
        // own tests rely on, so the memory needs no fill.
        threadlocal var memory: [regex.Searcher.memory_len(program.forward_len, program.slot_count(), constants.pattern_cache_words)]u64 align(@alignOf(u64)) = undefined;
        threadlocal var searcher: regex.Searcher align(@alignOf(regex.Searcher)) = undefined;
        threadlocal var ready: bool align(@alignOf(bool)) = false;
    };
}

/// What stops stdx from reading `pattern`, or null: a form of RE2's that stdx refuses, such as
/// `\p{...}`, or a pattern that is not RE2's syntax.
pub fn problem_of(comptime pattern: []const u8) ?[]const u8 {
    _ = Compiled(pattern).result catch |refusal| {
        return "stdx's regular expressions refuse the pattern `" ++ pattern ++ "`: " ++ @errorName(refusal);
    };
    return null;
}

/// One pattern's program, which the compiler reads once for `problem_of` and `matches`
/// (docs/performance.md, "The compiler's time").
fn Compiled(comptime pattern: []const u8) type {
    return struct {
        const result: regex.Error!regex.Program = compile(pattern);
    };
}

/// The program of `pattern`, forward alone: a search for whether a match exists reads no
/// reverse program. Its instructions are as long as the program, and live in the binary.
fn compile(comptime pattern: []const u8) regex.Error!regex.Program {
    comptime {
        @setEvalBranchQuota(regex.constants.comptime_branch_quota);
        var storage: [regex.constants.comptime_instructions_max]regex.Instruction = undefined;
        var program = try regex.compile(pattern, .{ .reverse = false }, &storage);
        const instructions: [program.instructions.len]regex.Instruction = storage[0..program.instructions.len].*;
        program.instructions = &instructions;
        return program;
    }
}

const testing = std.testing;

test "a pattern matches any part of a text, and its anchors hold it to the whole" {
    try testing.expect(matches("foo.*", "foobar"));
    try testing.expect(matches("bar", "foobar"));
    try testing.expect(!matches("^bar", "foobar"));
    try testing.expect(!matches("^[a-z]+$", "foo bar"));
    try testing.expect(matches("^[a-z]+$", "foobar"));
    try testing.expect(matches("", ""));
}

test "a pattern takes RE2's flags, classes and escapes" {
    try testing.expect(matches("(?i)^[a-z0-9]+$", "AbC123"));
    try testing.expect(!matches("^[a-z0-9]+$", "AbC123"));
    try testing.expect(matches("^[\\x00-\\x7F]+$", "plain ascii"));
    try testing.expect(!matches("^[\\x00-\\x7F]+$", "caf\u{e9}"));
    try testing.expect(matches("\\* \\\\ \\w", "* \\ x"));
    try testing.expect(!matches("\\* \\\\ \\w", "* \\ ."));
}

test "a short text and a long one get RE2's answers" {
    const pattern = "^[A-Z][a-z]+( [A-Z][a-z]+)*$";
    try testing.expect(matches(pattern, "Ada Lovelace Byron King Noel Milbanke Gordon"));
    try testing.expect(!matches(pattern, "Ada Lovelace Byron King Noel milbanke Gordon"));
    try testing.expect(matches(pattern, "Ada"));
    try testing.expect(!matches(pattern, "ada"));
    try testing.expect(matches("king$", "Ada Lovelace Byron king"));
}

test "an octet that is not UTF-8 matches nothing" {
    try testing.expect(!matches("^.$", "\xff"));
    try testing.expect(matches("a", "\xffa"));
}

test "a pattern that stdx refuses is a problem that names it" {
    try testing.expect(comptime problem_of("^[a-z]+$") == null);
    try testing.expectEqualStrings("stdx's regular expressions refuse the pattern `\\p{Greek}`: UnsupportedProperty", comptime problem_of("\\p{Greek}").?);
}

/// The answer of a searcher made ready for `text` alone.
fn fresh(comptime pattern: []const u8, text: []const u8) bool {
    const Kept = Searcher(pattern);
    var memory: @TypeOf(Kept.memory) = undefined;
    var searcher: regex.Searcher = undefined;
    searcher.init(&Kept.program, .{}, &memory);
    return searcher.is_match(text);
}

test "a kept searcher gives each text the answer a fresh one gives" {
    const pattern = "^[A-Z][a-z]+( [A-Z][a-z]+)*$";
    const texts = [_][]const u8{ "Ada", "ada", "Ada Lovelace", "Ada lovelace", "", "Ada Lovelace Byron", "A", "Ab Cd Ef Gh", "Ada  Byron" };
    // Twice over, so the second pass reads the states the first one built.
    for (0..2) |_| {
        for (texts) |text| try testing.expectEqual(fresh(pattern, text), matches(pattern, text));
    }
    // Another pattern keeps a searcher of its own.
    try testing.expect(matches("^[a-z]+$", "ada") and !matches(pattern, "ada") and !matches("^[a-z]+$", "Ada"));
}
