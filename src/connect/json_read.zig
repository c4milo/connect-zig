//! What the error body and the end-stream message share when they read JSON: a reader of tokens,
//! storage that keeps a token's octets past the next read, and a skip of a value no field names.
const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const codec = @import("codec");
const base64 = @import("base64");
const constants = @import("constants.zig");

pub const Error = json.DecodeError || error{ Truncated, NoSpaceLeft, UnexpectedToken, DepthExceeded, InvalidBase64, TooManyDetails, TooManyMetadata };

/// Decodes base64 in the alphabets `accept` names into the start of `buffer`, with its padding or
/// without: a decoder accepts both (Connect protocol, "Error End-Stream"; gRPC PROTOCOL-HTTP2.md,
/// "-bin" headers). The decoder may write past the octets it returns, in `buffer`'s free room.
pub fn decode_base64(accept: base64.Accept, text: []const u8, buffer: []u8) error{ InvalidBase64, NoSpaceLeft }![]u8 {
    const len = base64.Decoder.decoded_len(text) catch return error.InvalidBase64;
    if (len > buffer.len) return error.NoSpaceLeft;
    var decoder: base64.Decoder = undefined;
    decoder.init(.{ .accept = accept, .padding = .optional }, codec.Features.target());
    const decoded_len = decoder.decode_all(text, buffer) catch return error.InvalidBase64;
    assert(decoded_len == len);
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
        const kept = try decode_base64(.standard, octets, self.storage[self.used..]);
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
/// The base64 letters one string piece writes, under one cache line, so the staging buffer
/// costs a few stores a call.
const piece_len = 60;
/// The calls of the base64 encoder past one for each full piece: a part piece, and the end.
const base64_calls_extra = 2;

/// Writes `octets` as one string of unpadded standard base64, in pieces. One encoder takes the
/// whole value, and each call fills the staging buffer.
pub fn write_base64(octets: []const u8, text: *json.TextWriter) (json.EncodeError || error{NoSpaceLeft})!void {
    var buffer: [piece_len]u8 = undefined;
    var encoder: base64.Encoder = undefined;
    encoder.init(.{ .alphabet = .standard, .padding = false }, codec.Features.target());
    var start: usize = 0;
    // Bounded: each call but the last fills the buffer. Base64 writes 4 letters for each 3 octets.
    for (0..octets.len / (piece_len / base64_chars * base64_octets) + base64_calls_extra) |_| {
        const progress = encoder.encode(octets[start..], &buffer, .finish);
        start += progress.consumed;
        const last = progress.status == .done;
        try text.write(.{ .string = if (last) .last else .more }, buffer[0..progress.written]);
        if (last) return;
    }
    unreachable;
}

const testing = std.testing;

test "base64 decodes padded or not, in the alphabets asked, and refuses a partial padding" {
    var buffer: [8]u8 = undefined;
    // Connect protocol, "Error End-Stream", and gRPC's "-bin" headers: padded or not.
    for ([_][]const u8{ "/w==", "/w" }) |text| try testing.expectEqualSlices(u8, &.{0xff}, try decode_base64(.standard, text, &buffer));
    // The URL-safe alphabet is read only where the caller names it.
    try testing.expectError(error.InvalidBase64, decode_base64(.standard, "_w", &buffer));
    try testing.expectEqualSlices(u8, &.{0xff}, try decode_base64(.either, "_w", &buffer));
    // RFC 4648 §4: pad characters complete a quantum of four, so one too few or too many fails.
    try testing.expectError(error.InvalidBase64, decode_base64(.standard, "/w=", &buffer));
    try testing.expectError(error.InvalidBase64, decode_base64(.standard, "/w===", &buffer));
    try testing.expectError(error.NoSpaceLeft, decode_base64(.standard, "AAAA", buffer[0..2]));
}
