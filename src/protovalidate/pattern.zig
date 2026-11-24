//! The regular expressions of `pattern` and of CEL's `matches`, on stdx's `regex` module
//! (decision 47). A pattern is text the build knows, so the compiler reads it into a program
//! once, and a pattern stdx refuses stops the build with stdx's message. Each thread keeps one
//! searcher for each pattern, so a check reads the DFA states that earlier checks built. A search
//! takes the CPU features the program detected once and passes in `Options` (decision 47).
const std = @import("std");
const assert = std.debug.assert;
const regex = @import("regex");
const platform = @import("platform");
const constants = @import("constants.zig");

// The CPU features a search takes are stdx's `platform.CpuFeatures`, of the stdx `regex` comes
// from. A program detects them once with `platform.CpuFeatures.detect()`, or names the build
// target's with `platform.CpuFeatures.target()`. A search with AVX2 reads 32 octets a step where
// it reads 16 without.
comptime {
    assert(@FieldType(regex.SearcherOptions, "features") == platform.CpuFeatures);
}

/// Whether some part of `text` matches `pattern`. CEL language definition, "Regular
/// Expressions": "matches succeed if they match a substring of the argument". A pattern
/// states its own anchors. An octet of `text` that is not UTF-8 matches nothing. The caller
/// checked the pattern with `problem_of`, as `rules_error` does.
pub fn matches(comptime pattern: []const u8, text: []const u8, cpu_features: platform.CpuFeatures) bool {
    const Kept = Searcher(pattern);
    // A searcher is made ready again for features that its last check did not name, so each
    // check searches with its caller's. A program passes the one value it detected, so a thread
    // makes each searcher ready once, and each later check compares the features' octets.
    if (!Kept.ready or !std.mem.eql(u8, octets_of(&Kept.ready_with), octets_of(&cpu_features))) make_ready(Kept, cpu_features);
    return Kept.searcher.is_match(text);
}

fn make_ready(comptime Kept: type, cpu_features: platform.CpuFeatures) void {
    Kept.searcher.init(&Kept.program, &.{ .features = cpu_features }, &Kept.memory);
    Kept.ready_with = cpu_features;
    Kept.ready = true;
}

/// A set of features as its octets. Each field is a bool, one octet that holds 0 or 1, so the
/// struct holds no padding and two equal sets hold equal octets.
fn octets_of(cpu_features: *const platform.CpuFeatures) *const [@sizeOf(platform.CpuFeatures)]u8 {
    comptime assert(@sizeOf(platform.CpuFeatures) == std.meta.fields(platform.CpuFeatures).len);
    comptime for (std.meta.fields(platform.CpuFeatures)) |field| assert(field.type == bool);
    return @ptrCast(cpu_features);
}

/// The features this thread's searcher of `pattern` was made ready with, or null before its
/// first check. The tests read it to see that a check's features reach the searcher.
pub fn kept_cpu_features(comptime pattern: []const u8) ?platform.CpuFeatures {
    const Kept = Searcher(pattern);
    return if (Kept.ready) Kept.ready_with else null;
}

/// The searcher of `pattern` on this thread, made ready at its first check and kept (decision
/// 47, amended 2026-11-22). Its DFA states depend on the pattern alone, never on a text, so a
/// check gives the answer a fresh searcher would. Each thread holds its own, so no two threads
/// write one, and its memory is a constant size the build knows.
fn Searcher(comptime pattern: []const u8) type {
    return SearcherOf(pattern[0..pattern.len].*);
}

/// The searcher of a pattern's octets. The compiler makes one type of a function for each array
/// of equal octets, and may make two for two slices of equal text, as a rule's literal and the
/// test's constant are. So a pattern's text has one searcher on a thread, wherever it is named.
fn SearcherOf(comptime octets: anytype) type {
    return struct {
        const program = Compiled(&octets).result catch unreachable;
        // The searcher clears each part of its memory that it reads before it writes, as stdx's
        // own tests rely on, so the memory needs no fill.
        threadlocal var memory: [regex.Searcher.memory_len(program.forward_len, program.slot_count(), constants.pattern_cache_words)]u64 align(@alignOf(u64)) = undefined;
        threadlocal var searcher: regex.Searcher align(@alignOf(regex.Searcher)) = undefined;
        /// Whether a check made the searcher ready, and with which features.
        threadlocal var ready: bool align(@alignOf(bool)) = false;
        threadlocal var ready_with: platform.CpuFeatures align(@alignOf(platform.CpuFeatures)) = .{};
    };
}

/// What stops stdx from reading `pattern`, or null: a pattern that is not RE2's syntax, such as
/// `\p{Nothing}` or a backreference, or one past a limit of stdx's, such as a class of more
/// ranges than it holds.
pub fn problem_of(comptime pattern: []const u8) ?[]const u8 {
    _ = Compiled(pattern).result catch |refusal| {
        return "stdx's regular expressions refuse the pattern `" ++ pattern ++ "`: " ++ @errorName(refusal);
    };
    return null;
}

/// One pattern's program, which the compiler reads once for `problem_of` and `matches`
/// (docs/performance.md, "The compiler's time"), found by the pattern's octets as `Searcher` is.
fn Compiled(comptime pattern: []const u8) type {
    return CompiledOf(pattern[0..pattern.len].*);
}

fn CompiledOf(comptime octets: anytype) type {
    return struct {
        const result: regex.Error!regex.Program = compile(&octets);
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
/// What the build target guarantees, which every CPU that runs the tests has.
const testing_cpu_features = platform.CpuFeatures.target();

test "a pattern matches any part of a text, and its anchors hold it to the whole" {
    try testing.expect(matches("foo.*", "foobar", testing_cpu_features));
    try testing.expect(matches("bar", "foobar", testing_cpu_features));
    try testing.expect(!matches("^bar", "foobar", testing_cpu_features));
    try testing.expect(!matches("^[a-z]+$", "foo bar", testing_cpu_features));
    try testing.expect(matches("^[a-z]+$", "foobar", testing_cpu_features));
    try testing.expect(matches("", "", testing_cpu_features));
}

test "a pattern takes RE2's flags, classes and escapes" {
    try testing.expect(matches("(?i)^[a-z0-9]+$", "AbC123", testing_cpu_features));
    try testing.expect(!matches("^[a-z0-9]+$", "AbC123", testing_cpu_features));
    try testing.expect(matches("^[\\x00-\\x7F]+$", "plain ascii", testing_cpu_features));
    try testing.expect(!matches("^[\\x00-\\x7F]+$", "caf\u{e9}", testing_cpu_features));
    try testing.expect(matches("\\* \\\\ \\w", "* \\ x", testing_cpu_features));
    try testing.expect(!matches("\\* \\\\ \\w", "* \\ .", testing_cpu_features));
}

test "a short text and a long one get RE2's answers" {
    const pattern = "^[A-Z][a-z]+( [A-Z][a-z]+)*$";
    try testing.expect(matches(pattern, "Ada Lovelace Byron King Noel Milbanke Gordon", testing_cpu_features));
    try testing.expect(!matches(pattern, "Ada Lovelace Byron King Noel milbanke Gordon", testing_cpu_features));
    try testing.expect(matches(pattern, "Ada", testing_cpu_features));
    try testing.expect(!matches(pattern, "ada", testing_cpu_features));
    try testing.expect(matches("king$", "Ada Lovelace Byron king", testing_cpu_features));
}

test "a named group, as RE2 writes it, is a group" {
    const date = "^(?P<year>[0-9]{4})-(?<month>[0-9]{2})$";
    try testing.expect(comptime problem_of(date) == null);
    try testing.expect(matches(date, "2026-11", testing_cpu_features));
    try testing.expect(!matches(date, "2026-1", testing_cpu_features));
    try testing.expect(matches("(?P<word>[a-z]+)+!", "ab!", testing_cpu_features));
    // A group's name is a word, as Go's regexp checks it.
    try testing.expect(comptime problem_of("(?P<>a)") != null);
    try testing.expect(comptime problem_of("(?P<a-b>a)") != null);
}

test "an octet that is not UTF-8 matches nothing" {
    try testing.expect(!matches("^.$", "\xff", testing_cpu_features));
    try testing.expect(matches("a", "\xffa", testing_cpu_features));
}

test "a pattern that stdx refuses is a problem that names it" {
    try testing.expect(comptime problem_of("^[a-z]+$") == null);
    try testing.expectEqualStrings("stdx's regular expressions refuse the pattern `\\p{Nothing}`: InvalidProperty", comptime problem_of("\\p{Nothing}").?);
}

test "a pattern reads Unicode's properties, and folds case past ASCII" {
    try testing.expect(matches("^\\p{Greek}+$", "\u{3b1}\u{3b2}\u{3b3}", testing_cpu_features));
    try testing.expect(!matches("^\\p{Greek}+$", "abc", testing_cpu_features));
    try testing.expect(matches("^\\pL+$", "caf\u{e9}", testing_cpu_features));
    try testing.expect(!matches("^\\pL+$", "caf\u{e9}1", testing_cpu_features));
    try testing.expect(matches("^[\\P{Lu}]+$", "abc", testing_cpu_features) and !matches("^\\P{Lu}+$", "aBc", testing_cpu_features));
    // (?i) folds by Unicode's simple case folding, as Go's regexp does: k folds with U+212A.
    try testing.expect(matches("^(?i)k$", "\u{212a}", testing_cpu_features) and matches("^(?i)\u{e9}$", "\u{c9}", testing_cpu_features));
}

/// The answer of a searcher made ready for `text` alone.
fn fresh(comptime pattern: []const u8, text: []const u8, with: platform.CpuFeatures) bool {
    const Kept = Searcher(pattern);
    var memory: @TypeOf(Kept.memory) = undefined;
    var searcher: regex.Searcher = undefined;
    searcher.init(&Kept.program, &.{ .features = with }, &memory);
    return searcher.is_match(text);
}

test "a kept searcher gives each text the answer a fresh one gives" {
    const pattern = "^[A-Z][a-z]+( [A-Z][a-z]+)*$";
    const texts = [_][]const u8{ "Ada", "ada", "Ada Lovelace", "Ada lovelace", "", "Ada Lovelace Byron", "A", "Ab Cd Ef Gh", "Ada  Byron" };
    // Twice over, so the second pass reads the states the first one built.
    for (0..2) |_| {
        for (texts) |text| try testing.expectEqual(fresh(pattern, text, testing_cpu_features), matches(pattern, text, testing_cpu_features));
    }
    // Another pattern keeps a searcher of its own.
    try testing.expect(matches("^[a-z]+$", "ada", testing_cpu_features) and !matches(pattern, "ada", testing_cpu_features) and !matches("^[a-z]+$", "Ada", testing_cpu_features));
}

test "a check searches with the features its caller passes" {
    const pattern = "^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$";
    const texts = [_][]const u8{ "ada@example.com", "ada@example", "ada.lovelace+notes@mail.example.org", "@example.com" };
    // Each set the CPU has: none, the build target's, and the detected one, which may name AVX2.
    const sets = [_]platform.CpuFeatures{ platform.CpuFeatures.none(), platform.CpuFeatures.target(), platform.CpuFeatures.detect() };
    for (sets) |set| {
        for (texts) |text| try testing.expectEqual(fresh(pattern, text, set), matches(pattern, text, set));
        try testing.expect(std.meta.eql(kept_cpu_features(pattern), @as(?platform.CpuFeatures, set)));
        // The features reach the searcher: its forward DFA takes the paths a fresh one's takes.
        const Kept = Searcher(pattern);
        var memory: @TypeOf(Kept.memory) = undefined;
        var other: regex.Searcher = undefined;
        other.init(&Kept.program, &.{ .features = set }, &memory);
        try testing.expect(std.meta.eql(Kept.searcher.forward.config, other.forward.config));
    }
    try testing.expect(kept_cpu_features("^never checked$") == null);
}
