//! The ELIZA service's limits (decision 42).

/// The longest sentence a handler writes.
pub const text_len_max = 4096;
/// The sentences Converse answers in one call, at most.
pub const conversation_turns_max = 16;
