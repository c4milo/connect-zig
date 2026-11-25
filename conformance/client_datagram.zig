//! The UDP socket of the conformance client's QUIC connection, for a case over h3 (RFC 9114 §3):
//! `flush` sends each datagram the pool owes to the server, and `read` hands the pool the one
//! datagram the socket holds, with the address it came from. The transport holds one `UdpSocket`.
const std = @import("std");
const assert = std.debug.assert;
const client = @import("colibri").client;
const constants = @import("constants.zig");

pub const UdpSocket = struct {
    const Self = @This();

    socket: ?std.Io.net.Socket,
    incoming: [constants.client_datagram_in_bytes]u8,
    outgoing: [constants.client_datagram_out_bytes]u8,

    /// Starts with no socket bound.
    pub fn init(self: *Self) void {
        self.socket = null;
    }

    /// Binds the UDP socket on an address the kernel picks, of the server's family.
    pub fn open(self: *Self, io: std.Io, peer: *const std.Io.net.IpAddress) std.Io.net.IpAddress.BindError!void {
        assert(self.socket == null);
        const any: std.Io.net.IpAddress = switch (peer.*) {
            .ip4 => .{ .ip4 = .unspecified(0) },
            .ip6 => .{ .ip6 = .unspecified(0) },
        };
        self.socket = try any.bind(io, .{ .mode = .dgram });
    }

    pub fn close(self: *Self, io: std.Io) void {
        const bound = self.socket orelse return;
        bound.close(io);
        self.socket = null;
    }

    /// The socket's descriptor, for `poll`, or null when none is bound.
    pub fn descriptor(self: *const Self) ?std.posix.fd_t {
        const bound = self.socket orelse return null;
        return bound.handle;
    }

    /// Sends each datagram the QUIC connection owes. A send the system refuses drops the
    /// datagram, which QUIC sends again when it was needed (RFC 9000 §13.3).
    pub fn flush(self: *Self, io: std.Io, pool: anytype, peer: *const std.Io.net.IpAddress, now_ns: u64) void {
        const bound = self.socket orelse return;
        for (0..constants.client_events_per_turn_max) |_| {
            const sent = pool.send_datagram(&self.outgoing, now_ns) orelse return;
            bound.send(io, peer, sent.bytes) catch {};
        }
    }

    /// Reads the datagram the socket holds and passes it to the pool, then gives each event the
    /// pool reports to `reporter.report`, until the pool consumes nothing and reports nothing.
    /// The datagram is consumed whole.
    pub fn read(self: *Self, io: std.Io, pool: anytype, now_ns: u64, reporter: anytype) void {
        const bound = self.socket orelse return;
        const message = bound.receive(io, &self.incoming) catch return;
        const from: client.Address = switch (message.from) {
            .ip4 => |address| .init(&address.bytes, address.port),
            .ip6 => |address| .init(&address.bytes, address.port),
        };
        var rest: client.Input = .{ .datagram = .{ .bytes = message.data, .from = from } };
        for (0..constants.client_events_per_turn_max) |_| {
            const received = pool.receive(rest, now_ns);
            if (received.consumed > 0) rest = .none;
            const event = received.event orelse {
                if (received.consumed == 0) return;
                continue;
            };
            reporter.report(event, now_ns);
        }
    }
};
