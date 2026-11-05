//! The state the example server keeps across calls, which every handler and interceptor of the
//! ELIZA and demo services reads as its `app`.
const connect = @import("connect");
const adapter = @import("connect_colibri");

/// The longest sentence or detail a handler writes.
pub const text_len_max = 4096;
/// The digits of two u32 counts.
pub const count_digits_max = 20;

/// A reply is written into the response before its handler returns, so one room serves every
/// call, even while several calls run at once.
pub const App = struct {
    /// The calls ELIZA answered.
    calls: u32 = 0,
    /// The demo calls the logging interceptor saw start, and those it saw fail.
    logged: u32 = 0,
    failed: u32 = 0,
    /// The codings connect_colibri reads and writes messages in: none unless a program sets them.
    codings: adapter.Codings = .{},
    text: [text_len_max]u8 = undefined,
    /// A Divide error's detail: its encoding, and the list that names it.
    detail_bytes: [text_len_max]u8 = undefined,
    details: [1]connect.Detail = undefined,
    /// The digits of the counts `Counting` reports.
    counts: [count_digits_max]u8 = undefined,
};
