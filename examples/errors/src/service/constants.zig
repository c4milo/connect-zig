//! The calculator service's limits (decision 42).

/// The longest message and JSON token a route reads or writes, and the longest encoded detail.
pub const text_len_max = 4096;
/// The digits of a u32, at most: room for each count that `Counting` reports.
pub const count_len_max = 10;
