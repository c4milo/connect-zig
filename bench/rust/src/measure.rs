//! Times one operation as bench/measure.zig and bench/go/measure.go do: finds how many
//! iterations fill a batch of the target length, runs one batch to warm up, then times the runs
//! and returns the median time of one iteration.

use std::time::Instant;

/// Calibration doubles the iterations at most this many times.
const DOUBLINGS_MAX: u32 = 40;

pub struct Settings {
    pub runs: usize,
    pub batch_ns: u128,
}

pub const FULL: Settings = Settings {
    runs: 11,
    batch_ns: 20_000_000,
};
pub const QUICK: Settings = Settings {
    runs: 3,
    batch_ns: 1_000_000,
};

pub type Run<'a> = Box<dyn FnMut(u64) -> Result<(), String> + 'a>;

pub fn median_ns(current: &Settings, run: &mut Run<'_>) -> Result<f64, String> {
    let iterations = calibrate(current, run)?;
    time_batch(run, iterations)?;
    let mut per_iteration = Vec::with_capacity(current.runs);
    for _ in 0..current.runs {
        let elapsed = time_batch(run, iterations)?;
        per_iteration.push(elapsed as f64 / iterations as f64);
    }
    per_iteration.sort_by(f64::total_cmp);
    Ok(per_iteration[per_iteration.len() / 2])
}

fn calibrate(current: &Settings, run: &mut Run<'_>) -> Result<u64, String> {
    let mut iterations = 1u64;
    for _ in 0..DOUBLINGS_MAX {
        if time_batch(run, iterations)? >= current.batch_ns {
            return Ok(iterations);
        }
        iterations *= 2;
    }
    Ok(iterations)
}

fn time_batch(run: &mut Run<'_>, iterations: u64) -> Result<u128, String> {
    let start = Instant::now();
    run(iterations)?;
    Ok(start.elapsed().as_nanos())
}
