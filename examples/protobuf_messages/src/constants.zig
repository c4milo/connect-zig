//! The protobuf_messages example's limits (decision 42).

/// Room for the encoded message, for its JSON text, and for the binary form that a JSON read
/// writes.
pub const message_len = 1024;
/// Room for one JSON token. A JSON read takes one token at a time.
pub const token_len = 256;
/// Room for the elements of repeated fields that `decode_into` reads, and the alignment that this
/// room starts at.
pub const storage_len = 4096;
pub const storage_align = 16;
