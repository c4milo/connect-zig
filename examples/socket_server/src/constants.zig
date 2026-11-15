//! The socket server's limits (decision 42).

/// Calls the router answers at once, and room for one call's request body and for one reply with
/// its headers. A GitHub-style page of repositories takes the most.
pub const requests = 8;
pub const body_bytes = 64 * 1024;
pub const response_bytes = 64 * 1024;
