//! The quickstart's limits (decision 42).

/// The longest message a method reads or writes, and the longest greeting.
pub const message_bytes = 4096;
pub const greeting_len_max = 256;
/// Calls the router answers at once, and room for one call's request body and for one reply with
/// its headers: each above `message_bytes` (README, "Route it").
pub const requests = 8;
pub const body_bytes = 8192;
pub const response_bytes = 8192;
/// TCP connections and QUIC connections the server holds at once.
pub const tcp_connections = 8;
pub const quic_connections = 8;
/// The longest PEM file a program reads: a certificate chain, its key, or a CA bundle.
pub const pem_len_max = 16 * 1024;
/// The octets of the DER in a PEM file, at most: base64 writes 3 octets as 4 letters (RFC 7468
/// §2).
pub const der_len_max = pem_len_max / 4 * 3;
/// The CA certificates the client trusts, at most.
pub const anchors_max = 1;
/// Octets of each buffer one call writes its request into and reads its response into, and the
/// details and metadata a response reads, at most.
pub const call_buffer_len = 4096;
pub const entries_max = 8;
/// The calls of one round: Greet in Connect, and Greet in gRPC.
pub const calls_per_round = 2;
/// The loopback address, where the server listens and the client connects.
pub const loopback = [_]u8{ 127, 0, 0, 1 };
/// The base of the port number on the command line.
pub const decimal = 10;
