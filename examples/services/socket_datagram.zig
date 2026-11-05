//! The UDP socket of `socket_loop.zig`: one datagram socket on the TCP listener's port, one
//! multishot receive into a group of buffers the loop owns, and a slot for each datagram in
//! flight. QUIC runs over it, and h3 over QUIC (decision 28). It follows colibri's
//! `src/testing/udp.zig`, on the same loop as the TCP sockets.
const std = @import("std");
const assert = std.debug.assert;
const rotor = @import("rotor");
const server = @import("server");

/// The receive buffers the loop owns, and the octets of each: room for a datagram a path carries
/// whole, and the reserve Rotor keeps in front of it.
const receive_buffers = 16;
const receive_buffer_bytes = 2048;
/// Datagrams in flight at once, each in a slot of its own until its send completes.
const send_slots = 16;
/// The octets of one datagram the endpoint writes, at most: what one Ethernet frame carries.
const datagram_len_max = 1500;
/// The group the socket receives into. Not 0, so a read that names no group cannot pass.
const group_id: u16 = 1;
const group_options: rotor.datagram.GroupOptions = .{};

/// The user data of the receive, and of the first send slot; the slots follow it, below the
/// user data of the listener's accept. A socket's user data stays below them all.
pub const receive_user_data: u64 = std.math.maxInt(u64) - 1;
const send_user_data_first: u64 = receive_user_data - send_slots;

/// The operations the socket holds at once: its receive and a send for each slot.
pub const operations = 1 + send_slots;

comptime {
    assert(rotor.datagram.payload_capacity(receive_buffer_bytes, group_options) >= datagram_len_max);
}

pub const Datagrams = struct {
    group: [group_bytes + rotor.buffers.group_alignment]u8 align(rotor.buffers.group_alignment) = undefined,
    socket: rotor.Descriptor = undefined,
    busy: [send_slots]bool = @splat(false),
    buffers: [send_slots][datagram_len_max]u8 = undefined,
    outbound: [send_slots]rotor.datagram.Outbound = undefined,

    const group_bytes = rotor.buffers.group_bytes(receive_buffers, receive_buffer_bytes);

    /// Gives the loop the receive buffers, binds a datagram socket to `bind_to` and starts
    /// receiving.
    pub fn open(datagrams: *Datagrams, loop: *rotor.Loop, bind_to: rotor.Address) !void {
        // A block declared aligned is not always placed aligned, so the group starts at the
        // first aligned octet inside it, as colibri's `udp.zig` does.
        const start = std.mem.alignForward(usize, @intFromPtr(&datagrams.group), rotor.buffers.group_alignment);
        const aligned: [*]align(rotor.buffers.group_alignment) u8 = @ptrFromInt(start);
        try loop.provide_datagram_buffers(group_id, aligned[0..group_bytes], receive_buffers, receive_buffer_bytes, group_options);
        datagrams.socket = try rotor.sync.open_datagram(bind_to.family, &bind_to, .{});
        start_receive(datagrams, loop);
    }

    /// Whether an event is the socket's: its receive or one of its sends.
    pub fn owns(user_data: u64) bool {
        return user_data >= send_user_data_first and user_data <= receive_user_data;
    }

    /// The datagram a receive event carries, with the peer it came from, or null for a send's
    /// event, which frees its slot. The octets stay the loop's until `finish`.
    pub fn arrived(datagrams: *Datagrams, loop: *rotor.Loop, event: rotor.Event) ?server.Datagram {
        if (event.user_data != receive_user_data) {
            datagrams.busy[@intCast(event.user_data - send_user_data_first)] = false;
            return null;
        }
        if (!event.flags.buffer) return null;
        const delivery = loop.datagram(group_id, event);
        return .{ .bytes = delivery.bytes, .from = peer_address(delivery.from.peer) };
    }

    /// Ends a receive event once its datagram is read: gives its buffer back, and starts the
    /// receive again when this was its final event (Rotor ends one when its buffers run out).
    pub fn finish(datagrams: *Datagrams, loop: *rotor.Loop, event: rotor.Event) void {
        if (event.user_data != receive_user_data) return;
        if (event.flags.buffer) loop.give_back_buffer(group_id, event.flags.buffer_id);
        if (!event.flags.more) start_receive(datagrams, loop);
    }

    /// Sends every datagram the endpoint owes now, each from a free slot.
    pub fn send_owed(datagrams: *Datagrams, loop: *rotor.Loop, endpoint: anytype, now_ns: u64) void {
        for (&datagrams.busy, 0..) |*busy, slot| {
            if (busy.*) continue;
            const sent = endpoint.send_datagram(&datagrams.buffers[slot], now_ns) orelse return;
            datagrams.outbound[slot] = .{ .peer = socket_address(sent.to), .local = undefined, .segment_bytes = 0, .ecn = .not_ect, .flags = .{ .peer = true } };
            const send = rotor.Operation.send_to(send_user_data_first + slot, datagrams.socket, sent.bytes, &datagrams.outbound[slot]);
            const taken = loop.submit(&.{send}, &.{});
            assert(taken == 1);
            busy.* = true;
        }
    }
};

fn start_receive(datagrams: *Datagrams, loop: *rotor.Loop) void {
    const taken = loop.submit(&.{rotor.Operation.receive_from(receive_user_data, datagrams.socket, group_id)}, &.{});
    assert(taken == 1);
}

/// A socket address as colibri names a peer (colibri decision 72): four octets for IPv4, sixteen
/// for IPv6, the port, and an IPv6 address's scope id.
fn peer_address(address: rotor.Address) server.Address {
    const len: usize = if (address.family == .ipv4) rotor.Address.ipv4_bytes else address.bytes.len;
    var peer = server.Address.of(address.bytes[0..len], address.port);
    peer.scope_id = address.scope_id;
    return peer;
}

/// The peer colibri named, back in Rotor's form.
fn socket_address(address: server.Address) rotor.Address {
    if (address.len == rotor.Address.ipv4_bytes) return rotor.Address.ipv4(address.octets[0..rotor.Address.ipv4_bytes].*, address.port);
    assert(address.len == address.octets.len);
    return rotor.Address.ipv6(address.octets, address.port, address.scope_id);
}
