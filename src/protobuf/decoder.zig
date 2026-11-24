//! `Decoder`: what decodes a message, binary or JSON, with the program's CPU features. A program
//! makes one as it starts, with the features it detected once, and decodes with it from then on.
//! The decode checks each string of its input for UTF-8 with those features, once: a repeated
//! field's iterator and `Lazy.get` read the checked bytes later and check them no more.
const std = @import("std");
const platform = @import("platform");
const constants = @import("constants.zig");
const decode_file = @import("decode.zig");
const json_decode = @import("json_decode.zig");
const json_scalar = @import("json_scalar.zig");
const any = @import("any.zig");

/// What a `decode_into_use` took of its storage: the octets it filled from the start, and whether
/// a repeated field or a `Lazy` field found no room. Such a field points into the input, and each
/// read of it parses it again, so a program that sees `short` gives the decode more storage
/// (decision 37).
pub const StorageUse = struct {
    octets: usize = 0,
    short: bool = false,
};

pub const Decoder = struct {
    /// The CPU features each check of the input runs with: the program's, which it detects once
    /// with stdx's `platform.CpuFeatures.detect`.
    cpu_features: platform.CpuFeatures,

    pub fn init(cpu_features: platform.CpuFeatures) Decoder {
        return .{ .cpu_features = cpu_features };
    }

    /// Decodes `bytes` as a `T`. Strings, bytes and repeated fields point into `bytes`.
    pub fn decode(decoder: *const Decoder, comptime T: type, bytes: []const u8) decode_file.Error!T {
        // "Size Limitations": a message holds less than 2 GiB.
        if (bytes.len > constants.limits.message_len_max) return error.LengthTooLarge;
        return decode_file.decode_depth(T, bytes, constants.limits.depth_max, .checked, &decoder.cpu_features);
    }

    /// Decodes `bytes` as `decode` does, and reads each repeated field's elements, and each
    /// `Lazy` field's message, into `storage` while it has room. A later read of them parses
    /// nothing again, so a program that reads every field takes this call. A field that finds no
    /// room points into `bytes`, as `decode` leaves it. The message points into both, which must
    /// outlive it (decision 37).
    pub fn decode_into(decoder: *const Decoder, comptime T: type, bytes: []const u8, storage: []u8) decode_file.Error!T {
        // Its own body, not a call of `decode_into_use`: through that call, the compiler laid out
        // the benchmark's decode and walk of `varints` in 2,225 instructions where this takes 2,022.
        if (bytes.len > constants.limits.message_len_max) return error.LengthTooLarge;
        var store: decode_file.Store = .{ .buffer = storage, .cpu_features = &decoder.cpu_features };
        return decode_file.decode_depth(T, bytes, constants.limits.depth_max, .stored, &store);
    }

    /// Decodes as `decode_into` does, and writes what the decode took of `storage` to `use`.
    pub fn decode_into_use(decoder: *const Decoder, comptime T: type, bytes: []const u8, storage: []u8, use: *StorageUse) decode_file.Error!T {
        if (bytes.len > constants.limits.message_len_max) return error.LengthTooLarge;
        var store: decode_file.Store = .{ .buffer = storage, .cpu_features = &decoder.cpu_features };
        const message = try decode_file.decode_depth(T, bytes, constants.limits.depth_max, .stored, &store);
        use.* = .{ .octets = store.len, .short = store.short };
        return message;
    }

    /// Merges `bytes` into `message`, as a later occurrence of the same message merges ("Last One
    /// Wins", encoding guide).
    pub fn merge(decoder: *const Decoder, comptime T: type, message: *T, bytes: []const u8) decode_file.Error!void {
        if (bytes.len > constants.limits.message_len_max) return error.LengthTooLarge;
        return decode_file.merge_depth(T, message, bytes, constants.limits.depth_max, .checked, &decoder.cpu_features);
    }

    /// Reads the proto3 JSON text `text` as a `T` (decision 9). It writes the binary encoding into
    /// `binary`, and the message's strings and bytes point into it. `tokens` holds one token's
    /// octets at a time, so a string as long as the longest one in the text fits.
    pub fn decode_json(decoder: *const Decoder, comptime T: type, text: []const u8, binary: []u8, tokens: []u8) json_scalar.DecodeError!T {
        return decode_transcoded(T, try json_decode.transcode(T, text, binary, tokens, decoder.cpu_features, any.types));
    }

    /// `decode_json`, with an Any naming its type from the well-known types and `any_types`.
    pub fn decode_json_with(decoder: *const Decoder, comptime T: type, text: []const u8, binary: []u8, tokens: []u8, comptime any_types: []const type) json_scalar.DecodeError!T {
        return decode_transcoded(T, try json_decode.transcode(T, text, binary, tokens, decoder.cpu_features, any.with(any_types)));
    }
};

/// Decodes the binary the transcoder wrote (decision 9). The transcoder read the JSON to its full
/// depth and checked each value as it wrote it, its strings included (RFC 8259 §8.1), so
/// `decode`'s check of each nested payload would read the subtree again: the binary decodes one
/// level, as `Lazy.get` decodes bytes that `decode` checked. A test holds that what the
/// transcoder writes passes `decode` whole.
fn decode_transcoded(comptime T: type, bytes: []const u8) json_scalar.DecodeError!T {
    return decode_file.decode_shallow(T, bytes);
}
