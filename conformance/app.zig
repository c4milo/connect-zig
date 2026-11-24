//! The state the conformance server keeps, which every handler reads as its `app`.
const std = @import("std");
const platform = @import("platform");
const rpc = @import("connect_colibri");
const Echo = @import("echo.zig").Echo;

pub const App = struct {
    /// The CPU features the routes read and write each message with, stdx's type. The program
    /// detects them once, as it starts.
    cpu_features: platform.CpuFeatures,
    /// The codings connect_colibri reads and writes messages in.
    codings: rpc.Codings = .{},
    /// The ServerCompatRequest's limit, which connect_colibri's routes apply: 0 for none.
    message_receive_limit: u32 = 0,
    /// What a handler sleeps through for a definition's response delay.
    io: std.Io = undefined,
    echo: Echo = .{},
};
