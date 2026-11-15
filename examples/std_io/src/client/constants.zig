//! The self-check's limits, and those of its driver (decision 42).
const std = @import("std");

/// The port the self-check asks the server for: 0 lets the kernel choose.
pub const server_port_argument = "0";
/// The base of the port in the server's first line.
pub const port_base = 10;
/// Octets of the server's first line, at most, and the octets one read of it takes.
pub const line_len_max = 64;
/// The first-request timeout of the server, as `src/server/constants.zig` holds it, and how far
/// from it the close may come: within one tick of the server and the time a round takes.
pub const first_request_timeout_ns: u64 = 5 * std.time.ns_per_s;
pub const close_margin_ns: u64 = 2 * std.time.ns_per_s;

/// Turns of the driver in one round before the program gives up, and the longest one turn waits
/// for the socket: 100 ms. A round thus ends within about a minute, even against a server that
/// never answers.
pub const turns_max = 512;
pub const wait_ns_max: u64 = 100 * std.time.ns_per_ms;
/// Calls of `receive` in one drain, and calls of `send_stream` for one `send`, at most.
pub const receive_calls_max = 4096;
pub const sends_per_event_max = 16;
/// Octets the socket read that the pool has not consumed yet, at most.
pub const held_len_max = 64 * 1024;
/// Octets of each buffer `storage` lends a response, and the details and metadata it reads.
pub const read_len = 4096;
pub const entries_max = 8;
/// Octets of each buffer one call writes its request into and reads its response into.
pub const call_buffer_len = 4096;
/// The server's address: the loopback address. The port goes in the pool's `Destination`.
pub const loopback = [_]u8{ 127, 0, 0, 1 };
pub const authority = "127.0.0.1";
