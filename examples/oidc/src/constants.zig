//! The OpenID Connect example's limits (decision 42).

/// Calls the router answers at once, and room for one call's request body and for one reply with
/// its headers.
pub const requests = 8;
pub const body_bytes = 16 * 1024;
pub const response_bytes = 16 * 1024;

/// An hour, in seconds: how long before or after the judged instant a token expires.
pub const hour_s = 3600;
/// RFC 9110 §15.5.2: the HTTP status that Connect answers an unauthenticated unary call with.
pub const http_unauthorized = 401;
