//! The harness's limits (decision 42). Each names what it bounds, and the side it belongs to.

/// The octets the server writes for its TCP connection before it sends them, at most.
pub const server_output_len = 16 * 1024;
/// Events the server takes after one input, calls of `send_stream` for one `send`, and datagrams
/// it reads or writes in one turn, at most.
pub const server_events_per_turn_max = 64;
pub const server_sends_per_event_max = 8;
pub const datagrams_per_turn_max = 32;
/// Octets a QUIC connection holds unread, at most: what colibri's examples hold.
pub const receive_pool_len = 64 * 1024;
/// The UDP port the client sends from, which a program's UDP socket reports with each datagram.
pub const client_port = 50_000;
/// The port the server listens on, for TCP and for UDP: the port of an "https" origin (RFC 9110
/// §4.2.2).
pub const server_port = 443;
/// The loopback address, where both sides of the link sit.
pub const loopback = [_]u8{ 127, 0, 0, 1 };

/// Turns of the client and the server in one round before the example gives up.
pub const turns_max = 512;
/// Calls of `send_stream` for one `send`, and calls of `receive` in one drain, at most.
pub const client_sends_per_event_max = 16;
pub const receive_calls_max = 4096;
/// The longest a side sleeps when no octet waits: 100 ms.
pub const wait_ns_max: u64 = 100 * 1_000_000;
/// The streamed calls of one round, at most.
pub const listeners_max = 8;

/// Octets of each buffer one call writes its request into and reads its response into.
pub const call_buffer_len = 4096;
/// Octets of each piece of a streamed response: fewer than most envelopes, so pieces split them.
pub const piece_len = 16;
/// Octets of each buffer `storage` lends a response, and the details and metadata it reads.
pub const read_len = 4096;
pub const entries_max = 8;

/// A test draws no secret, so a seeded generator stands in for entropy on each side: each run
/// replays.
pub const server_seed = 0x656c697a61;
pub const client_seed = 0x636c69656e74;

/// The octets of the DER in a PEM file of `pem_len` octets, at most: base64 writes 3 octets as 4
/// letters (RFC 7468 §2).
pub fn der_len_max(comptime pem_len: usize) usize {
    return pem_len / 4 * 3;
}

/// The port `zig build serve` binds when the command line names none.
pub const serve_port_default = 8443;
/// TCP and QUIC connections a served example holds at once. A connection past the TCP sockets
/// waits in the kernel's backlog until one frees: `tools/interop_check.sh` fills all 64.
pub const serve_tcp_connections = 64;
pub const serve_quic_connections = 8;
/// The base of the port number on the command line.
pub const decimal = 10;
