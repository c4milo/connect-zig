//! A route reads and writes each message with the CPU features of the program's context
//! (decision 10 as amended): a request in gzip is inflated on the path those features pick.
const std = @import("std");
const testing = std.testing;
const connect = @import("connect");
const proto = @import("protobuf");
const platform = @import("stdx").platform;
const support = @import("pull_test_support.zig");

/// The codecs of the test: too large for a test's stack.
threadlocal var gzip_encoder: connect.GzipEncoder align(@alignOf(connect.GzipEncoder)) = undefined;
threadlocal var gzip_decoder: connect.GzipDecoder align(@alignOf(connect.GzipDecoder)) = undefined;
/// A decoder the test starts itself, which names the path a set of features picks.
threadlocal var reference: connect.GzipDecoder align(@alignOf(connect.GzipDecoder)) = undefined;

/// Room for one note, its gzip, and its envelope.
const note_bytes = 64;
const coded_bytes = 128;
const window = 4096;

test "a route inflates a request with the context's CPU features, and no others" {
    // The CRC-32 path the gzip decoder took shows the features it ran with. Where the build
    // target holds a carry-less multiply, the two contexts take two paths.
    inline for (.{ platform.CpuFeatures.none(), support.cpu_features }) |cpu_features| {
        var note: [note_bytes]u8 = undefined;
        const encoded = try proto.encode(support.Note, &.{ .text = "3" }, &note);
        var coded: [coded_bytes]u8 = undefined;
        const packed_octets = try connect.compression.compress(.gzip, &.{ .gzip = &gzip_encoder }, encoded, &coded, cpu_features);
        var envelope: [coded_bytes + connect.constants.protocol.envelope_prefix_len]u8 = undefined;
        const bytes = try connect.envelope.write(.{ .compressed = true }, packed_octets, &envelope);

        var fixture: support.Fixture = .{ .engine = .{}, .app = .{ .cpu_features = cpu_features, .codings = .{ .decoders = .{ .gzip = &gzip_decoder } } } };
        // The decoder starts on the other path, so that only the route's own start picks it.
        gzip_decoder.init(if (std.meta.eql(cpu_features, platform.CpuFeatures.none())) support.cpu_features else .none());
        fixture.open_coded("/test.Svc/Count", "application/grpc+proto", "gzip");
        fixture.send_octets(bytes, true);
        try fixture.drain(window);
        var notes = fixture.notes();
        try notes.expect_count(3);

        reference.init(cpu_features);
        try testing.expectEqual(reference.crc32_path, gzip_decoder.crc32_path);
    }
}
