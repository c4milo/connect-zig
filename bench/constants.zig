//! The benchmark tree's limits (decision 42): those of the benchmark in main.zig, measure.zig and
//! cases.zig, and those of the costs table in costs.zig. The values of the messages stay in
//! inputs.zig, which bench/go/inputs.go and bench/rust/src/inputs.rs follow.
const std = @import("std");

/// A full run times 11 batches of each operation, and each batch lasts about 20 ms.
/// bench/go/measure.go takes the same settings.
pub const full_runs = 11;
pub const full_batch_ns = 20 * std.time.ns_per_ms;
/// `--quick` times 3 batches of each operation, and each batch lasts about 1 ms: a smoke test.
pub const quick_runs = 3;
pub const quick_batch_ns = std.time.ns_per_ms;
/// The most timed batches a measurement takes.
pub const runs_max = 31;
/// Calibration doubles the iterations at most this many times: 2^40 iterations of the cheapest
/// operation take hours, far past any batch length.
pub const doublings_max = 40;
/// Each step of calibration multiplies the iterations by this factor.
pub const growth_factor = 2;
/// A count divided by `halves` gives its half. The middle of an odd count of sorted runs, which is
/// the median, is at that index.
pub const halves = 2;

/// The most arguments the program reads.
pub const arguments_max = 8;
/// Room for the table that the program writes to stdout.
pub const output_len = 16 * 1024;
/// Room for the path of one file that `--write` writes.
pub const path_len = 4096;
/// Room for "<message> <operation>" and its terminating zero.
pub const label_len = 64;

/// Room for the largest message in each form: the large message takes about 180 KB in binary
/// and about 300 KB in JSON.
pub const buffer_len = 1 << 20;
/// Room for the longest JSON token: the large message's description, about 6 KB.
pub const token_len = 16 * 1024;
/// Room for the elements of every repeated field of the largest message: about 130 KB for the
/// large one's records and their values.
pub const storage_len = 1 << 20;
/// The alignment of each buffer that an operation reads or writes, and of the program's output.
pub const buffer_align = 16;

/// The limits of the costs table, bench/costs.zig.
pub const costs = struct {
    /// The runs of each cost; their median is the cost, as the method asks.
    pub const runs = 5;
    /// The octets of a cache line, which the chases step by.
    pub const line_len = 64;
    /// The chase that stays in the first-level cache: 16 KiB, half of the smallest such cache CI
    /// has.
    pub const hit_buffer_len = 16 * 1024;
    /// The chase that reads main memory: 256 MiB, past any runner's last-level cache.
    pub const memory_buffer_len = 256 * 1024 * 1024;
    /// The loads of one timed chase.
    pub const chase_steps = 1 << 22;
    /// The bits one timed branch loop reads.
    pub const branch_bits_count = 1 << 16;
    /// Each branch loop runs this many times over its bits.
    pub const branch_rounds = 64;
    /// The branch loop adds 1 for each set bit and this number for each clear one, so the two
    /// arms differ.
    pub const clear_bit_addend = 2;
    /// The octets one copy moves, and how many copies are timed.
    pub const copy_len = 64 * 1024;
    pub const copy_rounds = 4096;
    /// The system calls one run times.
    pub const syscall_calls = 100_000;
    /// The least a mispredict costs on any core CI runs: about ten cycles. Less means the branch
    /// became a select and nothing was measured, so the row is marked suspect. The table reports
    /// and never gates (the owner's ruling of 2026-11-09).
    pub const mispredict_ns_min = 1.0;
    /// Room for the table that the program writes to stdout.
    pub const output_len = 4096;
};
