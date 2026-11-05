//! Message compression over stdx (decision 10). A coding names how a message's octets are
//! compressed: Connect's Content-Encoding and Connect-Content-Encoding, and gRPC's grpc-encoding
//! (Connect protocol, "Compression"; PROTOCOL-HTTP2.md, "Message-Encoding").
//!
//! gzip compresses and decompresses. zstd and br decompress only, at the stdx commit pinned, so a
//! server answers in gzip or identity alone.
const std = @import("std");
const assert = std.debug.assert;
const codec = @import("codec");
const gzip = @import("gzip");
const zstd = @import("zstd");
const brotli = @import("brotli");
const constants = @import("constants.zig");

pub const Coding = enum {
    identity,
    gzip,
    zstd,
    br,

    pub fn name(coding: Coding) []const u8 {
        return @tagName(coding);
    }

    /// The coding a header names. Coding names are case-insensitive (RFC 9110 §8.4.1).
    pub fn from_name(text: []const u8) ?Coding {
        const trimmed = std.mem.trim(u8, text, " \t");
        inline for (comptime std.enums.values(Coding)) |coding| {
            if (std.ascii.eqlIgnoreCase(trimmed, @tagName(coding))) return coding;
        }
        return null;
    }
};

/// The gzip encoder a caller places, at stdx's default level.
pub const GzipEncoder = gzip.Encoder(.{});

/// The gzip decoder a caller places.
pub const GzipDecoder = gzip.Decoder;

/// The decoders a caller placed. A coding whose decoder is null is not accepted.
pub const Decoders = struct {
    gzip: ?*gzip.Decoder = null,
    zstd: ?*zstd.HttpDecoder = null,
    brotli: ?*brotli.HttpDecoder = null,

    pub fn accepts(decoders: Decoders, coding: Coding) bool {
        return switch (coding) {
            .identity => true,
            .gzip => decoders.gzip != null,
            .zstd => decoders.zstd != null,
            .br => decoders.brotli != null,
        };
    }

    /// The codings these decoders accept, as an Accept-Encoding value: "gzip, zstd, br".
    pub fn accept_list(decoders: Decoders, buffer: *[accept_list_len_max]u8) []const u8 {
        var len: usize = 0;
        for ([_]Coding{ .gzip, .zstd, .br }) |coding| {
            if (!decoders.accepts(coding)) continue;
            const separator = if (len == 0) "" else ", ";
            const written = std.fmt.bufPrint(buffer[len..], "{s}{s}", .{ separator, coding.name() }) catch unreachable;
            len += written.len;
        }
        return buffer[0..len];
    }
};

/// The longest value `accept_list` writes: "gzip, zstd, br".
pub const accept_list_len_max = 16;

pub const Error = error{
    /// The message names a coding the decoders do not accept: Connect's unimplemented.
    UnsupportedCoding,
    /// The compressed octets are corrupt.
    CorruptMessage,
    /// The decompressed message does not fit the caller's buffer: resource_exhausted.
    MessageTooLarge,
};

/// Decompresses `input` into `output` and returns the message.
pub fn decompress(coding: Coding, decoders: Decoders, input: []const u8, output: []u8) Error![]const u8 {
    if (!decoders.accepts(coding)) return error.UnsupportedCoding;
    const features = codec.Features.target();
    const whole = switch (coding) {
        .identity => return input,
        .gzip => whole: {
            gzip.init(decoders.gzip.?, features);
            break :whole gzip.decode_all(decoders.gzip.?, input, output);
        },
        .zstd => whole: {
            decoders.zstd.?.init(features);
            break :whole decoders.zstd.?.decode_all(input, output);
        },
        .br => whole: {
            decoders.brotli.?.init(features);
            break :whole decoders.brotli.?.decode_all(input, output);
        },
    } catch |failure| return switch (failure) {
        error.NoSpaceLeft => error.MessageTooLarge,
        else => error.CorruptMessage,
    };
    return output[0..whole.written];
}

/// Compresses `input` with gzip into `output`.
pub fn compress_gzip(encoder: *GzipEncoder, input: []const u8, output: []u8) error{NoSpaceLeft}![]const u8 {
    encoder.init(codec.Features.target());
    const len = try encoder.encode_all(input, output);
    assert(len <= GzipEncoder.encoded_len_max(input.len));
    return output[0..len];
}

/// The coding a server answers in: the first one the peer's list names that the server
/// compresses with, which is gzip alone, or identity (Connect protocol, "Compression").
pub fn choose(accepted: []const u8, can_compress: bool) Coding {
    if (!can_compress) return .identity;
    var entries = std.mem.splitScalar(u8, accepted, ',');
    for (0..constants.limits.codings_max) |_| {
        const entry = entries.next() orelse return .identity;
        // RFC 9110 §12.4.2: a weight follows ";", and "q=0" means not acceptable.
        const end = std.mem.indexOfScalar(u8, entry, ';') orelse entry.len;
        if (weight(entry[end..]) > 0 and Coding.from_name(entry[0..end]) == .gzip) return .gzip;
    }
    return .identity;
}

/// The weight of an entry's parameters: 1 when they name none, and 0 for one that does not
/// parse (RFC 9110 §12.4.2).
fn weight(parameters: []const u8) f64 {
    const at = std.mem.indexOf(u8, parameters, "q=") orelse return 1;
    const rest = parameters[at + 2 ..];
    const end = std.mem.indexOfAny(u8, rest, "; \t") orelse rest.len;
    return std.fmt.parseFloat(f64, rest[0..end]) catch 0;
}

const testing = std.testing;

test "coding names are case-insensitive, and an unknown one is null" {
    try testing.expectEqual(@as(?Coding, .gzip), Coding.from_name(" GZIP"));
    try testing.expectEqual(@as(?Coding, null), Coding.from_name("snappy"));
}

test "a server picks gzip when the peer lists it, and identity otherwise" {
    try testing.expectEqual(Coding.gzip, choose("br, gzip", true));
    try testing.expectEqual(Coding.identity, choose("br, zstd", true));
    try testing.expectEqual(Coding.identity, choose("gzip;q=0", true));
    try testing.expectEqual(Coding.gzip, choose("gzip;q=0.5", true));
    try testing.expectEqual(Coding.identity, choose("gzip; q=0.0", true));
    try testing.expectEqual(Coding.identity, choose("gzip", false));
}

test "gzip round-trips, and a coding with no decoder or a small buffer is refused" {
    var encoder: GzipEncoder = undefined;
    var decoder: gzip.Decoder = undefined;
    const message = "hello hello hello hello";
    var compressed: [128]u8 = undefined;
    const packed_octets = try compress_gzip(&encoder, message, &compressed);
    var output: [64]u8 = undefined;
    const decoders: Decoders = .{ .gzip = &decoder };
    try testing.expectEqualStrings(message, try decompress(.gzip, decoders, packed_octets, &output));
    try testing.expectError(error.UnsupportedCoding, decompress(.zstd, decoders, packed_octets, &output));
    try testing.expectError(error.MessageTooLarge, decompress(.gzip, decoders, packed_octets, output[0..4]));
    try testing.expectError(error.CorruptMessage, decompress(.gzip, decoders, "not gzip at all", &output));
    var list: [accept_list_len_max]u8 = undefined;
    try testing.expectEqualStrings("gzip", decoders.accept_list(&list));
}
