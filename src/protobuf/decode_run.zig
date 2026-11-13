//! Reads a repeated field's records into storage the caller owns (decision 37). A run is a
//! field's records from one to the last before another field's. Its elements go into the
//! storage once, so an iterator reads them as a slice and parses nothing again.
//!
//! A run whose elements hold no repeated field of their own takes one pass: each element follows
//! the one before, since nothing else takes storage while it is read. Any other run is counted
//! first, so its elements stay together while their own runs take storage after them. A field
//! whose records come in two runs, or a run that finds no room, keeps decision 6's view alone,
//! and a decode refuses the same inputs either way.
const std = @import("std");
const assert = std.debug.assert;
const wire = @import("wire.zig");
const descriptor = @import("descriptor.zig");
const scalar = @import("scalar.zig");
const repeated = @import("repeated.zig");
const decode = @import("decode.zig");
const constants = @import("constants.zig");
const Error = decode.Error;

/// The caller's storage, which a decode fills from its start.
pub const Store = struct {
    buffer: []u8,
    len: usize = 0,

    /// Room for `count` elements of `T` past what the store holds, or null when it has none.
    pub fn reserve(store: *Store, comptime T: type, count: usize) ?[]T {
        const start = store.aligned(T) orelse return null;
        if (count > (store.buffer.len - start) / @sizeOf(T)) return null;
        store.len = start + count * @sizeOf(T);
        const first: [*]T = @ptrCast(@alignCast(store.buffer.ptr + start));
        return first[0..count];
    }

    /// Where the next `T` would start, or null past the buffer's end.
    fn aligned(store: *const Store, comptime T: type) ?usize {
        assert(store.len <= store.buffer.len);
        const base = @intFromPtr(store.buffer.ptr);
        const start = std.mem.alignForward(usize, base + store.len, @alignOf(T)) - base;
        if (start > store.buffer.len) return null;
        return start;
    }
};

/// Reads the run of the field's records that starts at the record whose tag the reader just read,
/// into `store`. A field that already holds a view, or a run that finds no room, takes the view
/// alone, as `decode.read_repeated` reads it.
pub fn read(comptime F: type, slot: *F, field_start: usize, bytes: []const u8, number: u32, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, store: *Store) Error!void {
    comptime assert(!repeated.holds_closed(F));
    if (store.buffer.len == 0 or slot.view.bytes.len != 0 or slot.items.len != 0) {
        // A second run of the field's records keeps them all in the view.
        slot.items = &.{};
        return decode.read_repeated(F, slot, field_start, bytes, number, tag, reader, depth_left, .checked);
    }
    if (comptime flat(F)) return read_appended(F, slot, field_start, bytes, number, tag, reader, depth_left, store);
    // A run the count cannot pass over is read as the view reads it, so its refusal is the same.
    const count = run_count(F, bytes, field_start, number) catch
        return decode.read_repeated(F, slot, field_start, bytes, number, tag, reader, depth_left, .checked);
    const items = store.reserve(F.Element, count) orelse
        return decode.read_repeated(F, slot, field_start, bytes, number, tag, reader, depth_left, .checked);
    const read_count = read_records(F, slot, items, field_start, bytes, number, tag, reader, depth_left, store) catch |failure| switch (failure) {
        // The count and the records disagree only in a malformed run.
        error.NoRoom => return error.Truncated,
        else => |other| return other,
    };
    if (read_count != count) return error.Truncated;
    slot.items = items;
}

/// Whether the field's elements hold no repeated field and no message of their own, so reading
/// one takes no storage but its own place.
fn flat(comptime F: type) bool {
    if (!F.kind.holds_message()) return true;
    const E = F.Element;
    for (E.protobuf.fields) |field| {
        if (field.kind.holds_message()) return false;
        if (field.oneof == null and repeated.is_repeated(@FieldType(E, field.name))) return false;
    }
    return true;
}

/// Reads a run of flat elements, each one after the one before, at the store's end.
fn read_appended(comptime F: type, slot: *F, field_start: usize, bytes: []const u8, number: u32, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, store: *Store) Error!void {
    const T = F.Element;
    const start = store.aligned(T) orelse
        return decode.read_repeated(F, slot, field_start, bytes, number, tag, reader, depth_left, .checked);
    const first: [*]T = @ptrCast(@alignCast(store.buffer.ptr + start));
    const room = first[0 .. (store.buffer.len - start) / @sizeOf(T)];
    const before = reader.*;
    const count = read_records(F, slot, room, field_start, bytes, number, tag, reader, depth_left, store) catch |failure| switch (failure) {
        error.NoRoom => {
            // The run outgrew the store: the view alone holds the field, as with no storage. The
            // view already starts at the run's first record, so reading the run again widens it.
            reader.* = before;
            return decode.read_repeated(F, slot, field_start, bytes, number, tag, reader, depth_left, .checked);
        },
        else => |other| return other,
    };
    store.len = start + count * @sizeOf(T);
    slot.items = first[0..count];
}

/// Reads each record of the run into `items`, widens the field's view over it, and returns the
/// count of elements read.
fn read_records(comptime F: type, slot: *F, items: []F.Element, field_start: usize, bytes: []const u8, number: u32, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, store: *Store) (Error || error{NoRoom})!usize {
    var count: usize = 0;
    var record_tag = tag;
    // Each record takes at least one byte.
    for (0..bytes.len + 1) |_| {
        count = try read_record(F, items, count, record_tag, reader, depth_left, store);
        // The view starts at the run's first record, and each record widens it to its end.
        decode.extend_view(&slot.view, bytes, field_start, reader.position, number);
        if (reader.at_end()) return count;
        var peek = reader.*;
        const next_tag = try peek.tag();
        if (next_tag.number != number) return count;
        reader.* = peek;
        record_tag = next_tag;
    }
    unreachable;
}

/// Reads one record's elements into `items` from `index`, and returns the index past them.
fn read_record(comptime F: type, items: []F.Element, index: usize, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, store: *Store) (Error || error{NoRoom})!usize {
    if (comptime F.kind.packable()) {
        // "Packed Repeated Fields": a parser accepts the packed form for any packable field.
        if (tag.wire_type == .len) return read_packed(F, items, index, try reader.length_delimited());
    }
    // "Message Structure": a known field with another wire type is malformed.
    if (tag.wire_type != F.kind.wire_type()) return error.WireTypeMismatch;
    if (index == items.len) return error.NoRoom;
    if (comptime F.kind.holds_message()) {
        const payload = try decode.message_payload(F.kind, tag, reader, depth_left);
        items[index] = .{};
        try decode.merge_depth(F.Element, &items[index], payload, depth_left - 1, .stored, store);
    } else {
        items[index] = try scalar.read(F.kind, F.Element, reader);
    }
    return index + 1;
}

fn read_packed(comptime F: type, items: []F.Element, start_index: usize, payload: []const u8) (Error || error{NoRoom})!usize {
    if (comptime F.kind.wire_type() == .varint) return read_packed_varints(F, items, start_index, payload);
    var packed_reader: wire.Reader = .{ .bytes = payload };
    var index = start_index;
    // Each element takes at least one byte.
    for (0..payload.len + 1) |_| {
        if (packed_reader.at_end()) return index;
        if (index == items.len) return error.NoRoom;
        items[index] = try scalar.read(F.kind, F.Element, &packed_reader);
        index += 1;
    }
    unreachable;
}

/// Reads a packed record of varints with its position in a local, each varint with no call: a
/// reader's address would put the position in memory at each element, and each element would
/// wait for the one before it to store it.
fn read_packed_varints(comptime F: type, items: []F.Element, start_index: usize, payload: []const u8) (Error || error{NoRoom})!usize {
    var index = start_index;
    var position: usize = 0;
    // Each element takes at least one byte.
    for (0..payload.len + 1) |_| {
        if (position == payload.len) return index;
        if (index == items.len) return error.NoRoom;
        items[index] = scalar.from_varint(F.kind, F.Element, try packed_varint(payload, &position));
        index += 1;
    }
    unreachable;
}

/// The varint at `position.*`, which it moves past the varint. It is inline, so the caller's
/// position stays in a register.
inline fn packed_varint(payload: []const u8, position: *usize) Error!u64 {
    const group_bits = constants.protocol.varint_group_bits;
    const continuation = constants.protocol.varint_continuation;
    const payload_mask = constants.protocol.varint_payload_mask;
    const two_octets = 2;
    // A varint of one or two octets, as most small numbers are, takes no loop.
    const first = payload[position.*];
    if (first < continuation) {
        position.* += 1;
        return first;
    }
    if (position.* + 1 < payload.len and payload[position.* + 1] < continuation) {
        const second = payload[position.* + 1];
        position.* += two_octets;
        return @as(u64, first & payload_mask) | @as(u64, second) << group_bits;
    }
    var varint: u64 = 0;
    // "Base 128 Varints": at most 10 octets, the last one with no continuation bit. The tenth
    // carries bit 63 alone; higher bits fall off the 64-bit value.
    for (0..constants.protocol.varint_len_max) |group| {
        if (position.* == payload.len) return error.Truncated;
        const octet = payload[position.*];
        position.* += 1;
        varint |= @as(u64, octet & payload_mask) << @intCast(group * group_bits);
        if (octet < continuation) return varint;
    }
    return error.VarintTooLong;
}

/// The records of the field's run that starts at `field_start`: one message element each. A
/// counted run holds messages alone, since every other element is flat.
fn run_count(comptime F: type, bytes: []const u8, field_start: usize, number: u32) Error!usize {
    comptime assert(F.kind.holds_message());
    var reader: wire.Reader = .{ .bytes = bytes, .position = field_start };
    var count: usize = 0;
    // Each record takes at least one byte.
    for (0..bytes.len + 1) |_| {
        if (reader.at_end()) return count;
        const tag = try reader.tag();
        if (tag.number != number) return count;
        count += 1;
        try reader.skip(tag, constants.limits.depth_max);
    }
    unreachable;
}
