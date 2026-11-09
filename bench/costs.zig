//! The costs table of docs/performance.md, timed on the machine that runs it: a first-level cache
//! hit, a main-memory read, a branch mispredict, a copy and a system call. Run it with
//! `zig build costs`, which builds it ReleaseFast. It prints one Markdown table: each cost's
//! median over `runs` runs, in nanoseconds, and the spread, the slowest run less the fastest as a
//! share of the median (pepegrillo's performance method, step 1).
//!
//! - A cache hit and a memory read chase pointers through a cyclic permutation of cache lines,
//!   so each load waits on the one before and the prefetcher cannot guess the next line. The
//!   memory read's buffer is far past any last-level cache; its cost includes a TLB miss.
//! - A mispredict times a branch over random bits against the same branch over sorted bits, and
//!   divides the difference by the mispredicts the random bits cause, half of them. One arm holds
//!   a volatile `asm`, so LLVM keeps the branch and does not use a select.
//! - A copy is one `@memcpy` of `copy_len` octets between buffers the second-level cache holds.
//! - A system call is `getpid`, which the kernel answers at once.
//!
//! This is a program, not the library: it reads the clock and makes system calls.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The runs of each cost; their median is the cost, as the method asks.
const runs = 5;
/// The octets of a cache line, which the chases step by.
const line_len = 64;
/// The chase that stays in the first-level cache: 16 KiB, half of the smallest such cache CI has.
const hit_buffer_len = 16 * 1024;
/// The chase that reads main memory: 256 MiB, past any runner's last-level cache.
const memory_buffer_len = 256 * 1024 * 1024;
/// The loads of one timed chase.
const chase_steps = 1 << 22;
/// The bits one timed branch loop reads.
const branch_bits_count = 1 << 16;
/// Each branch loop runs this many times over its bits.
const branch_rounds = 64;
/// A random bit is mispredicted half the time.
const mispredicts_per_bit = 0.5;
/// The octets one copy moves, and how many copies are timed.
const copy_len = 64 * 1024;
const copy_rounds = 4096;
/// The system calls one run times.
const syscall_calls = 100_000;
/// The seed of the generator that orders the chase and draws the random bits.
const seed = 0x9e37_79b9_7f4a_7c15;
/// The least a mispredict costs on any core CI runs: about ten cycles. Less means the branch
/// became a select and nothing was measured, so the row is marked suspect. The table reports and
/// never gates (the owner's ruling of 2026-11-09).
const mispredict_ns_min = 1.0;
const output_len = 4096;
const percent = 100;

const Cost = struct {
    name: []const u8,
    unit: []const u8,
    measure: *const fn (*Buffers, std.Io) anyerror!f64,
    /// The least a real measurement of this cost gives. A median below it is marked suspect.
    floor: f64 = 0,
};

const costs = [_]Cost{
    .{ .name = "first-level cache hit", .unit = "ns per load", .measure = cache_hit },
    .{ .name = "main-memory read", .unit = "ns per load", .measure = memory_read },
    .{ .name = "branch mispredict", .unit = "ns per mispredict", .measure = mispredict, .floor = mispredict_ns_min },
    .{ .name = "copy of 64 KiB", .unit = "ns per copy", .measure = copy },
    .{ .name = "system call (getpid)", .unit = "ns per call", .measure = system_call },
};

/// The memory every measurement reads, allocated once.
const Buffers = struct {
    hit: []usize,
    memory: []usize,
    random_bits: []u8,
    sorted_bits: []u8,
    copy_from: []u8,
    copy_to: []u8,
};

var output: [output_len]u8 align(16) = undefined;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.LinuxOnly;
    const allocator = init.arena.allocator();
    var buffers: Buffers = .{
        .hit = try allocator.alloc(usize, hit_buffer_len / @sizeOf(usize)),
        .memory = try allocator.alloc(usize, memory_buffer_len / @sizeOf(usize)),
        .random_bits = try allocator.alloc(u8, branch_bits_count),
        .sorted_bits = try allocator.alloc(u8, branch_bits_count),
        .copy_from = try allocator.alloc(u8, copy_len),
        .copy_to = try allocator.alloc(u8, copy_len),
    };
    var random: std.Random.DefaultPrng = .init(seed);
    link_lines(buffers.hit, random.random());
    link_lines(buffers.memory, random.random());
    fill_bits(buffers.random_bits, buffers.sorted_bits, random.random());
    @memset(buffers.copy_from, 1);
    var stdout = std.Io.File.stdout().writer(init.io, &output);
    const writer = &stdout.interface;
    try writer.print("## The costs, timed on this machine ({s}, {t})\n\n", .{ builtin.cpu.model.name, builtin.mode });
    try writer.print("| Cost | Median | Spread | Unit |\n| --- | ---: | ---: | --- |\n", .{});
    for (costs) |cost| {
        const result = try median(cost, &buffers, init.io);
        const suspect = if (result.median < cost.floor) " (suspect: below the floor a real measurement gives)" else "";
        try writer.print("| {s} | {d:.2}{s} | {d:.1}% | {s} |\n", .{ cost.name, result.median, suspect, result.spread_percent, cost.unit });
    }
    try writer.flush();
}

const Result = struct { median: f64, spread_percent: f64 };

fn median(cost: Cost, buffers: *Buffers, io: std.Io) !Result {
    // One unmeasured run first, so the first timed run pays no page faults or cold caches.
    _ = try cost.measure(buffers, io);
    var samples: [runs]f64 = @splat(0);
    for (&samples) |*sample| sample.* = try cost.measure(buffers, io);
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    const middle = samples[runs / 2];
    return .{ .median = middle, .spread_percent = (samples[runs - 1] - samples[0]) / middle * percent };
}

/// Links the first word of each cache line of `slots` into one cycle, in random order (Sattolo's
/// shuffle), so a chase from any line visits every line once before it returns.
fn link_lines(slots: []usize, random: std.Random) void {
    const words_per_line = line_len / @sizeOf(usize);
    const lines = slots.len / words_per_line;
    assert(lines > 1);
    for (0..lines) |line| slots[line * words_per_line] = line * words_per_line;
    for (0..lines - 1) |step| {
        const i = lines - 1 - step;
        const j = random.uintLessThan(usize, i);
        std.mem.swap(usize, &slots[i * words_per_line], &slots[j * words_per_line]);
    }
}

fn fill_bits(random_bits: []u8, sorted_bits: []u8, random: std.Random) void {
    for (random_bits) |*bit| bit.* = random.int(u1);
    for (sorted_bits, 0..) |*bit, i| bit.* = @intFromBool(i >= sorted_bits.len / 2);
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .awake);
}

fn elapsed_ns(io: std.Io, start: std.Io.Timestamp) f64 {
    const ns = start.untilNow(io, .awake).toNanoseconds();
    assert(ns >= 0);
    return @floatFromInt(ns);
}

noinline fn chase(slots: []const usize) usize {
    var index: usize = 0;
    for (0..chase_steps) |_| index = slots[index];
    return index;
}

fn time_chase(slots: []const usize, io: std.Io) f64 {
    const start = now(io);
    std.mem.doNotOptimizeAway(chase(slots));
    return elapsed_ns(io, start) / chase_steps;
}

fn cache_hit(buffers: *Buffers, io: std.Io) !f64 {
    return time_chase(buffers.hit, io);
}

fn memory_read(buffers: *Buffers, io: std.Io) !f64 {
    return time_chase(buffers.memory, io);
}

/// Adds 1 for each set bit and 2 for each clear one. The set arm holds an empty volatile `asm`,
/// which no path may run unless the bit is set, so LLVM keeps a branch: two volatile loads merged
/// into one indexed load, a select in all but name.
noinline fn branch_over(bits: []const u8) u64 {
    var sum: u64 = 0;
    for (0..branch_rounds) |_| {
        for (bits) |bit| {
            if (bit != 0) {
                asm volatile ("");
                sum +%= 1;
            } else {
                sum +%= 2;
            }
        }
    }
    return sum;
}

fn time_branch(bits: []const u8, io: std.Io) f64 {
    const start = now(io);
    std.mem.doNotOptimizeAway(branch_over(bits));
    return elapsed_ns(io, start);
}

fn mispredict(buffers: *Buffers, io: std.Io) !f64 {
    const random_ns = time_branch(buffers.random_bits, io);
    const sorted_ns = time_branch(buffers.sorted_bits, io);
    const mispredicts = @as(f64, @floatFromInt(branch_bits_count * branch_rounds)) * mispredicts_per_bit;
    return (random_ns - sorted_ns) / mispredicts;
}

fn copy(buffers: *Buffers, io: std.Io) !f64 {
    const start = now(io);
    for (0..copy_rounds) |_| {
        @memcpy(buffers.copy_to, buffers.copy_from);
        std.mem.doNotOptimizeAway(buffers.copy_to.ptr);
    }
    return elapsed_ns(io, start) / copy_rounds;
}

fn system_call(buffers: *Buffers, io: std.Io) !f64 {
    _ = buffers;
    const start = now(io);
    for (0..syscall_calls) |_| std.mem.doNotOptimizeAway(std.os.linux.getpid());
    return elapsed_ns(io, start) / syscall_calls;
}
