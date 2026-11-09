//! What the error body and the end-stream message share when they read JSON: a reader of tokens,
//! storage that keeps a token's octets past the next read, and a skip of a value no field names.
const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const codec = @import("codec");
const constants = @import("constants.zig");

pub const Error = json.DecodeError || error{ Truncated, NoSpaceLeft, UnexpectedToken, DepthExceeded, InvalidBase64, TooManyDetails, TooManyMetadata };

/// Decodes base64 into the start of `buffer`, with its padding or without: a decoder accepts
/// both (Connect protocol, "Error End-Stream"; gRPC PROTOCOL-HTTP2.md, "-bin" headers).
pub fn decode_base64(decoder: std.base64.Base64Decoder, text: []const u8, buffer: []u8) error{ InvalidBase64, NoSpaceLeft }![]u8 {
    const trimmed = std.mem.trimEnd(u8, text, "=");
    const len = decoder.calcSizeForSlice(trimmed) catch return error.InvalidBase64;
    if (len > buffer.len) return error.NoSpaceLeft;
    decoder.decode(buffer[0..len], trimmed) catch return error.InvalidBase64;
    return buffer[0..len];
}

pub const Tokens = struct {
    reader: json.TextReader,
    /// Where octets that outlive their token are copied.
    storage: []u8,
    used: usize = 0,

    pub fn init(text: []const u8, tokens: []u8, storage: []u8) Tokens {
        return .{ .reader = json.TextReader.init(text, tokens, .text, codec.Features.target()), .storage = storage };
    }

    pub fn start(self: *Tokens) Error!void {
        if (!self.reader.next_text()) return error.UnexpectedToken;
    }

    pub fn next(self: *Tokens) Error!json.TextReader.Item {
        const item = try self.reader.next();
        return item orelse error.UnexpectedToken;
    }

    pub fn expect(self: *Tokens, kind: json.Kind) Error!void {
        const item = try self.next();
        if (item != kind) return error.UnexpectedToken;
    }

    /// The octets of a string token, copied into the storage.
    pub fn keep_string(self: *Tokens) Error![]const u8 {
        return switch (try self.next()) {
            .string => |octets| self.keep(octets),
            else => error.UnexpectedToken,
        };
    }

    pub fn keep(self: *Tokens, octets: []const u8) Error![]const u8 {
        if (octets.len > self.storage.len - self.used) return error.NoSpaceLeft;
        const kept = self.storage[self.used..][0..octets.len];
        @memcpy(kept, octets);
        self.used += octets.len;
        return kept;
    }

    /// Decodes base64, padded or not, into the storage (Connect protocol, "Error End-Stream":
    /// decoders accept both).
    pub fn keep_base64(self: *Tokens) Error![]const u8 {
        const octets = switch (try self.next()) {
            .string => |octets| octets,
            else => return error.UnexpectedToken,
        };
        const kept = try decode_base64(std.base64.standard_no_pad.Decoder, octets, self.storage[self.used..]);
        self.used += kept.len;
        return kept;
    }

    /// Skips the value whose first token is next, nested at most `constants.limits.json_depth_max`.
    pub fn skip_value(self: *Tokens) Error!void {
        var depth: u32 = 0;
        for (0..self.reader.input.len + 1) |_| {
            switch (try self.next()) {
                .begin_object, .begin_array => {
                    depth += 1;
                    if (depth > constants.limits.json_depth_max) return error.DepthExceeded;
                },
                .end_object, .end_array => {
                    assert(depth > 0);
                    depth -= 1;
                },
                else => {},
            }
            if (depth == 0) return;
        }
        unreachable;
    }

    pub fn finish(self: *Tokens) Error!void {
        if (try self.reader.next() != null) return error.UnexpectedToken;
    }
};

const base64_chars = 4;
const base64_octets = 3;
/// The base64 octets one string piece writes, under one cache line, so the staging buffer
/// costs a few stores a call.
const piece_len = 60;

/// Writes `octets` as one string of unpadded standard base64, in pieces.
pub fn write_base64(octets: []const u8, text: *json.TextWriter) (json.EncodeError || error{NoSpaceLeft})!void {
    const encoder = std.base64.standard_no_pad.Encoder;
    // Base64 writes 4 characters for each 3 octets.
    const chunk_len = piece_len / base64_chars * base64_octets;
    var buffer: [piece_len]u8 = undefined;
    var start: usize = 0;
    for (0..octets.len / chunk_len + 1) |_| {
        const end = @min(start + chunk_len, octets.len);
        const piece = encoder.encode(&buffer, octets[start..end]);
        const last = end == octets.len;
        try text.write(.{ .string = if (last) .last else .more }, piece);
        if (last) return;
        start = end;
    }
    unreachable;
}
