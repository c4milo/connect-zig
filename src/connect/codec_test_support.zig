//! The codecs the connect module's tests place: one encoder and one decoder of each coding the
//! module writes. Each is too large for a test's stack, so each test thread holds one set.
//!
//! The tests share this one set. A test binary for aarch64 Linux reaches its thread-local data
//! through local-exec relocations, which reach 16 MiB (`R_AARCH64_TLSLE_ADD_TPREL_HI12`). The
//! zstd decoder alone takes about 8.7 MB, so a set in each test file overran that reach. A test
//! uses a codec for one message at a time, so a server and a client in one test take turns.
const compression = @import("compression.zig");

pub threadlocal var gzip_encoder: compression.GzipEncoder align(@alignOf(compression.GzipEncoder)) = undefined;
pub threadlocal var gzip_decoder: compression.GzipDecoder align(@alignOf(compression.GzipDecoder)) = undefined;
pub threadlocal var zstd_encoder: compression.ZstdEncoder align(@alignOf(compression.ZstdEncoder)) = undefined;
pub threadlocal var zstd_decoder: compression.ZstdDecoder align(@alignOf(compression.ZstdDecoder)) = undefined;

/// The decoders of the set, as a server or a client takes them.
pub fn decoders() compression.Decoders {
    return .{ .gzip = &gzip_decoder, .zstd = &zstd_decoder };
}

/// The encoders of the set, as a server or a client takes them.
pub fn encoders() compression.Encoders {
    return .{ .gzip = &gzip_encoder, .zstd = &zstd_encoder };
}
