//! Times one operation: finds how many iterations fill a batch of the target length, runs one
//! batch to warm up, then times `runs` batches and returns the median time of one iteration.
//! bench/go/measure.go follows the same steps with the same settings.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

pub const Settings = struct {
    /// The timed batches; the median of their times is the result. Odd, so one batch is the median.
    runs: usize,
    /// The length a batch should reach, in nanoseconds.
    batch_ns: u64,
};

/// The median nanoseconds of one call of `runner.run(1)`. `runner.run(n)` runs the operation `n`
/// times.
pub fn median_ns(io: std.Io, settings: Settings, runner: anytype) !f64 {
    assert(settings.runs > 0 and settings.runs <= constants.runs_max);
    assert(settings.runs % constants.halves == 1);
    const iterations = try calibrate(io, settings, runner);
    _ = try time_batch(io, runner, iterations);
    var per_iteration: [constants.runs_max]f64 = @splat(0);
    const timed = per_iteration[0..settings.runs];
    for (timed) |*each| {
        const elapsed = try time_batch(io, runner, iterations);
        each.* = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
    }
    std.mem.sort(f64, timed, {}, std.sort.asc(f64));
    return timed[timed.len / constants.halves];
}

/// The iterations a batch needs to last `settings.batch_ns`, doubling from one.
fn calibrate(io: std.Io, settings: Settings, runner: anytype) !u64 {
    var iterations: u64 = 1;
    for (0..constants.doublings_max) |_| {
        if (try time_batch(io, runner, iterations) >= settings.batch_ns) return iterations;
        iterations *= constants.growth_factor;
    }
    return iterations;
}

fn time_batch(io: std.Io, runner: anytype, iterations: u64) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    try runner.run(iterations);
    const elapsed = start.untilNow(io, .awake).toNanoseconds();
    assert(elapsed >= 0);
    return @intCast(elapsed);
}
