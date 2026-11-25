//! The validation benchmark's Zig program (tools/validate_compare_check.sh): connect-zig's
//! protovalidate over the schema of bench/validate/proto.
//!
//!     bench-validate [--quick] [--only <case>] <directory>
//!     bench-validate --instructions
//!
//! The directory holds one encoded message for each case of bench/validate/cases, as
//! `<case>.binpb`, which the check writes from the case's JSON with `buf convert`. For each case
//! the program times two things, the median nanoseconds of one call of each: `validate` of the
//! message decoded once, and the decode of its octets with `validate` of what it gives, which a
//! server runs for each request. The decode is `decode_into`, as `connect_colibri` decodes a
//! request into its route's storage (decision 37): each repeated field and each map is read once,
//! into elements that `validate` then reads in place, as another implementation's decode builds
//! its lists and maps. It prints
//! a row for each case with the verdict, which each other implementation's program prints too:
//! "valid", or "invalid:" and the rule ids of the violations in order. `--only` runs one case,
//! as "rules valid", for a profile of it.
//!
//! `--counters` reads the same directory, and counts what each thing it times takes on the CPU,
//! through Linux's hardware counters (`counters.zig`): cycles, instructions, branches and branch
//! misses for one call, over `counter_runs` calls. A host with no counters gets a line that says
//! so, and the program ends with no failure.
//!
//! `--instructions` times nothing and reads no file. It decodes each case's JSON, which the
//! program holds, encodes it, and under callgrind collects `instruction_iterations` runs of
//! each thing it times, dumped as "validate <case>" and "decode and validate <case>", which
//! tools/perf_check.sh reads.
//!
//! This is a program, not the library: it reads the clock and files through `init.io`.
const std = @import("std");
const proto = @import("protobuf");
/// The benchmark decodes and encodes with the build target's CPU features, so that
/// `tools/perf_check.sh` counts the same paths on every machine of an architecture.
const protobuf_decoder: proto.Decoder = .init(.target());
const protovalidate = @import("protovalidate");
const platform = @import("stdx").platform;
const schema = @import("bench_validate_v1");
const measure = @import("measure.zig");
const constants = @import("constants.zig");
const counters = @import("counters.zig");

const full: measure.Settings = .{ .runs = constants.full_runs, .batch_ns = constants.full_batch_ns };
const quick: measure.Settings = .{ .runs = constants.quick_runs, .batch_ns = constants.quick_batch_ns };

/// Each case: its name, the stem of its files, and the message's type.
const Case = struct { name: []const u8, stem: []const u8, Message: type };

const cases = [_]Case{
    .{ .name = "small valid", .stem = "small_valid", .Message = schema.Small },
    .{ .name = "small invalid", .stem = "small_invalid", .Message = schema.Small },
    .{ .name = "medium valid", .stem = "medium_valid", .Message = schema.Medium },
    .{ .name = "medium invalid", .stem = "medium_invalid", .Message = schema.Medium },
    .{ .name = "rules valid", .stem = "rules_valid", .Message = schema.Rules },
    .{ .name = "rules invalid", .stem = "rules_invalid", .Message = schema.Rules },
};

/// The runs of each thing `--instructions` counts. tools/perf_check.sh divides by the same.
pub const instruction_iterations = 16;
/// The calls of each thing `--counters` counts: about 10 ms of the slowest case.
const counter_runs = 100_000;
/// The octets of one JSON token of a case, at most.
const token_len = 1024;

/// The octets of one case's encoded message, at most.
const message_len_max = 4096;
/// The octets of the violations of one message, at most.
const report_len = 16_384;
/// The octets `decode_into` reads one message's repeated fields and maps into, at most.
const storage_len = 16_384;
/// The violations of one message whose rule ids the verdict names, at most.
const violations_max = 32;
/// The octets of a verdict, at most.
const verdict_len_max = 1024;

/// All the program holds, which `main` allocates once before the first case (decision 42).
const State = struct {
    message: [message_len_max]u8,
    report_storage: [report_len]u8 align(@alignOf(protovalidate.Violation)),
    storage: [storage_len]u8 align(@alignOf(u64)),
    transcoded: [message_len_max]u8,
    tokens: [token_len]u8,
    verdict: [verdict_len_max]u8,
    ids: [violations_max][]const u8,
    path: [constants.path_len]u8,
    output: [constants.output_len]u8 align(constants.buffer_align),
    /// The CPU features each validation's regular expressions search with, which `main` sets.
    cpu_features: platform.CpuFeatures,
};

/// What the command line asks for.
const Options = struct {
    settings: measure.Settings = full,
    directory: ?[]const u8 = null,
    only: ?[]const u8 = null,
    instructions: bool = false,
    counters: bool = false,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    const options = try parse(init.minimal.args);
    // The count takes the build target's features, x86-64-v3's for tools/perf_check.sh, so every
    // machine counts the same paths. A timed run detects the CPU once, as a program does.
    state.cpu_features = if (options.instructions) .target() else .detect();
    if (options.instructions) {
        inline for (cases) |case| try count_case(state, case);
        return;
    }
    const folder = options.directory orelse {
        std.debug.print("usage: bench-validate [--quick | --counters] [--only <case>] <directory> | --instructions\n", .{});
        return error.Usage;
    };
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &state.output);
    const writer = &stdout.interface;
    if (options.counters) return count_cases(init.io, state, options, folder, writer);
    try writer.writeAll("| case | verdict | validate ns/op | decode and validate ns/op |\n| --- | --- | ---: | ---: |\n");
    inline for (cases) |case| {
        if (options.only == null or std.mem.eql(u8, options.only.?, case.name)) {
            try run_case(init.io, state, options.settings, folder, case, writer);
        }
    }
    try writer.flush();
}

fn parse(args: std.process.Args) !Options {
    var options: Options = .{};
    var arguments = args.iterate();
    _ = arguments.skip();
    for (0..constants.arguments_max) |_| {
        const argument = arguments.next() orelse break;
        if (std.mem.eql(u8, argument, "--quick")) {
            options.settings = quick;
        } else if (std.mem.eql(u8, argument, "--instructions")) {
            options.instructions = true;
        } else if (std.mem.eql(u8, argument, "--counters")) {
            options.counters = true;
        } else if (std.mem.eql(u8, argument, "--only")) {
            options.only = arguments.next() orelse return error.Usage;
        } else options.directory = argument;
    }
    return options;
}

/// Decodes one case's message, writes its verdict, and times `validate` of it.
fn run_case(io: std.Io, state: *State, settings: measure.Settings, folder: []const u8, comptime case: Case, writer: *std.Io.Writer) !void {
    const path = try std.fmt.bufPrint(&state.path, "{s}/{s}.binpb", .{ folder, case.stem });
    const bytes = try std.Io.Dir.cwd().readFile(io, path, &state.message);
    if (bytes.len == state.message.len) return error.MessageTooLarge;
    const message = try protobuf_decoder.decode_into(case.Message, bytes, &state.storage);
    const verdict = try verdict_of(case.Message, state, &message);
    const runner: Runner(case.Message) = .{ .message = &message, .storage = &state.report_storage, .options = .{ .cpu_features = state.cpu_features } };
    const validate_ns = try measure.median_ns(io, settings, runner);
    const both: BothRunner(case.Message) = .{ .bytes = bytes, .storage = &state.report_storage, .elements = &state.storage, .options = .{ .cpu_features = state.cpu_features } };
    const both_ns = try measure.median_ns(io, settings, both);
    try writer.print("| {s} | {s} | {d:.1} | {d:.1} |\n", .{ case.name, verdict, validate_ns, both_ns });
    try writer.flush();
}

/// Decodes the octets of one message and validates what they give, `n` times.
fn BothRunner(comptime M: type) type {
    return struct {
        bytes: []const u8,
        storage: []align(@alignOf(protovalidate.Violation)) u8,
        elements: []u8,
        options: protovalidate.Options,

        pub fn run(runner: @This(), n: u64) !void {
            for (0..n) |_| {
                var bytes = runner.bytes;
                std.mem.doNotOptimizeAway(&bytes);
                const message = try protobuf_decoder.decode_into(M, bytes, runner.elements);
                var report: protovalidate.Report = .init(runner.storage);
                const result = protovalidate.validate(M, &message, runner.options, &report);
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
        options: protovalidate.Options,

        pub fn run(runner: @This(), n: u64) !void {
            for (0..n) |_| {
                var report: protovalidate.Report = .init(runner.storage);
                const result = protovalidate.validate(M, runner.message, runner.options, &report);
                std.mem.doNotOptimizeAway(&report);
                result catch |failure| if (failure != error.Invalid) return failure;
            }
        }
    };
}

/// "valid", or "invalid:" and the rule id of each violation, in order, with commas between them.
fn verdict_of(comptime M: type, state: *State, message: *const M) ![]const u8 {
    var report: protovalidate.Report = .init(&state.report_storage);
    protovalidate.validate(M, message, .{ .cpu_features = state.cpu_features }, &report) catch |failure| switch (failure) {
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

/// Counts the instructions of one case under callgrind: `validate` of the message decoded once,
/// and the decode of its octets with `validate` of what it gives, after one run of each that
/// warms them. The case's octets are the encoding of its JSON, which the program holds.
fn count_case(state: *State, comptime case: Case) !void {
    const json = @embedFile("validate/cases/" ++ case.stem ++ ".json");
    const decoded = try protobuf_decoder.decode_json(case.Message, json, &state.transcoded, &state.tokens);
    const bytes = try proto.encode(case.Message, &decoded, &state.message);
    const message = try protobuf_decoder.decode_into(case.Message, bytes, &state.storage);
    const runner: Runner(case.Message) = .{ .message = &message, .storage = &state.report_storage, .options = .{ .cpu_features = state.cpu_features } };
    try collect("validate " ++ case.name, runner);
    // `message` is done with: the decodes write their elements where it stood.
    const both: BothRunner(case.Message) = .{ .bytes = bytes, .storage = &state.report_storage, .elements = &state.storage, .options = .{ .cpu_features = state.cpu_features } };
    try collect("decode and validate " ++ case.name, both);
}

fn collect(comptime label: []const u8, runner: anytype) !void {
    try runner.run(1);
    const callgrind = std.valgrind.callgrind;
    callgrind.toggleCollect();
    try runner.run(instruction_iterations);
    callgrind.toggleCollect();
    // callgrind reads the label up to its zero octet.
    callgrind.dumpStatsAt(@ptrCast(label ++ "\x00"));
}

/// `--counters`: the table of what each case's two operations take on the CPU, or a line that
/// says the host has no counters.
fn count_cases(io: std.Io, state: *State, options: Options, folder: []const u8, writer: *std.Io.Writer) !void {
    var refusal: []const u8 = "the host is not Linux";
    const opened = if (comptime counters.available) counters.Counters.open(&refusal) else error.Unavailable;
    const counted = opened catch {
        try writer.print("No hardware counters on this host: {s}.\n", .{refusal});
        return writer.flush();
    };
    try writer.writeAll("| case | operation | cycles | instructions | instructions a cycle | branches | branch misses |\n");
    try writer.writeAll("| --- | --- | ---: | ---: | ---: | ---: | ---: |\n");
    inline for (cases) |case| {
        if (options.only == null or std.mem.eql(u8, options.only.?, case.name)) {
            const path = try std.fmt.bufPrint(&state.path, "{s}/{s}.binpb", .{ folder, case.stem });
            const bytes = try std.Io.Dir.cwd().readFile(io, path, &state.message);
            if (bytes.len == state.message.len) return error.MessageTooLarge;
            const message = try protobuf_decoder.decode_into(case.Message, bytes, &state.storage);
            const runner: Runner(case.Message) = .{ .message = &message, .storage = &state.report_storage, .options = .{ .cpu_features = state.cpu_features } };
            try write_counts(writer, case.name, "validate", &counted, runner);
            // `message` is done with: the decodes write their elements where it stood.
            const both: BothRunner(case.Message) = .{ .bytes = bytes, .storage = &state.report_storage, .elements = &state.storage, .options = .{ .cpu_features = state.cpu_features } };
            try write_counts(writer, case.name, "decode and validate", &counted, both);
        }
    }
    try writer.flush();
}

/// One row: the counts of `counter_runs` calls of `runner`, after one that warms it, for one call.
fn write_counts(writer: *std.Io.Writer, name: []const u8, operation: []const u8, counted: *const counters.Counters, runner: anytype) !void {
    try runner.run(1);
    counted.start();
    try runner.run(counter_runs);
    const counts = counted.stop();
    const runs: f64 = @floatFromInt(counter_runs);
    const per_call = struct {
        fn of(count: u64, calls: f64) f64 {
            return @as(f64, @floatFromInt(count)) / calls;
        }
    }.of;
    const cycles = per_call(counts[counters.cycles], runs);
    const instructions = per_call(counts[counters.instructions], runs);
    const ratio = if (cycles == 0) 0 else instructions / cycles;
    try writer.print("| {s} | {s} | {d:.1} | {d:.1} | {d:.2} | {d:.1} | {d:.2} |\n", .{ name, operation, cycles, instructions, ratio, per_call(counts[counters.branches], runs), per_call(counts[counters.branch_misses], runs) });
}
