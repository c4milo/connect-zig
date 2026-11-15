//! The interop server's limits (decision 42).

/// The port the server binds when the command line names none.
pub const port_default = 8080;
/// The base of the port number on the command line.
pub const decimal = 10;
/// TCP connections at once. A connection past them is accepted and closed, so its client learns
/// it at once.
pub const tcp_connections = 64;
/// QUIC connections at once. A connection past them is accepted and closed, as a TCP one is.
pub const quic_connections = 8;
/// Calls the router answers at once.
pub const requests = 8;
/// Room for one call's request body: each message is a coverage case, and the largest takes up
/// to 64 KiB.
pub const body_bytes = 64 * 1024;
/// Room for one reply with its headers: the largest coverage case takes up to 64 KiB.
pub const response_bytes = 64 * 1024;

/// The largest message a route reads or writes: the largest coverage case, in JSON, with room.
pub const message_bytes = 64 * 1024;
/// The longest JSON token of a request: a string's octets.
pub const token_bytes = 16 * 1024;
/// The most messages Repeat sends.
pub const repeat_max = 16;
/// The headers Inspect reports at most.
pub const inspected_max = 4;
/// Octets of the "name: value" lines of the headers Inspect reports.
pub const inspected_len = 1024;
/// Octets of the encoded request that Fail sends back as its detail.
pub const detail_len = 256;
