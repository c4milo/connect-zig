//! The connect_colibri module's named sizes.

/// The longest message a route reads or writes by default: 64 KiB.
pub const message_bytes_default = 64 * 1024;
/// The longest JSON token a route reads by default.
pub const token_bytes_default = 16 * 1024;
/// The octets of a route's status trailers: grpc-status, grpc-message and the details, twice
/// over for gRPC-Web's frame, and an end-stream message.
pub const trailer_bytes = 4096;
/// The headers and trailers the adapter copies into colibri's field lists at once, at most.
pub const fields_max = 8;
