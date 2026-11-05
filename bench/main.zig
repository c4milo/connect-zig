//! The protobuf runtime's benchmark: binary and JSON, encode and decode, on four messages from
//! bench/proto. It prints one Markdown table: the bytes each operation reads or writes, the
//! median nanoseconds of one operation, and MB/s (10^6 bytes a second).
//!
//! Run it with `zig build bench`, which builds it ReleaseFast. Flags:
//!
//! - `--quick` takes 3 short batches an operation instead of 11 long ones: a smoke test.
//! - `--write <dir>` writes each message's binary encoding to `<dir>/<name>.bin` and its walk sum
//!   to `<dir>/<name>.sum`, which tools/bench_check.sh compares with Go's.
//! - `--instructions` times nothing. Under `valgrind --tool=callgrind --collect-atstart=no`, it
//!   collects around `instruction_iterations` runs of each operation and dumps the count under
//!   the operation's name, which tools/perf_check.sh reads. Outside valgrind it does nothing.
//!
//! Decoding copies nothing: a decoded string or bytes field points into the input, and a repeated
//! or recursive field is decoded when a program reads it. "binary decode" times that first step
//! alone. "decode+walk" also reads every field, which is the work Go's `proto.Unmarshal` does.
//!
//! This is a program, not the library: it reads the clock and writes files through `init.io`.
const std = @import("std");
const proto = @import("protobuf");
const bench = @import("bench_v1");
const inputs = @import("inputs.zig");
const walk = @import("walk.zig");
const cases = @import("cases.zig");
const measure = @import("measure.zig");

const Operation = cases.Operation;

const full: measure.Settings = .{ .runs = 11, .batch_ns = 20 * std.time.ns_per_ms };
const quick: measure.Settings = .{ .runs = 3, .batch_ns = std.time.ns_per_ms };

/// The runs of each operation whose instructions `--instructions` counts.
pub const instruction_iterations = 16;
/// Room for "<message> <operation>" and its terminating zero.
const label_len = 64;

/// The most arguments the program reads.
const arguments_max = 8;
const output_len = 16 * 1024;
const path_len = 4096;
/// Bytes per MB, which MB/s counts in.
const bytes_per_megabyte = 1_000_000;

const Options = struct {
    settings: measure.Settings = full,
    write_directory: ?[]const u8 = null,
    instructions: bool = false,
};

var output: [output_len]u8 align(16) = undefined;

pub fn main(init: std.process.Init) !void {
    const options = try parse(init.minimal.args);
    inputs.build();
    var stdout = std.Io.File.stdout().writer(init.io, &output);
    const writer = &stdout.interface;
    const context: Context = .{ .io = init.io, .writer = writer, .options = options };
    try writer.print("| message | operation | bytes | ns/op | MB/s |\n| --- | --- | ---: | ---: | ---: |\n", .{});
    try run_message(context, bench.Small, walk.small, "small", &inputs.small);
    try run_message(context, bench.Medium, walk.medium, "medium", &inputs.medium);
    try run_message(context, bench.Large, walk.large, "large", &inputs.large);
    try run_message(context, bench.Deep, walk.deep, "deep", inputs.deep());
    try writer.flush();
}

const Context = struct {
    io: std.Io,
    writer: *std.Io.Writer,
    options: Options,
};

fn parse(args: std.process.Args) !Options {
    var options: Options = .{};
    var arguments = args.iterate();
    _ = arguments.skip();
    for (0..arguments_max) |_| {
        const argument = arguments.next() orelse return options;
        if (std.mem.eql(u8, argument, "--quick")) {
            options.settings = quick;
        } else if (std.mem.eql(u8, argument, "--instructions")) {
            options.instructions = true;
        } else if (std.mem.eql(u8, argument, "--write")) {
            options.write_directory = arguments.next() orelse return error.MissingDirectory;
        } else {
            std.debug.print("usage: bench [--quick] [--instructions] [--write <dir>]\n", .{});
            return error.UnknownArgument;
        }
    }
    return error.TooManyArguments;
}

fn run_message(
    context: Context,
    comptime T: type,
    comptime walk_message: fn (*const T) proto.Error!u64,
    name: []const u8,
    input: *const T,
) !void {
    const case = try cases.Case(T, walk_message).prepare(input);
    if (context.options.write_directory) |directory| try write_outputs(context.io, directory, name, case.binary, case.sum);
    for (std.enums.values(Operation)) |operation| {
        if (context.options.instructions) {
            try count_instructions(name, operation, case.runner(operation));
            continue;
        }
        const ns = try measure.median_ns(context.io, context.options.settings, case.runner(operation));
        const bytes = case.bytes(operation);
        const megabytes_per_second = @as(f64, @floatFromInt(bytes)) / ns * std.time.ns_per_s / bytes_per_megabyte;
        try context.writer.print("| {s} | {s} | {d} | {d:.1} | {d:.1} |\n", .{ name, operation.label(), bytes, ns, megabytes_per_second });
        try context.writer.flush();
    }
}

/// Collects the instructions of `instruction_iterations` runs of one operation, after one run that
/// warms it, and dumps them under "<message> <operation>".
fn count_instructions(name: []const u8, operation: Operation, runner: anytype) !void {
    try runner.run(1);
    const callgrind = std.valgrind.callgrind;
    callgrind.toggleCollect();
    try runner.run(instruction_iterations);
    callgrind.toggleCollect();
    var label: [label_len]u8 = @splat(0);
    _ = try std.fmt.bufPrint(label[0 .. label_len - 1], "{s} {s}", .{ name, operation.label() });
    callgrind.dumpStatsAt(@ptrCast(&label));
}

fn write_outputs(io: std.Io, directory: []const u8, name: []const u8, binary: []const u8, sum: u64) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory);
    var path: [path_len]u8 = @splat(0);
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path, "{s}/{s}.bin", .{ directory, name }), .data = binary });
    var text: [std.fmt.count("{d}\n", .{std.math.maxInt(u64)})]u8 = @splat(0);
    const sum_text = try std.fmt.bufPrint(&text, "{d}\n", .{sum});
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path, "{s}/{s}.sum", .{ directory, name }), .data = sum_text });
}
