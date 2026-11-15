//! The GitHub-style example's limits (decision 42).

/// Calls the router answers at once, and room for one call's request body and for one reply with
/// its headers.
pub const requests = 8;
pub const body_bytes = 64 * 1024;
pub const response_bytes = 64 * 1024;

/// The anonymous calls step 6 sends at once: fewer than the router answers at once.
pub const burst_len = 6;
/// The events the session's issues record: five opened, five labels added, and issue #1 closed.
pub const events_count = 11;
/// Room for the token of the next page of a list, which the client sends back.
pub const page_token_len = 32;
/// The issues a client asks for in each page of a list.
pub const page_size = 2;
/// An issue number that no repository holds.
pub const missing_issue_number = 42;
/// The issues with the label "bug": #1, which step 4 closes, and #3.
pub const bug_numbers = [_]i32{ 1, 3 };
