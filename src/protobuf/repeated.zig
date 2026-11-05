//! `Repeated(T, kind)` and `Lazy(T)`: the two field types that hold no decoded copy.
//!
//! A `Repeated` field is either a slice of `items`, which a program sets to encode, or a `View`
//! of the enclosing message's bytes, which `decode` sets. An `Iterator` yields each element from
//! either, reading packed and unpacked elements alike ("Packed Repeated Fields": a parser must
//! accept both). A map field is a `Repeated` of its entry messages ("Maps", language guide).
//!
//! A `Lazy` field holds a singular message that may contain its own type. It holds either the
//! encoded bytes, which `decode` sets, or a pointer to a value, which a program sets to encode.
const std = @import("std");
const assert = std.debug.assert;
const wire = @import("wire.zig");
const descriptor = @import("descriptor.zig");
const scalar = @import("scalar.zig");
const decode = @import("decode.zig");
const constants = @import("constants.zig");
const Kind = descriptor.Kind;

/// A message element is checked where it is decoded, not here: a message may repeat its own
/// type, and a check here would ask for the type while it is still being defined.
pub fn Repeated(comptime T: type, comptime element_kind: Kind) type {
    return struct {
        const Self = @This();
        pub const Element = T;
        pub const kind = element_kind;
        pub const Iterator = RepeatedIterator(T, element_kind);

        /// The elements a program sets to encode. Ignored when empty and `view` is set.
        items: []const T = &.{},
        /// Where `decode` found the elements.
        view: descriptor.View = .{},

        pub fn of(items: []const T) Self {
            return .{ .items = items };
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .items = self.items, .reader = .{ .bytes = self.view.bytes }, .number = self.view.number };
        }

        /// The number of elements. It reads every element of a view.
        pub fn count(self: *const Self) wire.Error!usize {
            if (self.items.len != 0 or self.view.bytes.len == 0) return self.items.len;
            return count_view(Iterator, self.iterator());
        }

        pub fn is_empty(self: *const Self) bool {
            return self.items.len == 0 and self.view.bytes.len == 0;
        }
    };
}

fn count_view(comptime Iterator: type, start: Iterator) wire.Error!usize {
    var elements = start;
    var total: usize = 0;
    for (0..constants.limits.elements_max) |_| {
        _ = try elements.next() orelse return total;
        total += 1;
    }
    unreachable;
}

/// Yields the elements of a `Repeated` field, from its items or from its view.
pub fn RepeatedIterator(comptime T: type, comptime element_kind: Kind) type {
    return struct {
        const Self = @This();
        items: []const T,
        index: usize = 0,
        reader: wire.Reader,
        number: u32,
        /// The rest of a packed record being read, or empty.
        packed_reader: wire.Reader = .{ .bytes = &.{} },

        pub fn next(it: *Self) wire.Error!?T {
            if (it.items.len != 0) return next_item(T, it);
            // A number a closed enum does not name stays with the unknown fields, so the
            // iterator passes over it (editions, "enum_type"). Each one takes an octet at least.
            for (0..it.reader.bytes.len + it.packed_reader.bytes.len + 1) |_| {
                const value = try next_read(T, element_kind, it) orelse return null;
                if (!decode.unknown_to_closed(element_kind, T, value)) return value;
            }
            unreachable;
        }
    };
}

fn next_read(comptime T: type, comptime element_kind: Kind, it: anytype) wire.Error!?T {
    if (!it.packed_reader.at_end()) return try read_scalar(T, element_kind, &it.packed_reader);
    return next_in_view(T, element_kind, it);
}

fn next_item(comptime T: type, it: anytype) ?T {
    if (it.index == it.items.len) return null;
    it.index += 1;
    return it.items[it.index - 1];
}

fn next_in_view(comptime T: type, comptime element_kind: Kind, it: anytype) wire.Error!?T {
    // Each field takes at least one byte, so the bytes left bound the fields.
    for (0..it.reader.bytes.len - it.reader.position + 1) |_| {
        if (it.reader.at_end()) return null;
        const tag = try it.reader.tag();
        if (tag.number != it.number) {
            try it.reader.skip(tag, constants.limits.depth_max);
            continue;
        }
        if (try element(T, element_kind, it, tag)) |value| return value;
    }
    unreachable;
}

/// The element a tag of the field starts, or null for an empty packed record.
fn element(comptime T: type, comptime element_kind: Kind, it: anytype, tag: wire.Tag) wire.Error!?T {
    if (comptime element_kind.packable()) {
        if (tag.wire_type == .len) {
            it.packed_reader = .{ .bytes = try it.reader.length_delimited() };
            if (it.packed_reader.at_end()) return null;
            return try read_scalar(T, element_kind, &it.packed_reader);
        }
    }
    // "Message Structure": a known field with another wire type is malformed.
    if (tag.wire_type != element_kind.wire_type()) return error.WireTypeMismatch;
    if (comptime element_kind.holds_message()) {
        const payload = try decode.message_payload(element_kind, tag, &it.reader, constants.limits.depth_max);
        // A map entry whose value its closed enum does not name goes with the unknown fields,
        // whole, as Go's runtime keeps it (editions, "enum_type").
        if (try entry_value_unknown(T, payload)) return null;
        return try decode.decode_shallow(T, payload);
    }
    return try read_scalar(T, element_kind, &it.reader);
}

fn read_scalar(comptime T: type, comptime element_kind: Kind, reader: *wire.Reader) wire.Error!T {
    if (comptime element_kind.holds_message()) unreachable;
    return scalar.read(element_kind, T, reader);
}

/// Whether a repeated field's elements are numbers of a closed enum, or map entries whose values
/// are: the elements a decoded view holds and its iterator passes over.
pub fn holds_closed(comptime F: type) bool {
    if (F.kind == .@"enum") return F.Element.protobuf.closed;
    if (!F.kind.holds_message() or !F.Element.protobuf.map_entry) return false;
    const V = @FieldType(F.Element, "value");
    return @typeInfo(V) == .@"enum" and @hasDecl(V, "protobuf") and V.protobuf.closed;
}

/// Whether `payload` is a map entry whose last value is a number its closed enum does not name.
pub fn entry_value_unknown(comptime Entry: type, payload: []const u8) wire.Error!bool {
    if (comptime !Entry.protobuf.map_entry) return false;
    const V = @FieldType(Entry, "value");
    if (comptime @typeInfo(V) != .@"enum" or !@hasDecl(V, "protobuf")) return false;
    if (comptime !V.protobuf.closed) return false;
    const number = comptime @intFromEnum(Entry.FieldNumber.value);
    var reader: wire.Reader = .{ .bytes = payload };
    var unknown = false;
    // Each record takes at least one byte. The last value wins ("Last One Wins").
    for (0..payload.len + 1) |_| {
        if (reader.at_end()) return unknown;
        const tag = try reader.tag();
        if (tag.number != number or tag.wire_type != .varint) {
            try reader.skip(tag, constants.limits.depth_max);
            continue;
        }
        unknown = decode.unknown_to_closed(.@"enum", V, try scalar.read(.@"enum", V, &reader));
    }
    unreachable;
}

/// Whether `T` is a type `Repeated` returned.
pub fn is_repeated(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Iterator") and @hasDecl(T, "Element") and @hasField(T, "view");
}

pub fn Lazy(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Message = T;

        /// The encoded message, which `decode` sets after it checked them.
        bytes: ?[]const u8 = null,
        /// The message a program sets to encode.
        value: ?*const T = null,

        pub fn of(value: *const T) Self {
            return .{ .value = value };
        }

        pub fn present(self: *const Self) bool {
            return self.bytes != null or self.value != null;
        }

        /// The message, decoded from `bytes` or copied from `value`, or null when absent.
        pub fn get(self: *const Self) wire.Error!?T {
            if (self.value) |value| return value.*;
            const bytes = self.bytes orelse return null;
            return try decode.decode_shallow(T, bytes);
        }
    };
}

pub fn is_lazy(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Message") and @hasField(T, "bytes") and @hasField(T, "value");
}

/// The value of the last entry of a map whose key is `key`, or null ("Maps": when a key repeats,
/// the last one wins).
pub fn map_get(comptime Map: type, map: *const Map, key: anytype) wire.Error!?@FieldType(Map.Element, "value") {
    var entries = map.iterator();
    var found: ?@FieldType(Map.Element, "value") = null;
    for (0..constants.limits.elements_max) |_| {
        const entry = try entries.next() orelse return found;
        if (keys_equal(entry.key, key)) found = entry.value;
    }
    unreachable;
}

fn keys_equal(a: anytype, b: @TypeOf(a)) bool {
    if (@TypeOf(a) == []const u8) return std.mem.eql(u8, a, b);
    return a == b;
}

const testing = std.testing;

test "an iterator reads packed and unpacked elements of one field in order" {
    // Field 4 unpacked 1, then packed {2, 3}, then field 5 (skipped), then unpacked 4.
    const bytes = [_]u8{ 0x20, 0x01, 0x22, 0x02, 0x02, 0x03, 0x28, 0x09, 0x20, 0x04 };
    const Field = Repeated(i32, .int32);
    const field: Field = .{ .view = .{ .bytes = &bytes, .number = 4 } };
    var it = field.iterator();
    for ([_]i32{ 1, 2, 3, 4 }) |want| try testing.expectEqual(want, (try it.next()).?);
    try testing.expectEqual(@as(?i32, null), try it.next());
    try testing.expectEqual(@as(usize, 4), try field.count());
}

test "items are yielded as set, and a wrong wire type is refused" {
    const field = Repeated(u64, .uint64).of(&.{ 7, 8 });
    var it = field.iterator();
    try testing.expectEqual(@as(u64, 7), (try it.next()).?);
    try testing.expectEqual(@as(u64, 8), (try it.next()).?);
    try testing.expectEqual(@as(?u64, null), try it.next());
    const strings: Repeated([]const u8, .string) = .{ .view = .{ .bytes = &.{ 0x08, 0x01 }, .number = 1 } };
    var bad = strings.iterator();
    try testing.expectError(error.WireTypeMismatch, bad.next());
}
