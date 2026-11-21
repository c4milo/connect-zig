//! The conformance server's named sizes (design §8 step 7), the client's, and the protobuf
//! testee's (decision 38).

/// The runner's message receive limit is 200 KiB (connectconformance v1.0.7,
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
/// The TCP connections the server holds at once. The runner's grpc-go client opens a connection
/// for each of its test cases, about 180 in a run, and leaves it open once the case ends.
pub const sockets_max = 512;
/// How long a connection waits for its first request, and then between requests, before the
/// server closes it. Both waits pass the 90 s that Go's client keeps a connection (net/http's
/// DefaultTransport, IdleConnTimeout). Go's client opens connections it may not use at once, and
/// keeps them. A client can send a request into a connection in the instant the server closes
/// it, and read "unexpected EOF". At a first-request wait of 5 s, CI's run 173 failed one h11
/// case; at 50 ms, 24 cases in a run failed. An idle wait of 1 s failed 1 case in 40 runs.
pub const first_request_timeout_ns = 120 * 1_000_000_000;
pub const idle_timeout_ns = 120 * 1_000_000_000;
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

// The conformance client's named sizes (design §8 step 7, the client half).

/// The runner's client receive limit is 1 MiB (connectconformance v1.0.7,
/// `clientReceiveLimit`), and a request at the limit grows by its echo. A message the client
/// writes or reads holds at most this many octets.
pub const client_message_bytes = 2 * 1024 * 1024;
/// The longest JSON token the client reads: a bytes field of a message at the limit, in base64.
pub const client_token_bytes = 3 * 1024 * 1024;
/// Octets of a call's request body and of its response body: two messages at the limit, the
/// most a client stream of the suite sends or a response echoes.
pub const client_body_bytes = 6 * 1024 * 1024;
/// Octets of each piece of a streamed response that colibri hands the client.
pub const client_piece_bytes = 64 * 1024;
/// Octets of a response's header section, and of its trailer section: each line's name and
/// value and four octets (colibri decision 152).
pub const client_field_bytes = 64 * 1024;
/// Octets of a call's error message, details and end-stream metadata.
pub const client_error_bytes = 64 * 1024;
/// The details of an error the client reads, and the metadata lines of an end-stream message
/// or a gRPC-Web trailers frame.
pub const client_details_max = 16;
pub const client_metadata_max = 64;
/// The longest ClientCompatRequest the client reads: two request messages at the limit.
pub const client_compat_request_bytes = 6 * 1024 * 1024;
/// Octets of a ClientCompatResponse, and of the ClientResponseResult it is built from: the
/// payloads of a call, each of which echoes the requests at the limit.
pub const client_compat_response_bytes = 16 * 1024 * 1024;
/// The test cases one run of the client reads, at most. The runner sends a few thousand.
pub const client_cases_max = 1_000_000;
/// The header lines one response holds, the request messages of one case, and the response
/// messages of one call, at most.
pub const client_fields_max = 256;
pub const client_requests_max = 64;
pub const client_responses_max = 1024;
/// Octets of the authority the client names: an IPv6 literal in brackets and a port.
pub const client_authority_bytes = 64;
/// Octets the client reads from its socket at once.
pub const client_socket_input_bytes = 64 * 1024;
/// The turns of one call's loop before the client gives the call up: a turn ends at an event,
/// a timer, or a read of the socket, and the longest case waits a few seconds.
pub const client_turns_max = 1_000_000;
/// The pool's events one turn reads, at most.
pub const client_events_per_turn_max = 4096;
/// The longest a turn waits on its socket with nothing due: 100 ms.
pub const client_wait_ns_max = 100 * nanos_per_milli;
/// How long a call waits, past its timeout or with none, for the pool's events before it gives
/// up: 30 s.
pub const client_call_ns_max = 30 * 1_000_000_000;
/// Octets of an error detail's type URL: its prefix and a full name.
pub const client_type_url_bytes = 256;
/// Octets of the DER of the server certificate the client trusts: one RSA-2048 certificate.
pub const client_certificate_bytes = 8 * 1024;
/// Octets of a datagram the client reads: the largest UDP payload (RFC 768), and of one it
/// writes: what an Ethernet path carries (RFC 9000 §14 asks for 1200 at least).
pub const client_datagram_in_bytes = 64 * 1024;
pub const client_datagram_out_bytes = 1500;

// The protobuf testee's named sizes (decision 38).

/// The length before each request and each response of Google's protobuf conformance runner:
/// 4 octets, little-endian ("conformance/conformance.proto").
pub const testee_frame_prefix_len = 4;
/// The largest test message, in either encoding, and the room a response takes beside it.
pub const testee_message_len_max = 1 << 20;
pub const testee_response_overhead_len = 64;
/// The longest JSON token: a string's octets.
pub const testee_token_len_max = 1 << 16;
/// Octets of the testee's stdin buffer, and of its stdout buffer.
pub const testee_io_buffer_len = 1 << 12;
/// The requests one run of the runner sends stay far below this bound.
pub const testee_requests_max = 1 << 24;

// The protovalidate executor's named sizes (decision 47).

/// The longest TestConformanceRequest the executor reads: the descriptors of every schema of
/// the suite, about 1 MiB, and one suite's cases.
pub const executor_request_bytes_max = 32 * 1024 * 1024;
/// The octets of one case's result, encoded: its name and its violations.
pub const executor_result_bytes = 256 * 1024;
/// The octets of one case's report: room for the violations of a case that breaks many rules.
pub const executor_report_bytes = 256 * 1024;
/// The octets stdin and stdout each buffer.
pub const executor_io_buffer_len = 64 * 1024;
/// The most cases of one request. The suite holds fewer than 3,000 in all.
pub const executor_cases_max = 65_536;
/// The nanoseconds of one second, for the time the executor passes to `validate`.
pub const executor_nanos_per_second = 1_000_000_000;
/// The backward branches the compiler may take while it lists one schema's messages: the suite's
/// largest file declares about 250.
pub const executor_eval_branches = 100_000;
