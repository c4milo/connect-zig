//! The std_http example's limits (decision 42).

/// The octets of each buffer that the server or the client holds: a head, a body, a message.
pub const buffer_len = 16384;
/// The headers of a request or a response that either side copies, at most.
pub const headers_max = 32;
/// The messages that the server writes for one call, at most.
pub const replies_max = 4;
/// The requests the server reads from one connection, at most, before it closes it.
pub const requests_per_connection_max = 64;
/// The connections `zig build serve` takes one after another before the program ends.
pub const serve_connections_max = 1_000_000;
/// The connections the self-check opens: the std.http client keeps one for every call.
pub const check_connections = 1;
/// The address the server binds: loopback alone.
pub const address = "127.0.0.1";
/// The port the self-check binds: 0 lets the kernel choose.
pub const check_port = 0;
/// The redirects the client follows: none.
pub const redirect_buffer_len = 0;
/// The longest HTTP method name the server copies: "OPTIONS" and "CONNECT" have 7 letters.
pub const method_len_max = 8;
/// The details and the metadata entries that the client reads, at most.
pub const entries_max = 8;
/// The base of a port on the command line.
pub const decimal = 10;
