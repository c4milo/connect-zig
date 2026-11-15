//! The errors example's limits (decision 42), and the numbers its calls divide.

/// Calls the router answers at once, and room for one call's request body and for one reply with
/// its headers.
pub const requests = 8;
pub const body_bytes = 16 * 1024;
pub const response_bytes = 16 * 1024;
/// The dividend of every call, and the divisor of the call that does not fail.
pub const dividend = 7;
pub const divisor = 2;
