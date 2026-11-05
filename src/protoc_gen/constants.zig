//! The plugin's named sizes.

/// The most bytes of request the plugin reads: protoc's requests for large trees stay far below.
pub const request_len_max = 256 * 1024 * 1024;
/// The bytes stdin and stdout each buffer.
pub const io_buffer_len = 64 * 1024;
