//! JSON bytes: base64 text read into a binary field ("JSON Mapping", bytes). A parser accepts
//! the standard and the URL-safe alphabet, with or without padding, and stdx's decoder reads
//! both; a text whose last letter sets pad bits is read here too, as protobuf's parsers read it.
const std = @import("std");
const assert = std.debug.assert;
const codec = @import("codec");
const base64 = @import("base64");
const wire = @import("wire.zig");
const json_scalar = @import("json_scalar.zig");

pub const DecodeError = json_scalar.DecodeError;

/// The octets base64 text decodes to, written into `writer` after their length, in standard or
/// URL-safe base64, with or without padding ("JSON Mapping", bytes).
pub fn write_base64_field(octets: []const u8, writer: *wire.Writer) DecodeError!void {
    // The length and the pad characters give the octets' count, so the length goes first.
    const len = base64.Decoder.decoded_len(octets) catch return error.InvalidBase64;
    try writer.varint(len);
    if (len > writer.buffer.len - writer.len) return error.NoSpaceLeft;
    // "JSON Mapping", bytes: a parser accepts either alphabet, but one alone in a text (RFC 4648
    // §5), with or without padding. The decoder takes the free room after the length, whose slack
    // its vector step uses, and writes `len` octets.
    var decoder: base64.Decoder = undefined;
    decoder.init(.{ .accept = .either, .padding = .optional }, codec.Features.target());
    // A refusal drops its reason and returns, as before this path existed, so the decode of a
    // valid text compiles alike: the path out of line finds the reason again.
    const decoded_len = decoder.decode_all(octets, writer.buffer[writer.len..]) catch
        return decode_pad_bits_set(octets, len, writer);
    assert(decoded_len == len);
    writer.len += len;
}

/// Decodes a text stdx refused, when its one fault is a last letter whose pad bits are not
/// zero. RFC 4648 §3.5 lets a decoder refuse such a text, and stdx's does; protobuf's parsers
/// read it and drop the bits (the conformance suite's "BytesFieldBase64Url"). It reads every
/// letter itself, in one alphabet alone (RFC 4648 §5), and `decoded_len` checked the padding
/// and the length, so it refuses each fault stdx refuses but the pad bits. It calls no
/// stdx decoder: a second caller made LLVM stop inlining stdx's decode into the first, and a
/// valid text's decode took 0.7% more instructions. Out of line, as it runs for refused texts.
noinline fn decode_pad_bits_set(octets: []const u8, len: usize, writer: *wire.Writer) DecodeError!void {
    const output = writer.buffer[writer.len..];
    const letters = std.mem.trimEnd(u8, octets, &.{base64.constants.pad});
    // Only a last quantum of two or three letters holds pad bits.
    if (letters.len % base64.constants.quantum_letters < base64.constants.one_octet_letters) return error.InvalidBase64;
    var seen: ?base64.Alphabet = null;
    var bits: u32 = 0;
    var held: usize = 0;
    var out_len: usize = 0;
    for (letters) |letter| {
        if (alphabet_of(letter)) |own| {
            if (seen != null and seen.? != own) return error.InvalidBase64;
            seen = own;
        }
        bits = bits << base64.constants.letter_bits | try letter_value(letter);
        held += 1;
        if (held == base64.constants.quantum_letters) {
            out_len = try put_octets(output, out_len, bits, base64.constants.group_octets);
            bits = 0;
            held = 0;
        }
    }
    const unused = held * base64.constants.letter_bits % base64.constants.octet_bits;
    out_len = try put_octets(output, out_len, bits >> @intCast(unused), held * base64.constants.letter_bits / base64.constants.octet_bits);
    assert(out_len == len);
    writer.len += len;
}

/// Writes the low `count` octets of `value` at `at`, most significant first, and returns the
/// position past them.
fn put_octets(output: []u8, at: usize, value: u32, count: usize) DecodeError!usize {
    if (count > output.len - at) return error.NoSpaceLeft;
    for (0..count) |index| {
        const shift = (count - 1 - index) * base64.constants.octet_bits;
        output[at + index] = @truncate(value >> @intCast(shift));
    }
    return at + count;
}

/// The alphabet a letter belongs to alone: "+" and "/" to the standard one, "-" and "_" to the
/// URL-safe one. Every other letter is in both, and names neither.
fn alphabet_of(letter: u8) ?base64.Alphabet {
    return switch (letter) {
        '+', '/' => .standard,
        '-', '_' => .url_safe,
        else => null,
    };
}

/// The number a letter of either base64 alphabet stands for (RFC 4648 §4 and §5).
fn letter_value(letter: u8) DecodeError!u32 {
    const lower_first = 26;
    const digit_first = 52;
    const sixty_two = 62;
    const sixty_three = 63;
    return switch (letter) {
        'A'...'Z' => letter - 'A',
        'a'...'z' => letter - 'a' + lower_first,
        '0'...'9' => letter - '0' + digit_first,
        '+', '-' => sixty_two,
        '/', '_' => sixty_three,
        else => error.InvalidBase64,
    };
}

const testing = std.testing;
const json = @import("json");

/// The JSON text `json_scalar.write` gives for bytes: base64 between quotes.
fn encoded(octets: []const u8, buffer: []u8) ![]const u8 {
    var text = json.TextWriter.init(buffer, .text, codec.Features.target());
    try json_scalar.write(.bytes, []const u8, octets, &text);
    return text.written();
}

test "base64 decodes in either alphabet, padded or not" {
    var buffer: [16]u8 = undefined;
    for ([_][]const u8{ "AP8=", "AP8", "_w==", "_w" }, [_][]const u8{ &.{ 0, 255 }, &.{ 0, 255 }, &.{255}, &.{255} }) |input, want| {
        var writer: wire.Writer = .{ .buffer = &buffer };
        try write_base64_field(input, &writer);
        try testing.expectEqualSlices(u8, want, writer.written()[1..]);
    }
    var writer: wire.Writer = .{ .buffer = &buffer };
    try testing.expectError(error.InvalidBase64, write_base64_field("A!", &writer));
    // A text that mixes the alphabets is neither.
    var mixed: wire.Writer = .{ .buffer = &buffer };
    try testing.expectError(error.InvalidBase64, write_base64_field("+_8=", &mixed));
}

test "base64 whose last letter sets pad bits reads as protobuf's parsers read it" {
    var buffer: [16]u8 = undefined;
    // "-_" is 0xfb and four pad bits set; "AP-_" and "AP_" set none. Each alphabet, padded or not.
    for ([_][]const u8{ "-_", "+/", "-_==", "AP8_", "AAAA-_", "AAA-" }, [_][]const u8{ &.{0xfb}, &.{0xfb}, &.{0xfb}, &.{ 0, 255, 63 }, &.{ 0, 0, 0, 0xfb }, &.{ 0, 0, 62 } }) |input, want| {
        var writer: wire.Writer = .{ .buffer = &buffer };
        try write_base64_field(input, &writer);
        try testing.expectEqualSlices(u8, want, writer.written()[1..]);
    }
    // Pad bits excuse nothing else: a letter neither alphabet has, or the two mixed.
    var bad: wire.Writer = .{ .buffer = &buffer };
    try testing.expectError(error.InvalidBase64, write_base64_field("A!-_", &bad));
    try testing.expectError(error.InvalidBase64, write_base64_field("+AAA-_", &bad));
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
        try write_base64_field(want, &writer);
        try testing.expectEqualSlices(u8, octets[0..len], writer.written()[writer.written().len - len ..]);
    }
}
