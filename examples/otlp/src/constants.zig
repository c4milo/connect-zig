//! The OTLP example's limits and the values of its spans (decision 42).

/// Calls the router answers at once, and room for one call's request body and for one reply with
/// its headers: the kept requests of the receiver, at most 32 KiB, and the headers.
pub const requests = 8;
pub const body_bytes = 48 * 1024;
pub const response_bytes = 48 * 1024;

/// The spans of the example's trace, which each export sends.
pub const spans_per_export = 3;
/// The trace's ID, 16 octets, and the ID of each span, 8 octets (OTLP: trace and span IDs).
pub const trace_id = [16]u8{ 0x5b, 0x8e, 0xff, 0xf7, 0x98, 0x03, 0x81, 0x03, 0xd2, 0x69, 0xb6, 0x33, 0x81, 0x3f, 0xc6, 0x0c };
pub const checkout_span_id = [8]u8{ 0xee, 0xe1, 0x9b, 0x7e, 0xc3, 0xc1, 0xb1, 0x74 };
pub const query_span_id = [8]u8{ 0xee, 0xe1, 0x9b, 0x7e, 0xc3, 0xc1, 0xb1, 0x75 };
pub const charge_span_id = [8]u8{ 0xee, 0xe1, 0x9b, 0x7e, 0xc3, 0xc1, 0xb1, 0x76 };
/// The instants of the trace, in nanoseconds since 1970: it starts at 2027-01-15T08:00:00Z.
pub const start_ns: u64 = 1_800_000_000_000_000_000;
pub const query_start_ns: u64 = start_ns + 2_000_000;
pub const query_end_ns: u64 = start_ns + 9_000_000;
pub const charge_start_ns: u64 = start_ns + 10_000_000;
pub const charge_end_ns: u64 = start_ns + 41_000_000;
pub const end_ns: u64 = start_ns + 45_000_000;
/// The values of the attributes, one of each kind OTLP carries.
pub const status_code = 200;
pub const retries = 2;
pub const ratio = 0.5;
