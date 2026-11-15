//! The std.Io server's limits (decision 42).
const std = @import("std");

/// The port the server listens on when its command line names none, and the base of the port
/// that the command line names.
pub const port_default = 8080;
pub const port_base = 10;

/// Sockets the server serves at once, at most. One past them waits in the kernel's backlog until
/// a socket closes, as `colibri.Server` rules (decision 31).
pub const connections_max = 16;
/// Octets one read of a socket takes, at most: the payload of one message to the owner.
pub const chunk_len = 4096;
/// Octets of a socket the engine has not consumed yet, at most. A connection past it fails.
pub const held_len_max = 64 * 1024;
/// Octets one `send_stream` writes, at most.
pub const output_len = 16 * 1024;
/// Messages that wait for the owner, at most. A task that finds the queue full waits.
pub const queue_len = 32;
/// The longest a deadline of the engine waits past its instant: 50 ms.
pub const tick_ns = 50 * std.time.ns_per_ms;
/// A socket that sends no request for 5 s closes. The self-check waits for this close, and
/// `src/client/constants.zig` holds the same value.
pub const first_request_timeout_ns = 5 * std.time.ns_per_s;
/// Messages the owner takes, sockets the server accepts and ticks it counts before it stops: far
/// past any run, so every loop of the program is bounded.
pub const messages_max = std.math.maxInt(u64);
/// Reads of one socket before its reader stops, at most.
pub const reads_max = std.math.maxInt(u64);
/// Calls of `receive` in one pass over a socket's octets, passes of one step, and calls of
/// `send_stream` in one flush, at most.
pub const events_per_step_max = 64;
pub const passes_max = 16;
pub const sends_per_flush_max = 16;

/// Calls the router answers at once, and room for one reply with its headers and for one call's
/// request body.
pub const requests = 8;
pub const response_bytes = 64 * 1024;
pub const body_bytes = 64 * 1024;
