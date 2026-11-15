//! The streaming service's limits (decision 42).

/// The longest text a handler writes.
pub const text_len_max = 4096;
/// The digits of a u32, at most: room for each count that `Counting` reports.
pub const count_len_max = 10;
/// The largest `from` Countdown counts down from. Its stream is then many times the router's
/// response memory, which bounds the octets in flight alone.
pub const countdown_max = 1_000_000;
