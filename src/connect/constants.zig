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
};
