//! The streaming example's limits (decision 42), and the numbers its calls send.

/// Calls the router answers at once, and room for one call's request body and for one reply with
/// its headers.
pub const requests = 8;
pub const body_bytes = 16 * 1024;
pub const response_bytes = 16 * 1024;
/// The numbers each Sum call sends, and their sum.
pub const sum_numbers = [_]i64{ 1, 2, 3, 4 };
pub const numbers_sum = 10;
/// The number the Countdown call counts down from.
pub const countdown_from = 3;
