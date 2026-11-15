//! The coverage converter's limits (decision 42).

/// The largest message a case holds, in either encoding.
pub const message_len_max = 1 << 20;
/// The longest JSON token: a string's octets.
pub const token_len_max = 1 << 16;
/// Octets of the buffer that stdin and stdout go through.
pub const io_buffer_len = 1 << 12;
