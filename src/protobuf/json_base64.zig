//! JSON bytes: base64 text read into a binary field ("JSON Mapping", bytes). A parser accepts
//! the standard and the URL-safe alphabet, with or without padding, and stdx's decoder reads
//! both. It reads a text whose last letter sets pad bits too, as protobuf's parsers read it.
const std = @import("std");
const assert = std.debug.assert;
const platform = @import("platform");
const base64 = @import("base64");
const wire = @import("wire.zig");
const json_scalar = @import("json_scalar.zig");

pub const DecodeError = json_scalar.DecodeError;

/// The octets base64 text decodes to, written into `writer` after their length, in standard or
/// URL-safe base64, with or without padding ("JSON Mapping", bytes).
/// The decoder runs with the program's CPU features, `cpu_features`.
pub fn write_base64_field(octets: []const u8, writer: *wire.Writer, cpu_features: platform.CpuFeatures) DecodeError!void {
    // The length and the pad characters give the octets' count, so the length goes first.
    const len = base64.Decoder.decoded_len(octets) catch return error.InvalidBase64;
    try writer.varint(len);
    if (len > writer.buffer.len - writer.len) return error.NoSpaceLeft;
    // "JSON Mapping", bytes: a parser accepts either alphabet, but one alone in a text (RFC 4648
    // §5), with or without padding. RFC 4648 §3.5 lets a decoder refuse a last letter whose pad
    // bits are not zero; protobuf's parsers read it and drop the bits (the conformance suite's
    // "BytesFieldBase64Url"), so the decoder drops them. It takes the free room after the
    // length, whose slack its vector step uses, and writes `len` octets.
    var decoder: base64.Decoder = undefined;
    decoder.init(.{ .accept = .either, .padding = .optional, .pad_bits = .drop }, cpu_features);
    const decoded_len = decoder.decode_all(octets, writer.buffer[writer.len..]) catch return error.InvalidBase64;
    assert(decoded_len == len);
    writer.len += len;
}

const testing = std.testing;
const support = @import("test_support.zig");
const json = @import("json");

/// The JSON text `json_scalar.write` gives for bytes: base64 between quotes.
fn encoded(octets: []const u8, buffer: []u8) ![]const u8 {
    var text = json.TextWriter.init(buffer, .text, support.cpu_features);
    try json_scalar.write(.bytes, []const u8, octets, &text);
    return text.written();
}

test "base64 decodes in either alphabet, padded or not" {
    var buffer: [16]u8 = undefined;
    for ([_][]const u8{ "AP8=", "AP8", "_w==", "_w" }, [_][]const u8{ &.{ 0, 255 }, &.{ 0, 255 }, &.{255}, &.{255} }) |input, want| {
        var writer: wire.Writer = .{ .buffer = &buffer };
        try write_base64_field(input, &writer, support.cpu_features);
        try testing.expectEqualSlices(u8, want, writer.written()[1..]);
    }
    var writer: wire.Writer = .{ .buffer = &buffer };
    try testing.expectError(error.InvalidBase64, write_base64_field("A!", &writer, support.cpu_features));
    // A text that mixes the alphabets is neither.
    var mixed: wire.Writer = .{ .buffer = &buffer };
    try testing.expectError(error.InvalidBase64, write_base64_field("+_8=", &mixed, support.cpu_features));
}

test "base64 whose last letter sets pad bits reads as protobuf's parsers read it" {
    var buffer: [16]u8 = undefined;
    // "-_" is 0xfb and four pad bits set; "AP-_" and "AP_" set none. Each alphabet, padded or not.
    for ([_][]const u8{ "-_", "+/", "-_==", "AP8_", "AAAA-_", "AAA-" }, [_][]const u8{ &.{0xfb}, &.{0xfb}, &.{0xfb}, &.{ 0, 255, 63 }, &.{ 0, 0, 0, 0xfb }, &.{ 0, 0, 62 } }) |input, want| {
        var writer: wire.Writer = .{ .buffer = &buffer };
        try write_base64_field(input, &writer, support.cpu_features);
        try testing.expectEqualSlices(u8, want, writer.written()[1..]);
    }
    // Pad bits excuse nothing else: a letter neither alphabet has, or the two mixed.
    var bad: wire.Writer = .{ .buffer = &buffer };
    try testing.expectError(error.InvalidBase64, write_base64_field("A!-_", &bad, support.cpu_features));
    try testing.expectError(error.InvalidBase64, write_base64_field("+AAA-_", &bad, support.cpu_features));
}

test "bytes of each length write the base64 that std.base64 writes, and read back" {
    var octets: [200]u8 = undefined;
    for (&octets, 0..) |*octet, index| octet.* = @truncate(index * 7);
    // Short and long lengths, with each remainder of 3 among them.
    for ([_]usize{ 0, 1, 44, 45, 46, 90, 91, 200 }) |len| {
        var buffer: [300]u8 = undefined;
        const text = try encoded(octets[0..len], &buffer);
        var reference: [300]u8 = undefined;
        const want = std.base64.standard.Encoder.encode(&reference, octets[0..len]);
        try testing.expectEqualStrings(want, text[1 .. text.len - 1]);
        var room: [300]u8 = undefined;
        var writer: wire.Writer = .{ .buffer = &room };
        try write_base64_field(want, &writer, support.cpu_features);
        try testing.expectEqualSlices(u8, octets[0..len], writer.written()[writer.written().len - len ..]);
    }
}
