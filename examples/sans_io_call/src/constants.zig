//! The sans_io_call example's limits (decision 42).

/// The octets of each buffer that either side holds.
pub const buffer_len = 4096;
/// The details and the metadata entries that the client reads, at most.
pub const entries_max = 8;
/// The messages that the server writes for one call, at most.
pub const replies_max = 4;
