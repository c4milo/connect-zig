//! What a scenario of the interop client found: nothing, when it passed, or `error.Wrong` with
//! the reason it failed, which `reason` holds until the next scenario.
const std = @import("std");

pub const Error = error{Wrong};

/// Octets of the reason a scenario failed, at most.
const reason_bytes = 512;
var reason_octets: [reason_bytes]u8 = undefined;
var reason_len: usize = 0;

/// Records why the scenario failed, and returns the error that fails it.
pub fn wrong(comptime format: []const u8, arguments: anytype) Error {
    var writer: std.Io.Writer = .fixed(&reason_octets);
    // A reason longer than its room is cut there.
    writer.print(format, arguments) catch {};
    reason_len = writer.end;
    return error.Wrong;
}

/// Records a call that ended with `failure` where it should have succeeded.
pub fn failed(failure: anytype) Error {
    return wrong("{s}: {s}", .{ failure.code.name(), failure.message });
}

/// The reason the last failed scenario recorded.
pub fn reason() []const u8 {
    return reason_octets[0..reason_len];
}
