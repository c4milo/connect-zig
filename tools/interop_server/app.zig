//! The state that the interop server's routes read as their `app`.
const rpc = @import("connect_colibri");
const service = @import("interop.zig");

pub const App = struct {
    /// The codings connect_colibri reads and writes messages in: none unless the program sets them.
    codings: rpc.Codings = .{},
    /// The interop service's room for its replies' headers and details.
    interop: service.Room = .{},
};
