//! Whether two messages are the same, as interop/README.md rules: connect-zig's runtime writes the
//! same octets for both. connect-zig writes a map's entries in the order it read them, and has no
//! deterministic option, while Go, Rust's Buffa and other runtimes write a map in any order. So
//! where the octets differ, the client compares the two messages' proto3 JSON as JSON values,
//! whose objects ignore key order, as the connect-rust client does.
//!
//! Numbers compare by their text, so -0 and 0 differ, except in a run whose messages travel as
//! JSON: there they compare as values, since connect-es writes -0 as 0. JSON's "NaN" holds no
//! payload, so a NaN whose bits differ compares the same in JSON.
const std = @import("std");
const proto = @import("protobuf");
const verdict = @import("verdict.zig");
const buffers = @import("buffers.zig");

/// The depth of JSON values the comparison reads, at most: the recursion case nests messages a
/// few dozen deep.
const depth_max = 256;
/// Octets of the memory the two JSON trees are parsed into.
const tree_bytes = 8 * 1024 * 1024;

var wanted_octets: [buffers.message_bytes]u8 = undefined;
var gotten_octets: [buffers.message_bytes]u8 = undefined;
var wanted_json: [buffers.message_bytes]u8 = undefined;
var gotten_json: [buffers.message_bytes]u8 = undefined;
var tree_memory: [tree_bytes]u8 align(@alignOf(u64)) = undefined;

/// How numbers compare.
pub const Numbers = enum { by_text, by_value };

/// Fails unless `got` is the same message of type `T` as `want`.
pub fn expect(comptime T: type, want: *const T, got: *const T, numbers: Numbers) verdict.Error!void {
    const wanted = proto.encode(T, want, &wanted_octets) catch |failure| return verdict.wrong("encoding the case: {s}", .{@errorName(failure)});
    const gotten = proto.encode(T, got, &gotten_octets) catch |failure| return verdict.wrong("encoding the answer: {s}", .{@errorName(failure)});
    if (std.mem.eql(u8, wanted, gotten)) return;
    const wanted_text = proto.encode_json(T, want, &wanted_json) catch |failure| return verdict.wrong("the case in JSON: {s}", .{@errorName(failure)});
    const gotten_text = proto.encode_json(T, got, &gotten_json) catch |failure| return verdict.wrong("the answer in JSON: {s}", .{@errorName(failure)});
    if (try same_json(wanted_text, gotten_text, numbers)) return;
    return verdict.wrong("the answer differs: wanted {d} octets, got {d}; wanted {s}, got {s}", .{ wanted.len, gotten.len, wanted_text, gotten_text });
}

/// Whether two JSON texts hold the same value.
fn same_json(wanted_text: []const u8, gotten_text: []const u8, numbers: Numbers) verdict.Error!bool {
    var memory: std.heap.FixedBufferAllocator = .init(&tree_memory);
    const allocator = memory.allocator();
    const options: std.json.ParseOptions = .{ .parse_numbers = false };
    const wanted = std.json.parseFromSliceLeaky(std.json.Value, allocator, wanted_text, options) catch |failure|
        return verdict.wrong("reading the case's JSON: {s}", .{@errorName(failure)});
    const gotten = std.json.parseFromSliceLeaky(std.json.Value, allocator, gotten_text, options) catch |failure|
        return verdict.wrong("reading the answer's JSON: {s}", .{@errorName(failure)});
    return same_value(&wanted, &gotten, numbers, depth_max);
}

fn same_value(wanted: *const std.json.Value, gotten: *const std.json.Value, numbers: Numbers, depth: u32) bool {
    if (depth == 0) return false;
    if (std.meta.activeTag(wanted.*) != std.meta.activeTag(gotten.*)) return false;
    return switch (wanted.*) {
        .null => true,
        .bool => |value| value == gotten.bool,
        .string => |value| std.mem.eql(u8, value, gotten.string),
        .number_string => |value| same_number(value, gotten.number_string, numbers),
        .array => |items| same_array(items.items, gotten.array.items, numbers, depth - 1),
        .object => |object| same_object(&object, &gotten.object, numbers, depth - 1),
        // `parse_numbers = false` reads every number as its text.
        .integer, .float => unreachable,
    };
}

fn same_number(wanted: []const u8, gotten: []const u8, numbers: Numbers) bool {
    if (std.mem.eql(u8, wanted, gotten)) return true;
    if (numbers == .by_text) return false;
    const wanted_value = std.fmt.parseFloat(f64, wanted) catch return false;
    const gotten_value = std.fmt.parseFloat(f64, gotten) catch return false;
    return wanted_value == gotten_value;
}

fn same_array(wanted: []const std.json.Value, gotten: []const std.json.Value, numbers: Numbers, depth: u32) bool {
    if (wanted.len != gotten.len) return false;
    for (wanted, gotten) |*want, *got| {
        if (!same_value(want, got, numbers, depth)) return false;
    }
    return true;
}

fn same_object(wanted: *const std.json.ObjectMap, gotten: *const std.json.ObjectMap, numbers: Numbers, depth: u32) bool {
    if (wanted.count() != gotten.count()) return false;
    var entries = wanted.iterator();
    for (0..wanted.count()) |_| {
        const entry = entries.next() orelse return false;
        const got = gotten.getPtr(entry.key_ptr.*) orelse return false;
        if (!same_value(entry.value_ptr, got, numbers, depth)) return false;
    }
    return true;
}

const testing = std.testing;

test "two JSON texts are the same whatever their key order, and numbers by text unless asked" {
    try testing.expect(try same_json("{\"a\":1,\"m\":{\"x\":[1,2],\"y\":\"z\"}}", "{\"m\":{\"y\":\"z\",\"x\":[1,2]},\"a\":1}", .by_text));
    try testing.expect(!try same_json("{\"a\":[1,2]}", "{\"a\":[2,1]}", .by_text));
    try testing.expect(!try same_json("{\"d\":-0}", "{\"d\":0}", .by_text));
    try testing.expect(try same_json("{\"d\":-0}", "{\"d\":0}", .by_value));
    try testing.expect(!try same_json("{\"a\":1}", "{\"a\":1,\"b\":2}", .by_text));
}
