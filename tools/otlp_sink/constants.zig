//! The OTLP sink's limits (decision 42).

/// The port the sink binds when the command line names none: OTLP's port for gRPC (OTLP
/// specification, "OTLP/gRPC").
pub const port_default = 4317;
/// The base of the port number on the command line.
pub const decimal = 10;
/// TCP connections at once: the production model's 516, one for each of 33,000 servers over a
/// gateway tier of 64 cores, and room for the probe. A connection past them is accepted and
/// closed, so its client learns it at once.
pub const tcp_connections = 528;
/// QUIC connections at once. The benchmark sends none, but the server binds UDP too.
pub const quic_connections = 1;
/// Calls the router answers at once: as many as the benchmark has in flight, at most. Each call
/// holds about 1.8 MiB: `storage_bytes`, two buffers of `message_bytes` for its request, and
/// `body_bytes`. So these calls take the largest part of the sink's memory. A call past them is
/// answered 503 at once, which gRPC reads as UNAVAILABLE and an OpenTelemetry exporter retries.
pub const requests = 64;
/// The longest export a call reads: the benchmark's largest request holds 512 spans in about
/// 192 KB, and an OpenTelemetry SDK sends at most 512 spans in one export by default.
pub const message_bytes = 256 * 1024;
/// The storage each call decodes its request's lists into (decision 37): spans, attributes and
/// events. A decoded export takes about 3.6 times its octets, so the production model's export of
/// 512 spans, 233 KB, takes about 850 KB. A list past the storage's end stays in the message, and
/// a reader of it, `protovalidate.Interceptor` among them, decodes it again: with 256 KiB, that
/// cost validation 0.83 µs a span of that export, and with room 0.11 µs (`zig build
/// otlp-validate-cost`).
pub const storage_bytes = 1_048_576;
/// Room for one call's request body: the message, and its gRPC prefix.
pub const body_bytes = message_bytes + 1024;
/// Room for one reply with its headers and trailers: an empty message, or the count's line.
pub const response_bytes = 4 * 1024;
/// The longest reply message the export route writes: OTLP's reply to an export is empty, and it
/// goes out within `response_bytes` with its headers. The route's two reply buffers take this
/// and not `message_bytes`, which saves about 0.5 MiB a call.
pub const reply_bytes = response_bytes;
/// The path that answers with the count of what the sink took.
pub const count_path = "/sink/count";
