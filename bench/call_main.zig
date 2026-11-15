//! The routed calls' benchmark: a unary call of the small and of the medium message, in Connect
//! and in gRPC, through `connect_colibri`'s route on colibri's router (bench/call.zig). It prints
//! the rows of bench/main.zig's table, in the same columns: a call's bytes are its request
//! body's.
//!
//! It is a program apart from bench/main.zig. The compiler lays out and inlines a program as a
//! whole, and in one program with the routed calls the codec's own counts moved: small binary
//! encode took 9% more instructions with no change to the library (docs/performance.md).
//!
//! `zig build bench` runs it after bench/main.zig, with the same flags:
//!
//! - `--quick` takes 3 short batches a call instead of 11 long ones: a smoke test.
//! - `--write <dir>` writes each call's reply to `<dir>/<message>.<protocol>.reply`, which
//!   tools/bench_check.sh compares with Go's and Rust's.
//! - `--instructions` times nothing. Under callgrind it collects `instruction_iterations` calls
//!   and dumps the count under "<message> <call>", which tools/perf_check.sh reads.
//!
//! This is a program, not the library: it reads the clock and writes files through `init.io`.
const std = @import("std");
const bench = @import("bench_v1");
const inputs = @import("inputs.zig");
const call = @import("call.zig");
const measure = @import("measure.zig");
const constants = @import("constants.zig");

const full: measure.Settings = .{ .runs = constants.full_runs, .batch_ns = constants.full_batch_ns };
const quick: measure.Settings = .{ .runs = constants.quick_runs, .batch_ns = constants.quick_batch_ns };

/// The calls whose instructions `--instructions` counts, as bench/main.zig counts its runs.
pub const instruction_iterations = 16;
/// Bytes per MB, which MB/s counts in.
const bytes_per_megabyte = 1_000_000;

const Options = struct {
    settings: measure.Settings = full,
    write_directory: ?[]const u8 = null,
    instructions: bool = false,
};

/// All the program holds, which `main` allocates once before the first call (decision 42).
const State = struct {
    messages: inputs.Messages,
    small_calls: call.Calls(bench.Small, "Small"),
    medium_calls: call.Calls(bench.Medium, "Medium"),
    output: [constants.output_len]u8 align(constants.buffer_align),
};

const Context = struct {
    io: std.Io,
    writer: *std.Io.Writer,
    options: Options,
};

pub fn main(init: std.process.Init) !void {
    const state = try init.arena.allocator().create(State);
    const options = try parse(init.minimal.args);
    state.messages.build();
    var stdout = std.Io.File.stdout().writer(init.io, &state.output);
    const writer = &stdout.interface;
    const context: Context = .{ .io = init.io, .writer = writer, .options = options };
    try writer.print("| message | operation | bytes | ns/op | MB/s |\n| --- | --- | ---: | ---: | ---: |\n", .{});
    try state.small_calls.prepare(&inputs.small);
    try run_calls(context, "small", &state.small_calls.exchange);
    try state.medium_calls.prepare(&state.messages.medium);
    try run_calls(context, "medium", &state.medium_calls.exchange);
    try writer.flush();
}

fn parse(args: std.process.Args) !Options {
    var options: Options = .{};
    var arguments = args.iterate();
    _ = arguments.skip();
    for (0..constants.arguments_max) |_| {
        const argument = arguments.next() orelse return options;
        if (std.mem.eql(u8, argument, "--quick")) {
            options.settings = quick;
        } else if (std.mem.eql(u8, argument, "--instructions")) {
            options.instructions = true;
        } else if (std.mem.eql(u8, argument, "--write")) {
            options.write_directory = arguments.next() orelse return error.MissingDirectory;
        } else {
            std.debug.print("usage: bench-call [--quick] [--instructions] [--write <dir>]\n", .{});
            return error.UnknownArgument;
        }
    }
    return error.TooManyArguments;
}

/// Times or counts each protocol's routed call of one message, and writes its reply under
/// `--write`. It, `count_instructions` and `Exchange.call` stay out of line: inlined into `main`
/// with the router, they made one function whose jump tables LLVM failed to encode on CI's arm64
/// runner ("fixup value out of range").
noinline fn run_calls(context: Context, name: []const u8, exchange: *call.Exchange) !void {
    for (std.enums.values(call.Protocol)) |protocol| {
        if (context.options.write_directory) |directory| {
            try write_reply(context.io, directory, name, protocol, try exchange.reply_of(protocol));
        }
        const runner = exchange.runner(protocol);
        if (context.options.instructions) {
            try count_instructions(name, protocol.label(), runner);
            continue;
        }
        const ns = try measure.median_ns(context.io, context.options.settings, runner);
        const bytes = exchange.bytes(protocol);
        const megabytes_per_second = @as(f64, @floatFromInt(bytes)) / ns * std.time.ns_per_s / bytes_per_megabyte;
        try context.writer.print("| {s} | {s} | {d} | {d:.1} | {d:.1} |\n", .{ name, protocol.label(), bytes, ns, megabytes_per_second });
        try context.writer.flush();
    }
}

/// Collects the instructions of `instruction_iterations` calls, after one call that warms them,
/// and dumps them under "<message> <call>".
noinline fn count_instructions(name: []const u8, label: []const u8, runner: call.Runner) !void {
    try runner.run(1);
    const callgrind = std.valgrind.callgrind;
    callgrind.toggleCollect();
    try runner.run(instruction_iterations);
    callgrind.toggleCollect();
    var dump_label: [constants.label_len]u8 = @splat(0);
    _ = try std.fmt.bufPrint(dump_label[0 .. constants.label_len - 1], "{s} {s}", .{ name, label });
    callgrind.dumpStatsAt(@ptrCast(&dump_label));
}

/// Writes a call's reply to `<directory>/<message>.<protocol>.reply`.
fn write_reply(io: std.Io, directory: []const u8, name: []const u8, protocol: call.Protocol, reply: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory);
    var path: [constants.path_len]u8 = @splat(0);
    const sub_path = try std.fmt.bufPrint(&path, "{s}/{s}.{s}", .{ directory, name, protocol.file_suffix() });
    try cwd.writeFile(io, .{ .sub_path = sub_path, .data = reply });
}
