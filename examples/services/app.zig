//! The state the example server keeps across calls, which every handler and interceptor of the
//! ELIZA, demo and GitHub-style services reads as its `app`.
const std = @import("std");
const connect = @import("connect");
const rpc = @import("connect_colibri");
const github = @import("github.zig");
const interop = @import("interop.zig");

/// The longest sentence or detail a handler writes.
pub const text_len_max = 4096;
/// The digits of two u32 counts.
pub const count_digits_max = 20;

/// A reply is written into the response before its handler returns, so one room serves every
/// call, even while several calls run at once.
pub const App = struct {
    /// The demo calls the logging interceptor saw start, and those it saw fail.
    logged: u32 = 0,
    failed: u32 = 0,
    /// The logged calls that arrived as a Connect GET, with their message in the query.
    queried: u32 = 0,
    /// The codings connect_colibri reads and writes messages in: none unless a program sets them.
    codings: rpc.Codings = .{},
    text: [text_len_max]u8 = undefined,
    /// A Divide error's detail: its encoding, and the list that names it.
    detail_bytes: [text_len_max]u8 = undefined,
    details: [1]connect.Detail = undefined,
    /// The digits of the counts `Counting` reports.
    counts: [count_digits_max]u8 = undefined,
    /// The GitHub-style service's store, and the room its replies take.
    github: github.Room = .{},
    /// The interop service's room for its replies' headers and details.
    interop: interop.Room = .{},
};

/// Writes a reply into `app.text`, which stays valid until the next call writes there.
pub fn text_of(app: *App, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&app.text, format, args) catch "too long";
}

/// The route options both services start from: room for a message and a JSON token of
/// `text_len_max` octets.
pub const route_options: rpc.RouteOptions = .{ .message_bytes = text_len_max, .token_bytes = text_len_max };
