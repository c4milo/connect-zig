//! The interop server's limits (decision 42).

/// The port the server binds when the command line names none.
pub const port_default = 8080;
/// TCP connections and QUIC connections at once. A connection past them is accepted and closed,
/// so its client learns it at once.
pub const tcp_connections = 64;
pub const quic_connections = 8;
/// Calls the router answers at once.
pub const requests = 8;
/// Room for one call's request body, and for one reply with its headers: each message is a
/// coverage case, and the largest takes up to 64 KiB.
pub const body_bytes = 64 * 1024;
pub const response_bytes = 64 * 1024;
