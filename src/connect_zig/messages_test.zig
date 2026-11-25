//! A test binary of a program that takes `connect_zig` with colibri and tests its messages alone,
//! as a project's own unit tests do. It links chapulin's objects through stdx's `crypto` and names
//! no stdx or colibri type, so it links only when the module's own reference reads stdx's root,
//! which keeps chapulin's hook, `ch_assert_fail` (decision 34 as amended).
//! `zig build test-connect-zig-messages` runs it.
const std = @import("std");
const proto = @import("connect_zig").protobuf;

/// The seconds of the Timestamp the test codes.
const seconds: i64 = 150;
/// Room for the Timestamp's octets.
const buffer_len = 16;

test "a program that codes messages alone links with colibri" {
    var buffer: [buffer_len]u8 = undefined;
    const timestamp: proto.wkt.Timestamp = .{ .seconds = seconds };
    const bytes = try proto.encode(proto.wkt.Timestamp, &timestamp, &buffer);
    try std.testing.expectEqual(try proto.encoded_len(proto.wkt.Timestamp, &timestamp), bytes.len);
    try std.testing.expect(bytes.len > 0);
}
