//! The random source of the rounds' TLS sessions: the operating system's entropy, as a program
//! that ships draws it. `std.Random` wraps any generator, so stdx cannot check a source, and a
//! seeded generator gives keys an observer can work out (stdx decision 87 as amended an eighth
//! time).
const std = @import("std");

/// A `std.Random` over `io.randomSecure`. Each draw is a call that is thread-safe, keeps no state
/// a fork copies, and has no weaker fallback. A draw that fails halts the program, so no session
/// runs on bytes the system did not give.
pub const SecureRandom = struct {
    io: std.Io,

    fn fill(pointer: *anyopaque, bytes: []u8) void {
        const self: *SecureRandom = @ptrCast(@alignCast(pointer));
        self.io.randomSecure(bytes) catch |err| std.debug.panic("no entropy: {t}", .{err});
    }

    /// The source, which points at `self`, so `self` stays where it is while the source is used.
    pub fn random(self: *SecureRandom) std.Random {
        return .{ .ptr = self, .fillFn = fill };
    }
};
