//! The validation benchmark's Zig program (tools/validate_compare_check.sh): connect-zig's
//! protovalidate over the schema of bench/validate/proto.
//!
//!     bench-validate [--quick] <directory>
//!
//! The directory holds one encoded message for each case of bench/validate/cases, as
//! `<case>.binpb`, which the check writes from the case's JSON with `buf convert`. For each case
//! the program times two things, the median nanoseconds of one call of each: `validate` of the
//! message decoded once, and the decode of its octets with `validate` of what it gives, which a
//! server runs for each request. A repeated field and a map are views of the octets here, so
//! `validate` reads them as it runs, where another implementation's decode built them. It prints
//! a row for each case with the verdict, which each other implementation's program prints too:
//! "valid", or "invalid:" and the rule ids of the violations in order.
//!
//! This is a program, not the library: it reads the clock and files through `init.io`.
const std = @import("std");
const proto = @import("protobuf");
const protovalidate = @import("protovalidate");
const schema = @import("bench_validate_v1");
const measure = @import("measure.zig");
const constants = @import("constants.zig");

const full: measure.Settings = .{ .runs = constants.full_runs, .batch_ns = constants.full_batch_ns };
const quick: measure.Settings = .{ .runs = constants.quick_runs, .batch_ns = constants.quick_batch_ns };

/// Each case: its name, the file of its message, and the message's type.
const Case = struct { name: []const u8, file: []const u8, Message: type };

const cases = [_]Case{
    .{ .name = "small valid", .file = "small_valid.binpb", .Message = schema.Small },
    .{ .name = "small invalid", .file = "small_invalid.binpb", .Message = schema.Small },
    .{ .name = "medium valid", .file = "medium_valid.binpb", .Message = schema.Medium },
    .{ .name = "medium invalid", .file = "medium_invalid.binpb", .Message = schema.Medium },
    .{ .name = "rules valid", .file = "rules_valid.binpb", .Message = schema.Rules },
    .{ .name = "rules invalid", .file = "rules_invalid.binpb", .Message = schema.Rules },
};

/// The octets of one case's encoded message, at most.
const message_len_max = 4096;
/// The octets of the violations of one message, at most.
const report_len = 16_384;
/// The violations of one message whose rule ids the verdict names, at most.
const violations_max = 32;
/// The octets of a verdict, at most.
const verdict_len_max = 1024;

/// All the program holds, which `main` allocates once before the first case (decision 42).
const State = struct {
    message: [message_len_max]u8,
    report_storage: [report_len]u8 align(@alignOf(protovalidate.Violation)),
    verdict: [verdict_len_max]u8,
    ids: [violations_max][]const u8,
    path: [constants.path_len]u8,
    output: [constants.output_len]u8 align(constants.buffer_align),
};

pub fn main(init: std.process.Init) !void {
    const state = try init.arena.allocator().create(State);
    var settings = full;
    var directory: ?[]const u8 = null;
    var arguments = init.minimal.args.iterate();
    _ = arguments.skip();
    for (0..constants.arguments_max) |_| {
        const argument = arguments.next() orelse break;
        if (std.mem.eql(u8, argument, "--quick")) {
            settings = quick;
        } else directory = argument;
    }
    const folder = directory orelse {
        std.debug.print("usage: bench-validate [--quick] <directory>\n", .{});
        return error.Usage;
    };
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &state.output);
    const writer = &stdout.interface;
    try writer.writeAll("| case | verdict | validate ns/op | decode and validate ns/op |\n| --- | --- | ---: | ---: |\n");
    inline for (cases) |case| try run_case(init.io, state, settings, folder, case, writer);
    try writer.flush();
}

/// Decodes one case's message, writes its verdict, and times `validate` of it.
fn run_case(io: std.Io, state: *State, settings: measure.Settings, folder: []const u8, comptime case: Case, writer: *std.Io.Writer) !void {
    const path = try std.fmt.bufPrint(&state.path, "{s}/{s}", .{ folder, case.file });
    const bytes = try std.Io.Dir.cwd().readFile(io, path, &state.message);
    if (bytes.len == state.message.len) return error.MessageTooLarge;
    const message = try proto.decode(case.Message, bytes);
    const verdict = try verdict_of(case.Message, state, &message);
    const runner: Runner(case.Message) = .{ .message = &message, .storage = &state.report_storage };
    const validate_ns = try measure.median_ns(io, settings, runner);
    const both: BothRunner(case.Message) = .{ .bytes = bytes, .storage = &state.report_storage };
    const both_ns = try measure.median_ns(io, settings, both);
    try writer.print("| {s} | {s} | {d:.1} | {d:.1} |\n", .{ case.name, verdict, validate_ns, both_ns });
    try writer.flush();
}

/// Decodes the octets of one message and validates what they give, `n` times.
fn BothRunner(comptime M: type) type {
    return struct {
        bytes: []const u8,
        storage: []align(@alignOf(protovalidate.Violation)) u8,

        pub fn run(runner: @This(), n: u64) !void {
            for (0..n) |_| {
                var bytes = runner.bytes;
                std.mem.doNotOptimizeAway(&bytes);
                const message = try proto.decode(M, bytes);
                var report: protovalidate.Report = .init(runner.storage);
                const result = protovalidate.validate(M, &message, .{}, &report);
                std.mem.doNotOptimizeAway(&report);
                result catch |failure| if (failure != error.Invalid) return failure;
            }
        }
    };
}

/// Validates one message `n` times, each time into a report of its own.
fn Runner(comptime M: type) type {
    return struct {
        message: *const M,
        storage: []align(@alignOf(protovalidate.Violation)) u8,

        pub fn run(runner: @This(), n: u64) !void {
            for (0..n) |_| {
                var report: protovalidate.Report = .init(runner.storage);
                const result = protovalidate.validate(M, runner.message, .{}, &report);
                std.mem.doNotOptimizeAway(&report);
                result catch |failure| if (failure != error.Invalid) return failure;
            }
        }
    };
}

/// "valid", or "invalid:" and the rule id of each violation, in order, with commas between them.
fn verdict_of(comptime M: type, state: *State, message: *const M) ![]const u8 {
    var report: protovalidate.Report = .init(&state.report_storage);
    protovalidate.validate(M, message, .{}, &report) catch |failure| switch (failure) {
        error.Invalid => {},
        else => return failure,
    };
    const violations = report.violations();
    if (violations.len == 0) return "valid";
    if (violations.len > violations_max) return error.TooManyViolations;
    const ids = state.ids[0..violations.len];
    for (violations, ids) |violation, *id| id.* = violation.rule_id orelse "";
    std.mem.sort([]const u8, ids, {}, less);
    var writer: std.Io.Writer = .fixed(&state.verdict);
    try writer.writeAll("invalid:");
    for (ids, 0..) |id, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll(id);
    }
    return writer.buffered();
}

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
