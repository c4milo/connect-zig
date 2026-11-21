//! The validate example's limits (decision 42).

/// Calls the router answers at once, and room for one call's request body and for one reply with
/// its headers.
pub const requests = 8;
pub const body_bytes = 16 * 1024;
pub const response_bytes = 16 * 1024;
/// The ages of the accounts the check sends: two that the schema takes, and one under its
/// least age of 13.
pub const age_ada = 36;
pub const age_grace = 45;
pub const age_too_young = 7;
