//! The state that the interop server's routes read as their `app`.
const rpc = @import("connect_colibri");
const platform = @import("platform");
const service = @import("interop.zig");

pub const App = struct {
    /// The CPU features the routes read and write each message with, stdx's type. The program
    /// detects them once, as it starts.
    cpu_features: platform.CpuFeatures,
    /// The codings connect_colibri reads and writes messages in: none unless the program sets them.
    codings: rpc.Codings = .{},
    /// The interop service's room for its replies' headers and details.
    interop: service.Room = .{},
};
