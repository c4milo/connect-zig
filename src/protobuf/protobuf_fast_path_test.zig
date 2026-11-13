//! The proof harness of the fast paths (pepegrillo's performance method, step 5): each path the
//! runtime takes for a common shape gives what a reference gives, on every short input and at
//! every boundary. The references here step once per octet, as the code before each fast path
//! did, and share no code with the paths they check.
//!
//! - Varints: every input of 1 and 2 octets, each value at a 7-bit boundary and one on each side
//!   of it, padded and truncated forms, at several offsets and in every room.
//! - UTF-8: every input of 1 and 2 octets, and each letter of the grammar at each place in ASCII
//!   text of each length to past the vector cutoff.
//! - Base64: every text of up to 4 letters over both alphabets, padding and a refused letter.
//! - A fuzz property over the same checks, which `zig build test` runs over its corpus.
const std = @import("std");
const testing = std.testing;
const wire = @import("wire.zig");
const scalar = @import("scalar.zig");
const json_scalar = @import("json_scalar.zig");
const constants = @import("constants.zig");

const varint_len_max = constants.protocol.varint_len_max;
const group_bits = constants.protocol.varint_group_bits;
const continuation = constants.protocol.varint_continuation;
const payload_mask = constants.protocol.varint_payload_mask;

/// The offsets a write starts at, so a path that assumes an aligned or empty buffer shows.
const write_offsets_count = 4;
/// The octet a sweep fills its buffer with first: a write that stores past its value shows.
const sentinel: u8 = 0xaa;
/// The room a write sweep gives past the longest varint, so a store past it shows.
const room_past_len = 2;
/// Room for the longest varint, its offset and the room past it.
const write_buffer_len = varint_len_max + write_offsets_count + room_past_len;
/// The vector cutoffs a UTF-8 sweep crosses: its text runs past twice the cutoff.
const utf8_cutoffs_crossed = 2;
/// The longest ASCII text a UTF-8 sweep places a letter in.
const utf8_text_len_max = utf8_cutoffs_crossed * constants.limits.utf8_vector_len_min + 1;
/// The longest letter of the UTF-8 grammar the sweep places, in octets.
const utf8_letter_len_max = 4;
/// The longest base64 text whose every form over the alphabet below the sweep reads.
const base64_text_len_max = 4;
/// Room for what any base64 text of the sweeps decodes to, and its length.
const base64_room_len = 64;
/// Base64 writes 4 characters for each 3 octets, so a padded text is a multiple of 4 (RFC 4648 §4).
const base64_chars = 4;
/// The most octets one fuzz input holds.
const fuzz_input_len_max = 64;

/// What a varint read gives: the value or the refusal, and where the reader stands after it.
const Read = struct { value: wire.Error!u64, position: usize };

/// Reads a varint one octet at a time ("Base 128 Varints"): the loop `Reader.varint` ran before
/// its one-octet path.
fn reference_read(bytes: []const u8, start: usize) Read {
    var position = start;
    var value: u64 = 0;
    for (0..varint_len_max) |index| {
        if (position == bytes.len) return .{ .value = error.Truncated, .position = position };
        const octet = bytes[position];
        position += 1;
        const shift: u6 = @intCast(index * group_bits);
        value |= @as(u64, octet & payload_mask) << shift;
        if (octet & continuation == 0) return .{ .value = value, .position = position };
    }
    return .{ .value = error.VarintTooLong, .position = position };
}

/// Writes `value` as a varint one group at a time and returns its length ("Base 128 Varints").
pub fn reference_write(value: u64, out: *[varint_len_max]u8) usize {
    var rest = value;
    for (out, 1..) |*octet, len| {
        const low: u8 = @truncate(rest & payload_mask);
        rest >>= group_bits;
        if (rest == 0) {
            octet.* = low;
            return len;
        }
        octet.* = low | continuation;
    }
    unreachable;
}

/// The values at the ends of the range, which no 7-bit boundary gives.
const extreme_values = [_]u64{ 0, 1, std.math.maxInt(u64) - 1, std.math.maxInt(u64) };
/// The values at each boundary: one below it, the power of two, and one above it.
const values_per_boundary = 3;
/// How many values `each_boundary` gives.
pub const boundary_values_count = extreme_values.len + values_per_boundary * (varint_len_max - 1);

/// The values `each_boundary` gives, in `out`.
pub fn boundary_values(out: *[boundary_values_count]u64) void {
    var index: usize = 0;
    for (extreme_values) |value| {
        out[index] = value;
        index += 1;
    }
    for (1..varint_len_max) |groups| {
        const boundary = @as(u64, 1) << @intCast(groups * group_bits);
        out[index..][0..values_per_boundary].* = .{ boundary - 1, boundary, boundary + 1 };
        index += values_per_boundary;
    }
}

/// Calls `check` with 0, 1, each power of two at a 7-bit boundary and one on each side of it,
/// and the two largest values: every length a varint takes, at both of its ends.
fn each_boundary(check: *const fn (u64) anyerror!void) anyerror!void {
    var values: [boundary_values_count]u64 = @splat(0);
    boundary_values(&values);
    for (values) |value| try check(value);
}

fn check_read(bytes: []const u8, start: usize) !void {
    const want = reference_read(bytes, start);
    var reader: wire.Reader = .{ .bytes = bytes, .position = start };
    const got = reader.varint();
    const want_value = want.value catch |refusal| return testing.expectError(refusal, got);
    try testing.expectEqual(want_value, try got);
    try testing.expectEqual(want.position, reader.position);
}

/// A value's encoding, read alone, after another octet, padded to each longer length, and cut
/// short at each length.
fn check_read_value(value: u64) anyerror!void {
    var encoded: [varint_len_max + 1]u8 = @splat(0);
    const len = reference_write(value, encoded[0..varint_len_max]);
    try check_read(encoded[0..len], 0);
    for (0..len) |cut| try check_read(encoded[0..cut], 0);
    var shifted: [varint_len_max + 1]u8 = @splat(sentinel);
    @memcpy(shifted[1..][0..len], encoded[0..len]);
    try check_read(shifted[0 .. len + 1], 1);
    // "Base 128 Varints": a parser reads a varint padded with groups of zero bits.
    var padded = encoded;
    for (len..varint_len_max + 1) |padded_len| {
        try check_read(padded[0..padded_len], 0);
        padded[padded_len - 1] |= continuation;
        padded[padded_len] = 0;
        try check_read(padded[0 .. padded_len + 1], 0);
    }
}

/// Which varint call a write sweep checks: `varint`, or binary encode's `varint_wide`.
const Write = enum { plain, wide };

fn check_write_room(comptime write: Write, want: []const u8, value: u64, offset: usize, room: usize) !void {
    var buffer: [write_buffer_len]u8 = @splat(sentinel);
    var writer: wire.Writer = .{ .buffer = buffer[0 .. offset + room], .len = offset };
    var end = offset;
    const written = switch (write) {
        .plain => writer.varint(value),
        .wide => writer.varint_wide(value),
    };
    if (written) |_| {
        try testing.expect(room >= want.len);
        try testing.expectEqualSlices(u8, want, buffer[offset..writer.len]);
        end = writer.len;
    } else |refusal| {
        try testing.expectEqual(error.NoSpaceLeft, refusal);
        try testing.expect(room < want.len);
        try testing.expectEqual(offset, writer.len);
    }
    // Nothing past the value changes: a length is written in place before octets already there.
    for (buffer[end..]) |octet| try testing.expectEqual(sentinel, octet);
}

/// A value written at each offset into each room, from none to past its length.
fn check_write_value(value: u64) anyerror!void {
    var want: [varint_len_max]u8 = @splat(0);
    const len = reference_write(value, &want);
    try testing.expectEqual(len, wire.varint_len(value));
    for (0..write_offsets_count) |offset| {
        for (0..varint_len_max + room_past_len) |room| {
            try check_write_room(.plain, want[0..len], value, offset, room);
            try check_write_room(.wide, want[0..len], value, offset, room);
        }
    }
}

test "a varint reads as the reference reads it, on every input of one and two octets" {
    for (0..256) |first| {
        try check_read(&.{@intCast(first)}, 0);
        for (0..256) |second| try check_read(&.{ @intCast(first), @intCast(second) }, 0);
    }
}

test "a varint reads as the reference reads it, at every boundary, padded and cut short" {
    try each_boundary(check_read_value);
    // Eleven octets with the continuation bit: too long. A tenth octet past bit 63 drops its bits.
    try check_read(&([_]u8{0xff} ** 10 ++ [_]u8{0x01}), 0);
    try check_read(&([_]u8{0xff} ** 9 ++ [_]u8{0x7f}), 0);
}

test "a varint writes as the reference writes it, at every boundary, offset and room" {
    try each_boundary(check_write_value);
}

/// The letters of the UTF-8 grammar (RFC 3629 §4) a sweep places, the refused ones among them:
/// a lone continuation octet, an octet UTF-8 never uses, an overlong form, a surrogate, a code
/// point past U+10FFFF, and a lead octet whose continuation is missing.
const utf8_letters = [_][]const u8{
    "\x7f",             "\xc2\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80",
    "\x80",             "\xff",     "\xc0\x80",     "\xed\xa0\x80",
    "\xf4\x90\x80\x80", "\xe2\x82", "\xc2",
};

fn check_utf8(octets: []const u8) !void {
    try testing.expectEqual(std.unicode.utf8ValidateSlice(octets), scalar.is_utf8(octets));
}

test "a string is UTF-8 as the standard library judges it, on every input of one and two octets" {
    for (0..256) |first| {
        try check_utf8(&.{@intCast(first)});
        for (0..256) |second| try check_utf8(&.{ @intCast(first), @intCast(second) });
    }
}

test "a string is UTF-8 as the standard library judges it, with each letter at each place" {
    var text: [utf8_text_len_max + utf8_letter_len_max]u8 = @splat('a');
    for (0..utf8_text_len_max + 1) |len| {
        try check_utf8(text[0..len]);
        for (utf8_letters) |letter| {
            for (0..len + 1) |place| {
                @memset(&text, 'a');
                @memcpy(text[place..][0..letter.len], letter);
                try check_utf8(text[0 .. len + letter.len]);
            }
        }
    }
}

/// The bytes of a base64 text, decoded as `write_base64_field` decoded them through
/// `std.base64`, before stdx's decoder: it chose the alphabet by a search for "-" and "_". It
/// stays the reference, a decoder written apart from stdx's.
fn reference_base64(octets: []const u8, writer: *wire.Writer) json_scalar.DecodeError!void {
    const url_safe = std.mem.indexOfAny(u8, octets, "-_") != null;
    const padded = octets.len % base64_chars == 0 and octets.len != 0 and octets[octets.len - 1] == '=';
    const decoder = if (url_safe)
        (if (padded) std.base64.url_safe.Decoder else std.base64.url_safe_no_pad.Decoder)
    else
        (if (padded) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder);
    const len = decoder.calcSizeForSlice(octets) catch return error.InvalidBase64;
    try writer.varint(len);
    if (len > writer.buffer.len - writer.len) return error.NoSpaceLeft;
    decoder.decode(writer.buffer[writer.len..][0..len], octets) catch return error.InvalidBase64;
    writer.len += len;
}

fn check_base64(octets: []const u8) !void {
    var want_room: [base64_room_len]u8 = @splat(0);
    var want: wire.Writer = .{ .buffer = &want_room };
    const want_result = reference_base64(octets, &want);
    var got_room: [base64_room_len]u8 = @splat(0);
    var got: wire.Writer = .{ .buffer = &got_room };
    const got_result = json_scalar.write_base64_field(octets, &got);
    if (want_result) |_| try got_result else |refusal| try testing.expectError(refusal, got_result);
    // A refusal fails the whole decode, which drops the writer, so what it holds then is no result.
    if (want_result) |_| try testing.expectEqualSlices(u8, want.written(), got.written()) else |_| {}
}

/// Letters of both base64 alphabets (RFC 4648 §4 and §5), padding, and a letter neither has.
const base64_letters = "Az09+/-_=!";

test "base64 decodes as the reference decodes it, on every text of up to four letters" {
    var text: [base64_text_len_max]u8 = @splat('A');
    var total: usize = 1;
    for (0..base64_text_len_max + 1) |len| {
        for (0..total) |index| {
            var rest = index;
            for (text[0..len]) |*letter| {
                letter.* = base64_letters[rest % base64_letters.len];
                rest /= base64_letters.len;
            }
            try check_base64(text[0..len]);
        }
        total *= base64_letters.len;
    }
}

test "base64 decodes as the reference decodes it, with each letter at each place of longer text" {
    var text: [base64_room_len / 2]u8 = @splat('A');
    for (0..text.len + 1) |len| {
        for (base64_letters) |letter| {
            for (0..len) |place| {
                @memset(&text, 'A');
                text[place] = letter;
                try check_base64(text[0..len]);
            }
        }
    }
}

/// One fuzz input through every check above: a varint read from its octets, its octets as a
/// string and as base64 text, and its first eight octets as a varint written.
fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
    var input: [fuzz_input_len_max]u8 = @splat(0);
    const len = smith.slice(&input);
    const octets = input[0..len];
    try check_read(octets, 0);
    try check_utf8(octets);
    try check_base64(octets);
    if (octets.len >= @sizeOf(u64)) try check_write_value(std.mem.readInt(u64, octets[0..@sizeOf(u64)], .little));
}

test "fuzz: each fast path gives what its reference gives, on any input" {
    try testing.fuzz({}, fuzz_one, .{ .corpus = &.{
        "\x96\x01",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01",
        "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x00",
        "AP8=",
        "_w-_+/==",
        "données, 日本語 — ünïcode",
        "abcdefghijklmnopqrstuvwxyz0123456789\xc0\x80",
    } });
}
