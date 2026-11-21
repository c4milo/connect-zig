//! The signup service's limits (decision 42).

/// The longest message and JSON token a route reads or writes.
pub const message_len_max = 4096;
/// The accounts one SignupMany call reads, at most.
pub const accounts_per_call_max = 1024;
