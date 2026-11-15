//! What a scenario of the interop client found: nothing, when it passed, or `error.Wrong` with
//! the reason it failed, which a `Verdict` holds until the next scenario fails.
const std = @import("std");
const constants = @import("constants.zig");

/// The reason the last failed scenario recorded. `main` keeps one in its `State` (decision 42),
/// and each scenario writes it when it fails.
pub const Verdict = struct {
    reason_octets: [constants.reason_bytes]u8 = undefined,
    reason_len: usize = 0,

    pub const Error = error{Wrong};

    /// Records why the scenario failed, and returns the error that fails it.
    pub fn wrong(verdict: *Verdict, comptime format: []const u8, arguments: anytype) Error {
        var writer: std.Io.Writer = .fixed(&verdict.reason_octets);
        // A reason longer than its room is cut there.
        writer.print(format, arguments) catch {};
        verdict.reason_len = writer.end;
        return error.Wrong;
    }

    /// Records a call that ended with `failure` where it should have succeeded.
    pub fn failed(verdict: *Verdict, failure: anytype) Error {
        return verdict.wrong("{s}: {s}", .{ failure.code.name(), failure.message });
    }

    /// The reason the last failed scenario recorded.
    pub fn reason(verdict: *const Verdict) []const u8 {
        return verdict.reason_octets[0..verdict.reason_len];
    }
};
