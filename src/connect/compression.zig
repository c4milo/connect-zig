//! Message compression over stdx (decision 10). A coding names how a message's octets are
//! compressed: Connect's Content-Encoding and Connect-Content-Encoding, and gRPC's grpc-encoding
//! (Connect protocol, "Compression"; PROTOCOL-HTTP2.md, "Message-Encoding").
//!
//! gzip, zstd and br compress and decompress. A server answers in the first coding the peer
//! lists that it holds an encoder for.
const std = @import("std");
const assert = std.debug.assert;
const platform = @import("stdx").platform;
const gzip = @import("stdx").compress.gzip;
const zstd = @import("stdx").compress.zstd;
const brotli = @import("stdx").compress.brotli;
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

/// The zstd encoder a caller places: level 1, and a window of one block, 128 KiB, which an RPC
/// message rarely outgrows and which keeps the encoder small (stdx decisions 12 and 13).
pub const ZstdEncoder = zstd.Encoder(.{ .level = zstd_level, .window_log = zstd_window_log });
const zstd_level = 1;
const zstd_window_log = 17;

/// The brotli encoder a caller places: level 1, and a window of 128 KiB, as the zstd encoder's
/// (decision 10 as amended). RFC 7932 §9.1 names the window's size WBITS.
pub const BrotliEncoder = brotli.Encoder(.{ .level = brotli_level, .window_bits = brotli_window_bits });
const brotli_level = 1;
const brotli_window_bits = 17;

/// The encoders a caller placed. A coding whose encoder is null is not written.
pub const Encoders = struct {
    gzip: ?*GzipEncoder = null,
    zstd: ?*ZstdEncoder = null,
    brotli: ?*BrotliEncoder = null,

    pub fn writes(encoders: *const Encoders, coding: Coding) bool {
        return switch (coding) {
            .identity => true,
            .gzip => encoders.gzip != null,
            .zstd => encoders.zstd != null,
            .br => encoders.brotli != null,
        };
    }
};

/// The gzip decoder a caller places.
pub const GzipDecoder = gzip.Decoder;

/// The zstd decoder a caller places, with HTTP's window limit (RFC 9659 §3).
pub const ZstdDecoder = zstd.HttpDecoder;

/// The brotli decoder a caller places.
pub const BrotliDecoder = brotli.HttpDecoder;

/// The decoders a caller placed. A coding whose decoder is null is not accepted.
pub const Decoders = struct {
    gzip: ?*GzipDecoder = null,
    zstd: ?*ZstdDecoder = null,
    brotli: ?*BrotliDecoder = null,

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

/// Decompresses `input` into `output` and returns the message. Each decoder's fast paths use
/// `cpu_features`, the program's CPU features: gzip's CRC-32 among them, which a build for a
/// generic CPU otherwise computes from a table (decision 10 as amended).
pub fn decompress(coding: Coding, decoders: Decoders, input: []const u8, output: []u8, cpu_features: platform.CpuFeatures) Error![]const u8 {
    if (!decoders.accepts(coding)) return error.UnsupportedCoding;
    const whole = switch (coding) {
        .identity => return input,
        .gzip => whole: {
            decoders.gzip.?.init(cpu_features);
            break :whole decoders.gzip.?.decode_all(input, output);
        },
        .zstd => whole: {
            decoders.zstd.?.init(cpu_features);
            break :whole decoders.zstd.?.decode_all(input, output);
        },
        .br => whole: {
            decoders.brotli.?.init(cpu_features);
            break :whole decoders.brotli.?.decode_all(input, output);
        },
    } catch |failure| return switch (failure) {
        error.NoSpaceLeft => error.MessageTooLarge,
        else => error.CorruptMessage,
    };
    return output[0..whole.written];
}

/// Compresses `input` with `coding`, which `encoders` writes, into `output`. Each encoder's fast
/// paths use `cpu_features`, the program's CPU features.
pub fn compress(coding: Coding, encoders: *const Encoders, input: []const u8, output: []u8, cpu_features: platform.CpuFeatures) error{NoSpaceLeft}![]const u8 {
    assert(coding != .identity and encoders.writes(coding));
    const len = switch (coding) {
        .gzip => len: {
            encoders.gzip.?.init(cpu_features);
            break :len try encoders.gzip.?.encode_all(input, output);
        },
        .zstd => len: {
            encoders.zstd.?.init(cpu_features);
            break :len try encoders.zstd.?.encode_all(input, output);
        },
        .br => len: {
            encoders.brotli.?.init(cpu_features);
            break :len try encoders.brotli.?.encode_all(input, output);
        },
        .identity => unreachable,
    };
    return output[0..len];
}

/// The coding a server answers in: the first one the peer's list names that `encoders` writes,
/// or identity (Connect protocol, "Compression").
pub fn choose(accepted: []const u8, encoders: *const Encoders) Coding {
    var entries = std.mem.splitScalar(u8, accepted, ',');
    for (0..constants.limits.codings_max) |_| {
        const entry = entries.next() orelse return .identity;
        // RFC 9110 §12.4.2: a weight follows ";", and "q=0" means not acceptable.
        const end = std.mem.indexOfScalar(u8, entry, ';') orelse entry.len;
        const coding = Coding.from_name(entry[0..end]) orelse continue;
        if (coding != .identity and weight(entry[end..]) > 0 and encoders.writes(coding)) return coding;
    }
    return .identity;
}

/// The weight of an entry's parameters: 1 when they name none, and 0 for one that does not
/// parse (RFC 9110 §12.4.2).
fn weight(parameters: []const u8) f64 {
    const marker = "q=";
    const at = std.mem.indexOf(u8, parameters, marker) orelse return 1;
    const rest = parameters[at + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, "; \t") orelse rest.len;
    return std.fmt.parseFloat(f64, rest[0..end]) catch 0;
}

const testing = std.testing;

test "coding names are case-insensitive, and an unknown one is null" {
    try testing.expectEqual(@as(?Coding, .gzip), Coding.from_name(" GZIP"));
    try testing.expectEqual(@as(?Coding, null), Coding.from_name("snappy"));
}

/// The codecs the tests place: too large for a test's stack.
const codecs = @import("codec_test_support.zig");

test "a server answers in the first coding the peer lists that it writes" {
    const both: Encoders = .{ .gzip = &codecs.gzip_encoder, .zstd = &codecs.zstd_encoder };
    try testing.expectEqual(Coding.gzip, choose("br, gzip", &both));
    try testing.expectEqual(Coding.zstd, choose("br, zstd, gzip", &both));
    try testing.expectEqual(Coding.gzip, choose("zstd, gzip", &.{ .gzip = &codecs.gzip_encoder }));
    try testing.expectEqual(Coding.identity, choose("br", &both));
    try testing.expectEqual(Coding.identity, choose("gzip;q=0", &both));
    try testing.expectEqual(Coding.gzip, choose("gzip;q=0.5", &both));
    try testing.expectEqual(Coding.identity, choose("gzip; q=0.0", &both));
    try testing.expectEqual(Coding.identity, choose("gzip, zstd", &.{}));
    // br is written once its encoder is placed, and a weight of 0 still refuses it.
    const all: Encoders = .{ .gzip = &codecs.gzip_encoder, .zstd = &codecs.zstd_encoder, .brotli = &codecs.brotli_encoder };
    try testing.expectEqual(Coding.br, choose("br, gzip", &all));
    try testing.expectEqual(Coding.gzip, choose("br;q=0, gzip", &all));
}

test "a coding is written only with its encoder placed" {
    const none: Encoders = .{};
    try testing.expect(none.writes(.identity));
    inline for (.{ Coding.gzip, Coding.zstd, Coding.br }) |coding| try testing.expect(!none.writes(coding));
    try testing.expect((Encoders{ .gzip = &codecs.gzip_encoder }).writes(.gzip));
    try testing.expect((Encoders{ .zstd = &codecs.zstd_encoder }).writes(.zstd));
    try testing.expect((Encoders{ .brotli = &codecs.brotli_encoder }).writes(.br));
    // Each encoder writes its own coding alone.
    try testing.expect(!(Encoders{ .gzip = &codecs.gzip_encoder, .zstd = &codecs.zstd_encoder }).writes(.br));
    try testing.expect(!(Encoders{ .brotli = &codecs.brotli_encoder }).writes(.zstd));
}

test "gzip round-trips, and a coding with no decoder or a small buffer is refused" {
    var decoder: gzip.Decoder = undefined;
    const message = "hello hello hello hello";
    var compressed: [128]u8 = undefined;
    const packed_octets = try compress(.gzip, &.{ .gzip = &codecs.gzip_encoder }, message, &compressed, codecs.cpu_features);
    var output: [64]u8 = undefined;
    const decoders: Decoders = .{ .gzip = &decoder };
    try testing.expectEqualStrings(message, try decompress(.gzip, decoders, packed_octets, &output, codecs.cpu_features));
    try testing.expectError(error.UnsupportedCoding, decompress(.zstd, decoders, packed_octets, &output, codecs.cpu_features));
    try testing.expectError(error.MessageTooLarge, decompress(.gzip, decoders, packed_octets, output[0..4], codecs.cpu_features));
    try testing.expectError(error.CorruptMessage, decompress(.gzip, decoders, "not gzip at all", &output, codecs.cpu_features));
    var list: [accept_list_len_max]u8 = undefined;
    try testing.expectEqualStrings("gzip", decoders.accept_list(&list));
}

test "each codec runs with the features its caller gives" {
    const message = "features features features features";
    var compressed: [128]u8 = undefined;
    var output: [64]u8 = undefined;
    var decoder: gzip.Decoder = undefined;
    var reference: gzip.Decoder = undefined;
    // The CRC-32 path each gzip codec takes shows the features it ran with.
    inline for (.{ platform.CpuFeatures.none(), codecs.cpu_features }) |cpu_features| {
        const packed_octets = try compress(.gzip, &.{ .gzip = &codecs.gzip_encoder }, message, &compressed, cpu_features);
        try testing.expectEqualStrings(message, try decompress(.gzip, .{ .gzip = &decoder }, packed_octets, &output, cpu_features));
        reference.init(cpu_features);
        try testing.expectEqual(reference.crc32_path, decoder.crc32_path);
        try testing.expectEqual(reference.crc32_path, codecs.gzip_encoder.crc32_path);
    }
}

test "zstd round-trips through stdx's encoder and decoder" {
    const message = "zstd zstd zstd zstd zstd zstd zstd zstd";
    var compressed: [128]u8 = undefined;
    const packed_octets = try compress(.zstd, &.{ .zstd = &codecs.zstd_encoder }, message, &compressed, codecs.cpu_features);
    // RFC 8878 §3.1.1: a Zstandard frame starts with its magic number, 0xFD2FB528, little-endian.
    try testing.expectEqualSlices(u8, &.{ 0x28, 0xb5, 0x2f, 0xfd }, packed_octets[0..4]);
    var output: [64]u8 = undefined;
    try testing.expectEqualStrings(message, try decompress(.zstd, .{ .zstd = &codecs.zstd_decoder }, packed_octets, &output, codecs.cpu_features));
}

test "brotli round-trips through stdx's encoder and decoder" {
    const message = "brotli brotli brotli brotli brotli brotli";
    var compressed: [128]u8 = undefined;
    const encoders: Encoders = .{ .brotli = &codecs.brotli_encoder };
    const packed_octets = try compress(.br, &encoders, message, &compressed, codecs.cpu_features);
    try testing.expect(packed_octets.len < message.len);
    // Decision 10 as amended: level 1, which the size of the encoder follows.
    try testing.expect(!BrotliEncoder.level_five);
    // RFC 7932 §9.1: a stream starts with WBITS, and 17 is the seven bits 0000001.
    const wbits_mask = 0x7f;
    const wbits_17 = 0x01;
    try testing.expectEqual(@as(u8, wbits_17), packed_octets[0] & wbits_mask);
    var output: [64]u8 = undefined;
    codecs.brotli_window_decoder.init(codecs.cpu_features);
    const whole = try codecs.brotli_window_decoder.decode_all(packed_octets, &output);
    try testing.expectEqualStrings(message, output[0..whole.written]);
    // A stream the buffer does not hold is the caller's to make room for.
    try testing.expectError(error.NoSpaceLeft, compress(.br, &encoders, message, compressed[0..4], codecs.cpu_features));
}
