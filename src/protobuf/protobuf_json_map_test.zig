//! The JSON of a map that holds a key twice: JSON encode writes the key once, with its last
//! entry's value ("Maps", language guide), from a program's entries and from a decoded message's.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");
const constants = @import("constants.zig");
const binary_test = @import("protobuf_test.zig");
const All = binary_test.All;
const Entry = binary_test.Entry;

const entries_checked_max = constants.limits.json_map_entries_checked_max;
const text_len = 1024;
/// The octets each entry of a map one entry past the check's bound takes at most: `"k":`, a
/// value of at most three digits and a comma in JSON, and fewer in binary.
const large_entry_len = 8;
/// Room for that map's JSON or binary.
const large_text_len = (entries_checked_max + 1) * large_entry_len + text_len;

/// A map of integer keys, whose check compares the keys themselves.
const Tally = struct {
    counts: proto.Repeated(TallyEntry, .message) = .{},
    pub const FieldNumber = enum(u29) { counts = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Tally", .fields = &.{
        proto.field_of(FieldNumber.counts, .message, .{}),
    } };
};

const TallyEntry = struct {
    key: i32 = 0,
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Tally.CountsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .int32, .{}),
        proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

test "a program's map that holds a key twice writes it once, with the last value" {
    const all: All = .{ .counts = .of(&.{
        .{ .key = "k", .value = 1 },
        .{ .key = "j", .value = 2 },
        .{ .key = "k", .value = 9 },
    }) };
    var text: [text_len]u8 = undefined;
    try testing.expectEqualStrings("{\"counts\":{\"j\":2,\"k\":9}}", try proto.encode_json(All, &all, &text));
}

test "a decoded map that holds a key twice writes it once, with the last value" {
    const all: All = .{ .counts = .of(&.{
        .{ .key = "k", .value = 1 },
        .{ .key = "j", .value = 2 },
        .{ .key = "k", .value = 9 },
    }) };
    var binary: [text_len]u8 = undefined;
    const decoded = try proto.decode(All, try proto.encode(All, &all, &binary));
    var text: [text_len]u8 = undefined;
    try testing.expectEqualStrings("{\"counts\":{\"j\":2,\"k\":9}}", try proto.encode_json(All, &decoded, &text));
}

test "a map of integer keys that holds a key twice writes it once, with the last value" {
    // The keys differ by 2, so a comparison off by one matches no other key by chance.
    const tally: Tally = .{ .counts = .of(&.{
        .{ .key = 3, .value = 1 },
        .{ .key = 1, .value = 2 },
        .{ .key = 3, .value = 7 },
    }) };
    var text: [text_len]u8 = undefined;
    try testing.expectEqualStrings("{\"counts\":{\"1\":2,\"3\":7}}", try proto.encode_json(Tally, &tally, &text));
    var binary: [text_len]u8 = undefined;
    const decoded = try proto.decode(Tally, try proto.encode(Tally, &tally, &binary));
    try testing.expectEqualStrings("{\"counts\":{\"1\":2,\"3\":7}}", try proto.encode_json(Tally, &decoded, &text));
}

test "two keys of one fingerprint that differ are both written" {
    // The same length, and the same 8 octets at each end: only the middle tells them apart.
    const all: All = .{ .counts = .of(&.{
        .{ .key = "aaaaaaaa-x-bbbbbbbb", .value = 1 },
        .{ .key = "aaaaaaaa-y-bbbbbbbb", .value = 2 },
    }) };
    var text: [text_len]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"counts\":{\"aaaaaaaa-x-bbbbbbbb\":1,\"aaaaaaaa-y-bbbbbbbb\":2}}",
        try proto.encode_json(All, &all, &text),
    );
}

test "a map at the check's bound writes a key once, and a larger one as received" {
    var entries: [entries_checked_max + 1]Entry = undefined;
    for (&entries, 0..) |*entry, index| entry.* = .{ .key = "k", .value = @intCast(index) };
    var text: [large_text_len]u8 = undefined;
    const at_bound: All = .{ .counts = .of(entries[0..entries_checked_max]) };
    const once = try proto.encode_json(All, &at_bound, &text);
    try testing.expectEqual(1, std.mem.count(u8, once, "\"k\":"));
    try testing.expect(std.mem.endsWith(u8, once, std.fmt.comptimePrint("\"k\":{d}}}}}", .{entries_checked_max - 1})));
    const past_bound: All = .{ .counts = .of(&entries) };
    const each = try proto.encode_json(All, &past_bound, &text);
    try testing.expectEqual(entries.len, std.mem.count(u8, each, "\"k\":"));
}

test "a decoded map at the check's bound writes a key once, and a larger one as received" {
    var entries: [entries_checked_max + 1]Entry = undefined;
    for (&entries, 0..) |*entry, index| entry.* = .{ .key = "k", .value = @intCast(index) };
    var binary: [large_text_len]u8 = undefined;
    var text: [large_text_len]u8 = undefined;
    const at_bound: All = .{ .counts = .of(entries[0..entries_checked_max]) };
    const decoded_at_bound = try proto.decode(All, try proto.encode(All, &at_bound, &binary));
    try testing.expectEqual(1, std.mem.count(u8, try proto.encode_json(All, &decoded_at_bound, &text), "\"k\":"));
    const past_bound: All = .{ .counts = .of(&entries) };
    const decoded_past_bound = try proto.decode(All, try proto.encode(All, &past_bound, &binary));
    const each = try proto.encode_json(All, &decoded_past_bound, &text);
    try testing.expectEqual(entries.len, std.mem.count(u8, each, "\"k\":"));
}
