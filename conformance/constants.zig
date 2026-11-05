//! The conformance server's named sizes (design §8 step 7).

/// The runner's message receive limit is 200 KiB (connectconformance v1.0.4,
/// `serverReceiveLimit`). A message holds at most this many octets, so the limit always fits.
pub const message_bytes = 512 * 1024;
/// The longest JSON token of a request. The JSON cases carry short strings.
pub const token_bytes = 64 * 1024;
/// The octets one call's echo of its requests holds: two requests at the runner's limit, with
/// room for the rest of each message.
pub const requests_bytes = 512 * 1024;
/// The requests one call echoes, at most.
pub const requests_max = 64;
/// The octets of the first request of a stream, which holds the response definition.
pub const definition_bytes = 64 * 1024;
/// The responses one stream writes, at most.
pub const responses_max = 64;
/// The query parameters a GET echoes, at most, and their decoded octets.
pub const query_pairs_max = 32;
pub const query_bytes = 4096;
/// The calls the router answers at once. The runner sends 16 at a time by default.
pub const requests_at_once = 16;
/// Octets of each call's response memory: a stream's every message, each echoing two requests
/// at the runner's limit.
pub const response_bytes = 640 * 1024;
/// Octets of each call's request body memory: a whole unary body at the runner's limit, or the
/// part of an envelope a stream has not read yet, up to `message_bytes`.
pub const body_bytes = message_bytes + 1024;
/// The sockets the server holds at once: as many as the socket loop names. The runner's client
/// opens a connection for each test case and leaves it open once the case ends.
pub const sockets_max = 128;
/// The octets one socket reads, and writes, before the endpoint takes them. It holds a whole h2
/// frame of the largest size a peer may send by default, with its header (RFC 9113 §4.2).
pub const socket_buffer_len = 64 * 1024;
/// How long a connection waits for its first request, and then between requests, before the
/// server closes it. The runner's client leaves each test case's connection open, so the server
/// closes them soon to keep sockets free for the cases that follow.
pub const first_request_timeout_ns = 5 * 1_000_000_000;
pub const idle_timeout_ns = 1_000_000_000;
/// The longest ServerCompatRequest the server reads from stdin: a TLS key and certificates at
/// most, which the server refuses.
pub const compat_request_bytes_max = 64 * 1024;
/// The octets of the ServerCompatResponse the server writes to stdout.
pub const compat_response_bytes = 256;
/// The 4-octet big-endian length before each message on stdin and stdout (connectconformance
/// `--help`: "a fixed-32-bit length"; docs/testing_servers.md: "network-byte-order").
pub const length_prefix_len = 4;
/// Milliseconds in a nanosecond count, for `timeout_ms`.
pub const nanos_per_milli = 1_000_000;
