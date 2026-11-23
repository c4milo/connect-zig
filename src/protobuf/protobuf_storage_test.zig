//! The proof harness of a decode with storage (decision 37; pepegrillo's performance method,
//! step 5): `decode_into` gives the message that `decode` gives, or the same refusal, on every
//! input. The inputs:
//!
//! - The encoding of a message with each kind of repeated field: packed varints, packed fixed
//!   numbers, strings, a run of flat messages, a counted run of messages that hold runs of their
//!   own, a map, and a chain of `Lazy` children.
//! - The same with a field's records in two runs, which keeps the field's view.
//! - Each one cut short at every length, and with each bit of each octet flipped.
//! - Storage of each size from none to more than the message needs, aligned and not.
//!
//! Each node that decodes is also read through its iterators, from the views `decode` leaves and
//! from the storage `decode_into` fills, and both readings must give the same elements in the
//! same order. An iterator gives a message in place, and any other element by value.
//!
//! A fuzz property runs the same check on any input.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");
const Repeated = proto.Repeated;
const Lazy = proto.Lazy;

/// A flat message: its run takes one pass.
const Leaf = struct {
    name: []const u8 = "",
    id: u32 = 0,
    pub const FieldNumber = enum(u29) { name = 1, id = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Leaf", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),
        proto.field_of(FieldNumber.id, .uint32, .{}),
    } };
};

const CountsEntry = struct {
    key: []const u8 = "",
    value: i64 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Node.CountsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}),
        proto.field_of(FieldNumber.value, .int64, .{}),
    } };
};

/// A message with each kind of repeated field. Its own run is counted first, since a node holds
/// runs of its own.
const Node = struct {
    label: []const u8 = "",
    numbers: Repeated(i64, .int64) = .{},
    fixed: Repeated(u32, .fixed32) = .{},
    names: Repeated([]const u8, .string) = .{},
    leaves: Repeated(Leaf, .message) = .{},
    children: Repeated(Node, .message) = .{},
    counts: Repeated(CountsEntry, .message) = .{},
    next: Lazy(Node) = .{},
    pub const FieldNumber = enum(u29) { label = 1, numbers = 2, fixed = 3, names = 4, leaves = 5, children = 6, counts = 7, next = 8 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Node", .fields = &.{
        proto.field_of(FieldNumber.label, .string, .{}),
        proto.field_of(FieldNumber.numbers, .int64, .{}),
        proto.field_of(FieldNumber.fixed, .fixed32, .{}),
        proto.field_of(FieldNumber.names, .string, .{}),
        proto.field_of(FieldNumber.leaves, .message, .{}),
        proto.field_of(FieldNumber.children, .message, .{}),
        proto.field_of(FieldNumber.counts, .message, .{}),
        proto.field_of(FieldNumber.next, .message, .{}),
    } };
};

/// A group that holds a run of its own, so a run of such groups is counted before it is read.
const Bundle = struct {
    numbers: Repeated(i64, .int64) = .{},
    pub const FieldNumber = enum(u29) { numbers = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Crate.Bundle", .fields = &.{
        proto.field_of(FieldNumber.numbers, .int64, .{}),
    } };
};

/// A run of three 4-octet numbers, then a run of 8-octet ones: the second run starts past 12
/// octets at the next multiple of 8, so a store of 13 to 15 octets ends before its start.
const Pair = struct {
    fixed: Repeated(u32, .fixed32) = .{},
    numbers: Repeated(i64, .int64) = .{},
    pub const FieldNumber = enum(u29) { fixed = 1, numbers = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Pair", .fields = &.{
        proto.field_of(FieldNumber.fixed, .fixed32, .{}),
        proto.field_of(FieldNumber.numbers, .int64, .{}),
    } };
};

const Crate = struct {
    bundles: Repeated(Bundle, .group) = .{},
    pub const FieldNumber = enum(u29) { bundles = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Crate", .fields = &.{
        proto.field_of(FieldNumber.bundles, .group, .{}),
    } };
};

/// The most octets an input of the harness takes, and the most its message's encoding takes again
/// once decoded: an input changed by one bit may decode to a longer message.
const encoded_len_max = 1024;
const out_len_max = 2048;
/// The most octets a message's storage takes, and the alignment the harness's storage starts at.
const storage_len_max = 8192;
const storage_align = 16;
/// The storage sizes each input decodes with, beside none and room for every run: too little
/// for one run, and room for some runs. Each also starts one octet past an aligned address.
const storage_too_small = 8;
const storage_some_runs = 96;
const storage_lens = [_]usize{ 0, storage_too_small, storage_some_runs, storage_len_max - 1 };
const bits_per_octet = 8;

/// Numbers whose varints take two octets and more, and fixed numbers of each width of value.
const two_octets = 300;
const wide = 0x100_0000_0000;
const fixed_small = 7;
const fixed_wide = 0xdead_beef;

const numbers = [_]i64{ 0, 1, -1, two_octets, std.math.maxInt(i64), std.math.minInt(i64) };
const few_numbers = [_]i64{ 1, -1 };
/// Two one-octet numbers: a change of one bit can leave the record's last octet alone with its
/// continuation bit.
const short_numbers = [_]i64{ 1, 0 };
const fixed = [_]u32{ fixed_small, fixed_wide };
const names = [_][]const u8{ "", "a", "données", "日本語" };
const few_names = [_][]const u8{ "a", "données" };
const leaves = [_]Leaf{ .{ .name = "one", .id = 1 }, .{}, .{ .name = "three", .id = two_octets } };
const counts = [_]CountsEntry{ .{ .key = "x", .value = -1 }, .{ .key = "y", .value = wide } };
const grandchildren = [_]Node{ .{ .label = "g", .numbers = .of(&few_numbers) }, .{ .names = .of(&few_names) } };
const children = [_]Node{ .{ .label = "c", .children = .of(&grandchildren), .leaves = .of(leaves[0..1]) }, .{}, .{ .counts = .of(&counts) } };
const tail: Node = .{ .label = "tail", .numbers = .of(&numbers) };
const middle: Node = .{ .label = "middle", .next = .of(&tail), .leaves = .of(&leaves) };

const bundles = [_]Bundle{ .{ .numbers = .of(&few_numbers) }, .{}, .{ .numbers = .of(&numbers) } };

/// A node with every kind of repeated field, and a chain of two `Lazy` children.
const full: Node = .{
    .label = "root",
    .numbers = .of(&numbers),
    .fixed = .of(&fixed),
    .names = .of(&names),
    .leaves = .of(&leaves),
    .children = .of(&children),
    .counts = .of(&counts),
    .next = .of(&middle),
};

/// What a decode gave: the encoding of its message, or its refusal.
const Outcome = union(enum) {
    message: []const u8,
    refusal: anyerror,
};

fn outcome(comptime T: type, bytes: []const u8, storage: ?[]u8, out: []u8) Outcome {
    const decoded = if (storage) |room| proto.decode_into(T, bytes, room) else proto.decode(T, bytes);
    const message = decoded catch |failure| return .{ .refusal = failure };
    return .{ .message = proto.encode(T, &message, out) catch |failure| return .{ .refusal = failure } };
}

/// An element changes a fold by its place and by its value, so two folds agree only when both
/// read the same elements in the same order.
const fold_factor = 31;
/// The levels of nodes a fold follows: more than any message of the harness nests.
const fold_depth_max = 16;

/// One number from every element of every repeated field of a node, each read through its
/// field's iterator.
fn fold_node(node: *const Node, depth_left: usize) anyerror!u64 {
    if (depth_left == 0) return error.FoldTooDeep;
    var sum: u64 = node.label.len;
    inline for (.{ "numbers", "fixed", "names", "leaves", "children", "counts" }) |name| {
        const field = &@field(node, name);
        sum = sum *% fold_factor +% try fold_field(@TypeOf(field.*), field, depth_left);
    }
    const next = try node.next.get() orelse return sum;
    return sum *% fold_factor +% try fold_node(&next, depth_left - 1);
}

fn fold_field(comptime F: type, field: *const F, depth_left: usize) anyerror!u64 {
    var elements = field.iterator();
    var sum: u64 = 0;
    // Each element takes at least one octet of an input.
    for (0..encoded_len_max + 1) |_| {
        const element = try elements.next() orelse return sum;
        // A message comes from the iterator in place, as a pointer.
        const at = if (comptime F.kind.holds_message()) element else &element;
        sum = sum *% fold_factor +% try fold_element(F.Element, at, depth_left);
    }
    return error.FoldTooLong;
}

fn fold_element(comptime E: type, element: *const E, depth_left: usize) anyerror!u64 {
    return switch (E) {
        i64 => @bitCast(element.*),
        u32 => element.*,
        []const u8 => fold_text(element.*),
        Leaf => fold_text(element.name) *% fold_factor +% element.id,
        CountsEntry => fold_text(element.key) *% fold_factor +% @as(u64, @bitCast(element.value)),
        Node => fold_node(element, depth_left - 1),
        else => @compileError("no fold for " ++ @typeName(E)),
    };
}

fn fold_text(text: []const u8) u64 {
    return text.len *% fold_factor +% (if (text.len == 0) 0 else text[0]);
}

/// What the iterators of a decoded node read, or null when `T` is no node or the decode refuses
/// `bytes`: the outcome holds the refusal.
fn reading(comptime T: type, bytes: []const u8, storage: ?[]u8) ?anyerror!u64 {
    if (T != Node) return null;
    const decoded = if (storage) |room| proto.decode_into(Node, bytes, room) else proto.decode(Node, bytes);
    const node = decoded catch return null;
    return fold_node(&node, fold_depth_max);
}

/// Decodes `bytes` as a `T` with `decode`, and with `decode_into` in each size of storage, and
/// requires one outcome.
fn check(comptime T: type, bytes: []const u8) !void {
    var want_out: [out_len_max]u8 = @splat(0);
    const want = outcome(T, bytes, null, &want_out);
    const want_reading = reading(T, bytes, null);
    var storage: [storage_len_max + 1]u8 align(storage_align) = @splat(0);
    for (storage_lens) |len| {
        for ([_]usize{ 0, 1 }) |offset| {
            var got_out: [out_len_max]u8 = @splat(0);
            const got = outcome(T, bytes, storage[offset..][0..len], &got_out);
            try testing.expectEqual(want_reading, reading(T, bytes, storage[offset..][0..len]));
            switch (want) {
                .refusal => |refusal| try testing.expectEqual(Outcome{ .refusal = refusal }, got),
                .message => |message| try testing.expectEqualSlices(u8, message, got.message),
            }
        }
    }
}

/// Each input cut short at every length, and with each bit of each octet flipped.
fn check_each_change(comptime T: type, bytes: []const u8) !void {
    try check(T, bytes);
    var changed: [encoded_len_max]u8 = @splat(0);
    for (0..bytes.len) |len| try check(T, bytes[0..len]);
    for (0..bytes.len) |index| {
        for (0..bits_per_octet) |bit| {
            @memcpy(changed[0..bytes.len], bytes);
            changed[index] ^= @as(u8, 1) << @intCast(bit);
            try check(T, changed[0..bytes.len]);
        }
    }
}

fn encoded(message: *const Node, buffer: []u8) ![]const u8 {
    return proto.encode(Node, message, buffer);
}

test "decode_into gives the message or the refusal decode gives" {
    var buffer: [encoded_len_max]u8 = @splat(0);
    try check_each_change(Node, try encoded(&full, &buffer));
    try check_each_change(Node, try encoded(&middle, &buffer));
    try check_each_change(Node, try encoded(&.{ .children = .of(&children) }, &buffer));
    try check_each_change(Node, try encoded(&.{ .numbers = .of(&short_numbers) }, &buffer));
}

test "a field in two runs keeps its view, and gives the same message" {
    var first: [encoded_len_max]u8 = @splat(0);
    var second: [encoded_len_max]u8 = @splat(0);
    var joined: [encoded_len_max]u8 = @splat(0);
    // Two encodings one after the other merge ("Last One Wins"): each repeated field's records
    // come in two runs, with the other fields' records between them.
    const one = try encoded(&.{ .numbers = .of(&numbers), .names = .of(&names), .leaves = .of(&leaves) }, &first);
    const two = try encoded(&.{ .numbers = .of(numbers[0..1]), .names = .of(names[0..1]), .leaves = .of(leaves[0..1]) }, &second);
    @memcpy(joined[0..one.len], one);
    @memcpy(joined[one.len..][0..two.len], two);
    try check_each_change(Node, joined[0 .. one.len + two.len]);
}

test "a run of groups is counted, and read into the storage" {
    var buffer: [encoded_len_max]u8 = @splat(0);
    const bytes = try proto.encode(Crate, &.{ .bundles = .of(&bundles) }, &buffer);
    var storage: [storage_len_max]u8 align(storage_align) = @splat(0);
    // "Groups": a group's record has no length, so its count passes over it to its end tag.
    const crate = try proto.decode_into(Crate, bytes, &storage);
    try testing.expectEqual(bundles.len, crate.bundles.items.len);
    try testing.expectEqual(numbers.len, crate.bundles.items[bundles.len - 1].numbers.items.len);
    try check_each_change(Crate, bytes);
}

test "an iterator gives a message of the storage where it lies, and a view's message from its slot" {
    var buffer: [encoded_len_max]u8 = @splat(0);
    const bytes = try encoded(&full, &buffer);
    var storage: [storage_len_max]u8 align(storage_align) = @splat(0);
    const stored = try proto.decode_into(Node, bytes, &storage);
    var in_storage = stored.leaves.iterator();
    for (stored.leaves.items) |*leaf| try testing.expectEqual(leaf, (try in_storage.next()).?);
    // The end holds: each later call gives null again.
    try testing.expectEqual(@as(?*const Leaf, null), try in_storage.next());
    try testing.expectEqual(@as(?*const Leaf, null), try in_storage.next());
    // A view holds no message to point at, so each one is decoded into the iterator's slot.
    const lazy = try proto.decode(Node, bytes);
    var in_view = lazy.leaves.iterator();
    for (leaves) |want| {
        const got = (try in_view.next()).?;
        try testing.expectEqual(&in_view.current, got);
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqual(want.id, got.id);
    }
    try testing.expectEqual(@as(?*const Leaf, null), try in_view.next());
    // The messages a program set are read in place too, and an empty field has none.
    var in_program = full.leaves.iterator();
    try testing.expectEqual(&leaves[0], (try in_program.next()).?);
    try testing.expectEqual(try fold_node(&full, fold_depth_max), try fold_node(&stored, fold_depth_max));
    var in_empty = (Node{}).children.iterator();
    try testing.expectEqual(@as(?*const Node, null), try in_empty.next());
    // A number comes back by value, and a field of numbers holds no slot.
    try testing.expectEqual(i64, @TypeOf(stored.numbers).Iterator.Item);
    try testing.expectEqual(void, @FieldType(@TypeOf(stored.numbers).Iterator, "current"));
}

test "with room, each repeated field and each Lazy child is read into the storage" {
    var buffer: [encoded_len_max]u8 = @splat(0);
    const bytes = try encoded(&full, &buffer);
    var storage: [storage_len_max]u8 align(storage_align) = @splat(0);
    const node = try proto.decode_into(Node, bytes, &storage);
    try testing.expectEqual(numbers.len, node.numbers.items.len);
    try testing.expectEqual(fixed.len, node.fixed.items.len);
    try testing.expectEqual(names.len, node.names.items.len);
    try testing.expectEqual(leaves.len, node.leaves.items.len);
    try testing.expectEqual(children.len, node.children.items.len);
    try testing.expectEqual(counts.len, node.counts.items.len);
    try testing.expectEqual(grandchildren.len, node.children.items[0].children.items.len);
    try testing.expect(node.next.value != null);
    try testing.expect(node.next.value.?.next.value != null);
    try testing.expectEqualStrings("tail", node.next.value.?.next.value.?.label);
    // `decode` leaves each field in the input (decision 6).
    const lazy = try proto.decode(Node, bytes);
    try testing.expectEqual(@as(usize, 0), lazy.numbers.items.len);
    try testing.expect(lazy.next.value == null);
}

test "decode_into_use is short exactly when the storage holds less than the message takes" {
    var buffer: [encoded_len_max]u8 = @splat(0);
    try expect_short_below_need(Node, try encoded(&full, &buffer));
    var crate_buffer: [encoded_len_max]u8 = @splat(0);
    try expect_short_below_need(Crate, try proto.encode(Crate, &.{ .bundles = .of(&bundles) }, &crate_buffer));
    var pair_buffer: [encoded_len_max]u8 = @splat(0);
    const three = [_]u32{ fixed_small, fixed_wide, fixed_small };
    try expect_short_below_need(Pair, try proto.encode(Pair, &.{ .fixed = .of(&three), .numbers = .of(&few_numbers) }, &pair_buffer));
    // A message with no repeated field and no `Lazy` field takes no storage, so none is short.
    var leaf_buffer: [encoded_len_max]u8 = @splat(0);
    var use: proto.StorageUse = .{};
    _ = try proto.decode_into_use(Leaf, try proto.encode(Leaf, &leaves[0], &leaf_buffer), &.{}, &use);
    try testing.expectEqual(proto.StorageUse{}, use);
}

/// Decodes `bytes` into storage of each length from none to past what the message takes. Below
/// it, a field finds no room at some run, flat or counted, or at a `Lazy` child; from it on, the
/// decode fills the same octets and none is short.
fn expect_short_below_need(comptime T: type, bytes: []const u8) !void {
    var storage: [storage_len_max]u8 align(storage_align) = @splat(0);
    var roomy: proto.StorageUse = .{};
    _ = try proto.decode_into_use(T, bytes, &storage, &roomy);
    try testing.expect(!roomy.short);
    try testing.expect(roomy.octets > 0 and roomy.octets < storage.len);
    // One length past what the message takes, and the one after it.
    const past = 2;
    for (0..roomy.octets + past) |len| {
        var use: proto.StorageUse = .{};
        _ = try proto.decode_into_use(T, bytes, storage[0..len], &use);
        try testing.expectEqual(len < roomy.octets, use.short);
        if (!use.short) try testing.expectEqual(roomy.octets, use.octets);
    }
}

/// A closed enum: a field of it passes over a number it does not name, so `decode_into` keeps
/// the field's view (editions, "enum_type").
const Size = enum(i32) {
    unspecified = 0,
    small = 1,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "test.Size", .closed = true, .values = &.{
        .{ .name = "SIZE_UNSPECIFIED", .number = @intFromEnum(@This().unspecified) },
        .{ .name = "SMALL", .number = @intFromEnum(@This().small) },
    } };
};

const ByNameEntry = struct {
    key: []const u8 = "",
    value: Size = .unspecified,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Shirt.ByNameEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}),
        proto.field_of(FieldNumber.value, .@"enum", .{}),
    } };
};

/// A message whose repeated fields hold a closed enum: a list of it, and a map to it.
const Shirt = struct {
    sizes: Repeated(Size, .@"enum") = .{},
    by_name: Repeated(ByNameEntry, .message) = .{},
    pub const FieldNumber = enum(u29) { sizes = 1, by_name = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Shirt", .fields = &.{
        proto.field_of(FieldNumber.sizes, .@"enum", .{}),
        proto.field_of(FieldNumber.by_name, .message, .{}),
    } };
};

test "a closed enum's field keeps its view, and its unknown numbers go back out" {
    // Field 1 packed { 1, 5, 0 }, then field 2's entries { "a": 1 } and { "b": 5 }: 5 is a number
    // the closed enum does not name.
    const bytes = "\x0a\x03\x01\x05\x00\x12\x05\x0a\x01a\x10\x01\x12\x05\x0a\x01b\x10\x05";
    var storage: [storage_len_max]u8 align(storage_align) = @splat(0);
    const stored = try proto.decode_into(Shirt, bytes, &storage);
    try testing.expectEqual(@as(usize, 0), stored.sizes.items.len);
    try testing.expectEqual(@as(usize, 0), stored.by_name.items.len);
    const lazy = try proto.decode(Shirt, bytes);
    var want: [encoded_len_max]u8 = @splat(0);
    var got: [encoded_len_max]u8 = @splat(0);
    try testing.expectEqualSlices(u8, try proto.encode(Shirt, &lazy, &want), try proto.encode(Shirt, &stored, &got));
}

fn fuzz_one(_: void, smith: *testing.Smith) anyerror!void {
    var input: [encoded_len_max]u8 = @splat(0);
    const len = smith.slice(&input);
    try check(Node, input[0..len]);
}

test "fuzz: decode_into gives what decode gives, on any input" {
    try testing.fuzz({}, fuzz_one, .{ .corpus = &.{
        "\x12\x03\x01\xac\x02",
        "\x2a\x07\x0a\x03one\x10\x01\x2a\x00",
        "\x32\x04\x32\x02\x0a\x00",
        "\x42\x06\x42\x04\x0a\x02ab",
    } });
}
