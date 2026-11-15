//! The interop client's limits (decision 42).
const std = @import("std");

/// The cases the client reads at most.
pub const cases_max = 64;
/// Octets of all the cases together.
pub const cases_bytes = 1024 * 1024;
/// Octets of all the cases' names together.
pub const names_bytes = 4096;
/// Octets of the CA's PEM.
pub const ca_pem_bytes = 16 * 1024;
/// Octets of the DER of the CA's certificate.
pub const certificate_bytes = 8 * 1024;
/// Octets of one output line.
pub const line_bytes = 1024;
/// The scenarios a run leaves out, at most.
pub const left_out_max = 16;
/// The base of the port number in the base URL.
pub const decimal = 10;

/// Octets of a message the client writes or reads: the largest coverage case, in JSON, with room.
pub const message_bytes = 256 * 1024;
/// Octets of a request body and of a response body: Collect sends every case, and Chat's answers
/// gather here until the client reads them.
pub const body_bytes = 1024 * 1024;
/// Octets of each piece of a streamed response that colibri hands the client.
pub const piece_bytes = 64 * 1024;
/// Octets of a response's header section and trailer section, and of the request's header values.
pub const field_bytes = 16 * 1024;
/// Octets of the JSON tokens the client reads at once: a bytes field in base64.
pub const token_bytes = 256 * 1024;
/// Octets of an error's message and details, and of the end-stream metadata.
pub const error_bytes = 64 * 1024;
/// The details of an error the client reads at most.
pub const details_max = 8;
/// The metadata lines of an end-stream message or a gRPC-Web trailers frame the client reads at
/// most.
pub const metadata_max = 32;

/// The longest one call runs before the client gives it up: 10 s.
pub const call_ns_max: u64 = 10 * std.time.ns_per_s;
/// The turns of the transport one wait takes at most. A turn ends at an event, a timer, or a read
/// of the socket, and waits 100 ms at most, so `call_ns_max` passes first.
pub const wait_turns_max = 1_000_000;
/// The messages one response piece holds, at most.
pub const answers_per_piece_max = 4096;

/// The depth of JSON values the comparison reads, at most: the recursion case nests messages a
/// few dozen deep.
pub const depth_max = 256;
/// Octets of the memory the two JSON trees are parsed into.
pub const tree_bytes = 8 * 1024 * 1024;

/// Octets of the reason a scenario failed, at most.
pub const reason_bytes = 512;

/// The copies `repeat` asks for.
pub const repeat_count = 3;
/// The timeout `inspect` sends.
pub const inspect_timeout_ns: u64 = 5 * std.time.ns_per_s;
/// The longest timeout the server may report to `inspect`: grpc-core rounds a deadline up to the
/// next 10 ms (interop/README.md).
pub const inspect_timeout_ms_max = 5010;
