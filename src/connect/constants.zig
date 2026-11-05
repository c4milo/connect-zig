//! The connect module's named values: those the protocol documents fix, and the bounds this
//! module chose (design §6).
const std = @import("std");

/// Values the Connect protocol, gRPC over HTTP/2 and gRPC-Web fix.
pub const protocol = struct {
    /// An envelope's prefix: one flags octet and a 4-octet big-endian length (Connect protocol,
    /// "Streaming-Request"; gRPC PROTOCOL-HTTP2.md, "Length-Prefixed-Message").
    pub const envelope_prefix_len = 5;
    pub const flag_compressed: u8 = 0x01;
    /// Connect's end-stream message (Connect protocol, "Streaming-Response").
    pub const flag_end_stream: u8 = 0x02;
    /// gRPC-Web's trailers frame: the most significant bit of the flags (PROTOCOL-WEB.md).
    pub const flag_trailers: u8 = 0x80;
    /// Connect-Timeout-Ms holds at most 10 digits (Connect protocol, "Timeout").
    pub const connect_timeout_digits_max = 10;
    /// grpc-timeout holds at most 8 digits, then a unit (PROTOCOL-HTTP2.md, "Timeout").
    pub const grpc_timeout_digits_max = 8;
    /// The one protocol version Connect defines (Connect protocol, "Connect-Protocol-Version").
    pub const connect_protocol_version = "1";
    /// The HTTP status Connect gives `canceled`, which no HTTP RFC names (Connect protocol,
    /// "Error Codes").
    pub const status_client_closed_request: u16 = 499;
    /// The HTTP statuses the protocols name (RFC 9110 §15).
    pub const status = struct {
        pub const ok: u16 = 200;
        pub const bad_request: u16 = 400;
        pub const unauthorized: u16 = 401;
        pub const forbidden: u16 = 403;
        pub const not_found: u16 = 404;
        pub const method_not_allowed: u16 = 405;
        pub const conflict: u16 = 409;
        pub const unsupported_media_type: u16 = 415;
        pub const too_many_requests: u16 = 429;
        pub const internal_server_error: u16 = 500;
        pub const not_implemented: u16 = 501;
        pub const bad_gateway: u16 = 502;
        pub const service_unavailable: u16 = 503;
        pub const gateway_timeout: u16 = 504;
    };
    /// The largest Connect-Timeout-Ms: 10 digits.
    pub const connect_timeout_millis_max: u64 = 9_999_999_999;
    /// The largest grpc-timeout amount: 8 digits.
    pub const grpc_timeout_amount_max: u64 = 99_999_999;
    /// The nanoseconds of each grpc-timeout unit (PROTOCOL-HTTP2.md, "Timeout").
    pub const nanos_per_micro: u64 = 1_000;
    pub const nanos_per_milli: u64 = 1_000_000;
    pub const nanos_per_second: u64 = 1_000_000_000;
    pub const nanos_per_minute: u64 = 60_000_000_000;
    pub const nanos_per_hour: u64 = 3_600_000_000_000;
    /// A percent escape, "%XX": the sign and two hex digits (RFC 3986 §2.1).
    pub const percent_escape_len = 3;
    pub const hex_base = 16;
    pub const decimal_base = 10;
    /// grpc-message leaves the printable ASCII octets as they are, but "%" (PROTOCOL-HTTP2.md,
    /// "Responses").
    pub const printable_first: u8 = 0x20;
    pub const printable_last: u8 = 0x7e;
};

/// The bounds this module chose.
pub const limits = struct {
    /// The most envelopes one body holds that a reader walks: each takes at least 5 octets.
    pub const envelopes_max: usize = std.math.maxInt(u32);
    /// The most error details an error carries.
    pub const details_max = 32;
    /// The most metadata entries an end-stream message or a trailers frame carries.
    pub const metadata_max = 64;
    /// The most entries an Accept-Encoding-style list holds that the negotiation reads.
    pub const codings_max = 16;
    /// The most query pairs a unary GET carries that the parser reads.
    pub const query_pairs_max = 32;
    /// The deepest JSON nesting an error body or end-stream message holds.
    pub const json_depth_max = 16;
    /// The octets of base64 one string piece writes.
    pub const base64_piece_len = 64;
};

/// The halves a writer splits one storage into, when it writes two values at once: a Status and
/// its base64, or the status trailers and gRPC-Web's frame of them.
pub const storage_halves = 2;
