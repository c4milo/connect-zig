//! The protobuf module's named limits and the values the encoding fixes. Every bound a loop or a
//! recursion in this module obeys is named here (TigerStyle, docs/decisions.md entry 4).
const std = @import("std");

/// The protobuf encoding's own values (https://protobuf.dev/programming-guides/encoding/).
pub const protocol = struct {
    /// A varint holds at most 64 bits in 7-bit groups, so at most 10 bytes ("Base 128 Varints").
    pub const varint_len_max = 10;
    /// The largest field number: 2^29 - 1 ("Field Numbers", language guide).
    pub const field_number_max: u32 = (1 << 29) - 1;
    /// Field numbers 19000 to 19999 are reserved for the implementation ("Field Numbers").
    pub const reserved_number_first: u32 = 19_000;
    pub const reserved_number_last: u32 = 19_999;
    /// The low three bits of a tag hold the wire type ("Message Structure").
    pub const wire_type_bits = 3;
    /// A fixed32 field is 4 bytes and a fixed64 field 8 bytes, little-endian ("Non-varint Numbers").
    pub const fixed32_len = 4;
    pub const fixed64_len = 8;
    /// A varint carries 7 bits in each byte, least significant group first; the high bit says
    /// another byte follows ("Base 128 Varints").
    pub const varint_group_bits = 7;
    pub const varint_continuation: u8 = 0x80;
    pub const varint_payload_mask: u8 = 0x7f;
};

/// The bounds this module chose.
pub const limits = struct {
    /// The deepest nesting of messages and groups `decode` follows. The reference implementations
    /// use 100 as their default recursion limit, and the conformance suite expects it.
    pub const depth_max = 100;
    /// The most bytes one encoded message may hold: 2 GiB - 1, the encoding's own limit
    /// ("Size Limitations").
    pub const message_len_max: usize = (1 << 31) - 1;
    /// The most fields a generated message names. A loop over a descriptor's fields is bounded
    /// by its length, which is checked against this at comptime.
    pub const fields_max = 4096;
    /// The most elements an iterator over a `Repeated` field yields. An element takes at least
    /// one byte, so a message of `message_len_max` bytes holds no more.
    pub const elements_max: usize = message_len_max;
    /// The length a nested message's prefix takes when the JSON transcoder writes it before it
    /// knows the length: 5 bytes hold any length below 2^35, padded with continuation bits.
    pub const padded_length_len = 5;
    /// The deepest nesting of JSON values the transcoder follows.
    pub const json_depth_max = depth_max;
};

comptime {
    std.debug.assert(limits.padded_length_len * 7 >= 31);
    std.debug.assert(protocol.varint_len_max * 7 >= 64);
}
