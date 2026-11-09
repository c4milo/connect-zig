//! The UDP socket of the conformance client's QUIC connection, for a case over h3 (RFC 9114 §3):
//! `flush` sends each datagram the pool owes to the server, and `read` hands the pool the one
//! datagram the socket holds, with the address it came from.
const std = @import("std");
const assert = std.debug.assert;
const client = @import("client");
const constants = @import("constants.zig");

var socket: ?std.Io.net.Socket align(@alignOf(std.Io.net.Socket)) = null;
var incoming: [constants.client_datagram_in_bytes]u8 = undefined;
var outgoing: [constants.client_datagram_out_bytes]u8 = undefined;

/// Binds the UDP socket on an address the kernel picks, of the server's family.
pub fn open(io: std.Io, peer: *const std.Io.net.IpAddress) std.Io.net.IpAddress.BindError!void {
    assert(socket == null);
    const any: std.Io.net.IpAddress = switch (peer.*) {
        .ip4 => .{ .ip4 = .unspecified(0) },
        .ip6 => .{ .ip6 = .unspecified(0) },
    };
    socket = try any.bind(io, .{ .mode = .dgram });
}

pub fn close(io: std.Io) void {
    const bound = socket orelse return;
    bound.close(io);
    socket = null;
}

/// The socket's descriptor, for `poll`, or null when none is bound.
pub fn descriptor() ?std.posix.fd_t {
    const bound = socket orelse return null;
    return bound.handle;
}

/// Sends each datagram the QUIC connection owes. A send the system refuses drops the datagram,
/// which QUIC sends again when it was needed (RFC 9000 §13.3).
pub fn flush(io: std.Io, pool: anytype, peer: *const std.Io.net.IpAddress, now_ns: u64) void {
    const bound = socket orelse return;
    for (0..constants.client_events_per_turn_max) |_| {
        const sent = pool.send_datagram(&outgoing, now_ns) orelse return;
        bound.send(io, peer, sent.bytes) catch {};
    }
}

/// Reads the datagram the socket holds and passes it to the pool, then reports each event the
/// pool gives until it consumes nothing and reports nothing. The datagram is consumed whole.
pub fn read(io: std.Io, pool: anytype, now_ns: u64, report: *const fn (client.Event, u64) void) void {
    const bound = socket orelse return;
    const message = bound.receive(io, &incoming) catch return;
    const from: client.Address = switch (message.from) {
        .ip4 => |address| .of(&address.bytes, address.port),
        .ip6 => |address| .of(&address.bytes, address.port),
    };
    var rest: client.Input = .{ .datagram = .{ .bytes = message.data, .from = from } };
    for (0..constants.client_events_per_turn_max) |_| {
        const received = pool.receive(rest, now_ns);
        if (received.consumed > 0) rest = .none;
        const event = received.event orelse {
            if (received.consumed == 0) return;
            continue;
        };
        report(event, now_ns);
    }
}
