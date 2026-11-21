//! The first place of an octet in a string, for the checks of a string's form. Most strings a
//! form check reads are shorter than a vector, where `std.mem.indexOfScalar` compares one octet
//! a step. This search compares eight octets a step in a 64-bit word.
const std = @import("std");

/// The octets of one step.
const word_len = @sizeOf(u64);
/// One octet of value 1 in each place of a word.
const low_bits: u64 = std.math.maxInt(u64) / std.math.maxInt(u8);
/// The top bit of each octet of a word.
const top_bits: u64 = low_bits << (word_len - 1);
/// The length from which `std.mem.indexOfScalar` compares a vector of octets a step.
const vector_len = std.simd.suggestVectorLength(u8) orelse word_len;

/// The place of the first `octet` of `text`, or null when `text` holds none.
pub fn index_of(text: []const u8, octet: u8) ?usize {
    if (text.len >= vector_len) return std.mem.indexOfScalar(u8, text, octet);
    if (text.len < word_len) return index_by_octet(text, octet);
    const pattern = low_bits * octet;
    var place: usize = 0;
    for (0..text.len / word_len) |_| {
        const found = zeros_of(std.mem.readInt(u64, text[place..][0..word_len], .little) ^ pattern);
        if (found != 0) return place + @ctz(found) / word_len;
        place += word_len;
    }
    // The last word ends at the end of `text`. Its first octets were compared and are not
    // `octet`, so no false mark stands in them (see `zeros_of`).
    const start = text.len - word_len;
    const found = zeros_of(std.mem.readInt(u64, text[start..][0..word_len], .little) ^ pattern);
    if (found != 0) return start + @ctz(found) / word_len;
    return null;
}

/// A mark at the top bit of each zero octet of `word`. A borrow from a zero octet may also
/// mark an octet above it, so only the lowest mark is sure: it is the first zero octet.
fn zeros_of(word: u64) u64 {
    return (word -% low_bits) & ~word & top_bits;
}

/// The parts of `text` between its `separator` octets, as `std.mem.splitScalar` gives them,
/// each found with `index_of`.
pub fn split(text: []const u8, separator: u8) Split {
    return .{ .rest = text, .separator = separator };
}

pub const Split = struct {
    /// What follows the last separator found, or null once the last part was given.
    rest: ?[]const u8,
    separator: u8,

    /// The next part, or null after the last.
    pub fn next(parts: *Split) ?[]const u8 {
        const rest = parts.rest orelse return null;
        const place = index_of(rest, parts.separator) orelse {
            parts.rest = null;
            return rest;
        };
        parts.rest = rest[place + 1 ..];
        return rest[0..place];
    }
};

fn index_by_octet(text: []const u8, octet: u8) ?usize {
    for (text, 0..) |each, place| {
        if (each == octet) return place;
    }
    return null;
}

const testing = std.testing;

test "the first place of an octet is the one an octet-by-octet search finds" {
    const longest = vector_len + word_len + 1;
    var text: [longest]u8 = undefined;
    // Each length, the octet at each place or at none, among octets one away from it.
    const sought = 0x80;
    for (0..longest + 1) |len| {
        for (0..len + 1) |place| {
            for ([_]u8{ sought - 1, sought + 1, 0, std.math.maxInt(u8) }) |other| {
                @memset(text[0..len], other);
                if (place < len) text[place] = sought;
                try testing.expectEqual(index_by_octet(text[0..len], sought), index_of(text[0..len], sought));
                // A second one after the first changes nothing.
                if (place + 1 < len) text[len - 1] = sought;
                try testing.expectEqual(index_by_octet(text[0..len], sought), index_of(text[0..len], sought));
            }
        }
    }
    try testing.expectEqual(@as(?usize, 5), index_of("https://example.com/ada", ':'));
    try testing.expectEqual(@as(?usize, null), index_of("https://example.com/ada", '#'));
}

test "a split gives the parts that std.mem.splitScalar gives" {
    const texts = [_][]const u8{ "", ".", "a", "a.b", ".a.", "api.example.com", "192.0.2.10", "a..b.", "a.very-long-label-of-the-name.example.com" };
    for (texts) |text| {
        var expected = std.mem.splitScalar(u8, text, '.');
        var parts = split(text, '.');
        for (0..text.len + 2) |_| {
            const want = expected.next();
            const got = parts.next();
            try testing.expectEqual(want == null, got == null);
            if (want) |part| try testing.expectEqualStrings(part, got.?);
        }
    }
}
