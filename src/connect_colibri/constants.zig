//! The connect_colibri module's named sizes.

/// The longest message a route reads or writes by default: 64 KiB.
pub const message_bytes_default = 64 * 1024;
/// The longest JSON token a route reads by default.
pub const token_bytes_default = 16 * 1024;
/// The octets of a route's status trailers: grpc-status, grpc-message and the details, twice
/// over for gRPC-Web's frame, and an end-stream message.
pub const trailer_bytes = 4096;
/// The headers and trailers connect_colibri copies into colibri's field lists at once, at most.
pub const fields_max = 8;
/// The octets of a request's headers a route copies at its head, names and values together.
pub const request_header_bytes = 4096;
/// The request headers a route copies at its head, at most.
pub const request_headers_max = 32;
/// The octets of a GET's query a route copies at its head: the request-line length RFC 9110 §4.1
/// recommends that a server support, at least.
pub const request_query_bytes = 8192;
/// The messages one read of a streaming body passes on, at most. Each takes at least an
/// envelope's 5-octet prefix, and a router entry holds far fewer octets than this many prefixes.
pub const messages_per_read_max = 65_536;
/// RFC 9110 §15.5.15: URI Too Long.
pub const status_uri_too_long: u16 = 414;
/// RFC 6585 §5: Request Header Fields Too Large.
pub const status_headers_too_large: u16 = 431;
