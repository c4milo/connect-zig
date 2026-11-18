//! The entries of a map that JSON encode leaves out: each whose key a later entry of the map
//! holds again. A map read from binary may hold a key twice, and its last entry wins ("Maps",
//! language guide: "the last key seen is used"). A JSON object holds each name once (RFC 8259
//! §4: "The names within an object SHOULD be unique"), and Go's protojson refuses a map key twice.
//!
//! One pass counts the entries and sets a bit of a filter for each key's fingerprint. A map
//! whose keys set distinct bits holds no key twice, and costs that pass alone. A map with two
//! keys on one bit takes a second pass, which compares each pair of keys. It runs on a map of at
//! most `json_map_entries_checked_max` entries; a larger map is written as it was received. The
//! check keeps no key, so it holds no array of them.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const wire = @import("wire.zig");

const entries_checked_max = constants.limits.json_map_entries_checked_max;

/// One bit for each entry the check reads: set when JSON encode leaves the entry out.
pub const Skipped = std.StaticBitSet(entries_checked_max);

/// The bits of the filter: 1,024, which 16 distinct keys share by chance about once in 9 maps.
/// A power of two, so a fingerprint's high bits pick one. 2,048 bits cost Medium's JSON encode
/// more to clear than the rarer second pass saved (`tools/perf_check.sh`'s counts, 2026-11-17).
const filter_bits = 1024;
const Filter = std.StaticBitSet(filter_bits);
/// The shift that leaves a fingerprint's high bits that pick one bit of the filter.
const filter_shift: std.math.Log2Int(u64) = @bitSizeOf(u64) - @ctz(@as(u64, filter_bits));
comptime {
    assert(std.math.isPowerOfTwo(filter_bits));
}
/// The octets of a string key that its fingerprint reads at each end.
const fingerprint_end_len = @sizeOf(u64);
/// The rotation that keeps a key's last octets apart from its first ones in its fingerprint.
const fingerprint_rotation = 29;
/// Fibonacci hashing's multiplier, 2^64 / φ: it spreads close keys over the high bits.
const fingerprint_multiplier: u64 = 0x9e3779b97f4a7c15;

/// The entries of the map `item` that JSON encode leaves out: each whose key a later entry holds,
/// or null when it leaves none out. A map of more than `json_map_entries_checked_max` entries
/// leaves none out.
pub noinline fn skipped(comptime F: type, item: *const F) wire.Error!?Skipped {
    const scan = try scan_keys(F, item);
    if (scan.count > entries_checked_max or !scan.shared_bit) return null;
    var skip: Skipped = .initEmpty();
    var entries = item.iterator();
    for (0..scan.count) |index| {
        const entry = (try entries.next()).?;
        // A copy of the iterator reads the entries after this one.
        var later = entries;
        if (try holds_key(F, &later, entry.key)) skip.set(index);
    }
    return skip;
}

const Scan = struct {
    /// The entries read: `json_map_entries_checked_max + 1` for any larger map.
    count: usize,
    /// Whether two keys set one bit of the filter.
    shared_bit: bool,
};

fn scan_keys(comptime F: type, item: *const F) wire.Error!Scan {
    const Key = @FieldType(F.Element, "key");
    var filter: Filter = .initEmpty();
    var shared_bit = false;
    // A program's entries are a slice: one loop over it, without an iterator call per entry.
    if (item.items.len != 0) {
        if (item.items.len > entries_checked_max) return .{ .count = item.items.len, .shared_bit = false };
        for (item.items) |*entry| shared_bit = mark_filter(Key, &filter, entry.key) or shared_bit;
        return .{ .count = item.items.len, .shared_bit = shared_bit };
    }
    var entries = item.iterator();
    for (0..entries_checked_max + 1) |index| {
        const entry = try entries.next() orelse return .{ .count = index, .shared_bit = shared_bit };
        shared_bit = mark_filter(Key, &filter, entry.key) or shared_bit;
    }
    return .{ .count = entries_checked_max + 1, .shared_bit = false };
}

/// Sets the filter's bit for `key`, and gives whether it was set before.
inline fn mark_filter(comptime Key: type, filter: *Filter, key: Key) bool {
    const bit: usize = @intCast(fingerprint(Key, key) >> filter_shift);
    const was_set = filter.isSet(bit);
    filter.set(bit);
    return was_set;
}

/// Whether an entry that `later` yields holds `key`.
fn holds_key(comptime F: type, later: *F.Iterator, key: @FieldType(F.Element, "key")) wire.Error!bool {
    const Key = @TypeOf(key);
    for (0..entries_checked_max) |_| {
        const other = try later.next() orelse return false;
        const equal = if (comptime Key == []const u8) std.mem.eql(u8, other.key, key) else other.key == key;
        if (equal) return true;
    }
    return false;
}

/// A key's fingerprint: two equal keys have equal fingerprints.
inline fn fingerprint(comptime Key: type, key: Key) u64 {
    const raw: u64 = switch (@typeInfo(Key)) {
        .bool => @intFromBool(key),
        .int => |info| if (info.signedness == .signed) @bitCast(@as(i64, key)) else @as(u64, key),
        else => string_fingerprint(key),
    };
    return raw *% fingerprint_multiplier;
}

/// A string's length and its first and last octets, up to `fingerprint_end_len` at each end. A
/// key of `fingerprint_end_len` octets or more takes two loads; a shorter one, its octets.
inline fn string_fingerprint(key: []const u8) u64 {
    if (key.len >= fingerprint_end_len) {
        const first = std.mem.readInt(u64, key[0..fingerprint_end_len], .little);
        const last = std.mem.readInt(u64, key[key.len - fingerprint_end_len ..][0..fingerprint_end_len], .little);
        return first ^ std.math.rotl(u64, last, fingerprint_rotation) ^ key.len;
    }
    var octets: u64 = 0;
    for (key) |octet| octets = (octets << @bitSizeOf(u8)) | octet;
    return octets ^ key.len;
}
