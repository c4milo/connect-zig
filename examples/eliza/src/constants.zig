//! The ELIZA example's limits (decision 42).

/// Calls the router answers at once, and room for one call's request body and for one reply with
/// its headers.
pub const requests = 8;
pub const body_bytes = 16 * 1024;
pub const response_bytes = 16 * 1024;
