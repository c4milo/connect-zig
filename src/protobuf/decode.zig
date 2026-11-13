//! Decodes an encoded message into a generated struct, copying nothing: strings and bytes are
//! slices of the input, and repeated fields are views of it. The input must outlive the struct.
//!
//! Merge semantics follow "Last One Wins" in the encoding guide: a scalar that repeats keeps its
//! last value, a singular message that repeats merges, and a oneof keeps the member read last.
//! A message that keeps unknown fields keeps them as one span of the input (decision 24). A
//! number a closed enum does not name joins them, and its field stays as it was.
const std = @import("std");
const assert = std.debug.assert;
const wire = @import("wire.zig");
const descriptor = @import("descriptor.zig");
const scalar = @import("scalar.zig");
const repeated = @import("repeated.zig");
const constants = @import("constants.zig");
const decode_run = @import("decode_run.zig");
const Field = descriptor.Field;
const Kind = descriptor.Kind;

pub const Error = wire.Error;

/// The caller's storage for the elements of repeated fields (decision 37).
pub const Store = decode_run.Store;

/// Decodes `bytes` as a `T`, following messages at most `depth_left` deep.
pub fn decode_depth(comptime T: type, bytes: []const u8, depth_left: u32, comptime mode: Mode, store: StoreOf(mode)) Error!T {
    var message: T = .{};
    try merge_depth(T, &message, bytes, depth_left, mode, store);
    return message;
}

/// How far a decode checks the payloads it keeps as bytes, `Lazy` fields and repeated fields, and
/// where it keeps them.
pub const Mode = enum {
    /// Each kept payload is decoded once and thrown away, so a malformed one fails here.
    checked,
    /// Each kept payload is decoded once, as `checked` decodes it, into the caller's storage
    /// while it has room (decision 37). The mode is known at compile time, so a decode with no
    /// storage is `checked` alone and pays nothing for it.
    stored,
    /// Kept payloads are not decoded. `Lazy.get` and a repeated field's iterator use it for
    /// bytes `decode` already checked: checking again at every level would cost each level its
    /// whole subtree. Bytes a program set itself fail when that level is read, never earlier.
    shallow,
};

/// What a decode in `mode` keeps its storage in: a `Store` when it stores, and nothing otherwise.
pub fn StoreOf(comptime mode: Mode) type {
    return if (mode == .stored) *Store else void;
}

/// Decodes one level of `bytes`, which leaves its `Lazy` and repeated message payloads unchecked.
pub fn decode_shallow(comptime T: type, bytes: []const u8) Error!T {
    var message: T = .{};
    try merge_depth(T, &message, bytes, constants.limits.depth_max, .shallow, {});
    return message;
}

/// Merges `bytes` into `message`, as a second occurrence of the message would merge.
pub fn merge_depth(comptime T: type, message: *T, bytes: []const u8, depth_left: u32, comptime mode: Mode, store: StoreOf(mode)) Error!void {
    comptime descriptor.check(T);
    assert(bytes.len <= constants.limits.message_len_max);
    if (depth_left == 0) return error.DepthExceeded;
    var reader: wire.Reader = .{ .bytes = bytes };
    // Each field takes at least one byte, so the input's length bounds the fields.
    for (0..bytes.len + 1) |_| {
        if (reader.at_end()) return;
        const field_start = reader.position;
        const tag = try reader.tag();
        const read = try read_known(T, message, field_start, bytes, tag, &reader, depth_left, mode, store);
        if (read == .field) continue;
        if (read == .absent) try reader.skip(tag, depth_left);
        if (comptime descriptor.keeps_unknown(T)) try keep_unknown(&@field(message, descriptor.unknown_field), bytes, field_start, reader.position);
    }
    unreachable;
}

/// What became of a record: its field took it, its value is unknown to the field's closed enum, or
/// the message has no field of its number.
const Read = enum { field, unknown_value, absent };

/// `field_start` is where the field's tag starts in `bytes`, where a repeated field's view
/// starts, so the view holds the field's records and not the whole message.
fn read_known(comptime T: type, message: *T, field_start: usize, bytes: []const u8, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode, store: StoreOf(mode)) Error!Read {
    inline for (T.protobuf.fields) |field| {
        if (tag.number == field.number) return read_field(T, field, message, field_start, bytes, tag, reader, depth_left, mode, store);
    }
    return .absent;
}

/// Whether `value` is a number its closed enum does not name, which a parser keeps with the
/// unknown fields (editions, "enum_type").
pub fn unknown_to_closed(comptime kind: Kind, comptime V: type, value: V) bool {
    if (comptime kind != .@"enum") return false;
    if (comptime !V.protobuf.closed) return false;
    return !V.protobuf.contains(@intFromEnum(value));
}

fn read_field(comptime T: type, comptime field: Field, message: *T, field_start: usize, bytes: []const u8, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode, store: StoreOf(mode)) Error!Read {
    if (field.oneof) |oneof| return read_oneof(T, field, oneof, message, tag, reader, depth_left, mode, store);
    const F = @FieldType(T, field.name);
    const slot = &@field(message, field.name);
    if (comptime repeated.is_repeated(F)) {
        try read_repeated_field(F, slot, field_start, bytes, field.number, tag, reader, depth_left, mode, store);
    } else if (comptime repeated.is_lazy(F)) {
        try read_lazy(F, field.kind, slot, tag, reader, depth_left, mode, store);
    } else if (comptime field.kind.holds_message()) {
        const Child = @typeInfo(F).optional.child;
        if (slot.* == null) slot.* = .{};
        try read_message(Child, field.kind, &slot.*.?, tag, reader, depth_left, mode, store);
    } else {
        const V = switch (@typeInfo(F)) {
            .optional => |optional| optional.child,
            else => F,
        };
        const value = try read_value(field.kind, V, tag, reader);
        if (unknown_to_closed(field.kind, V, value)) return .unknown_value;
        slot.* = value;
    }
    return .field;
}

/// A repeated field's record: into storage in the stored mode, and into the field's view in any
/// other. A closed enum's field passes over numbers it does not name, so it keeps its view.
inline fn read_repeated_field(comptime F: type, slot: *F, field_start: usize, bytes: []const u8, number: u32, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode, store: StoreOf(mode)) Error!void {
    if (comptime mode == .stored and !repeated.holds_closed(F)) return decode_run.read(F, slot, field_start, bytes, number, tag, reader, depth_left, store);
    // Inline here whatever else calls it: `decode_run`'s fallbacks made LLVM call it out of line,
    // and `decode` took up to 39% more instructions (docs/performance.md, pitfalls).
    return @call(.always_inline, read_repeated, .{ F, slot, field_start, bytes, number, tag, reader, depth_left, if (mode == .shallow) .shallow else .checked });
}

fn read_value(comptime kind: Kind, comptime V: type, tag: wire.Tag, reader: *wire.Reader) Error!V {
    // "Message Structure": a known field whose wire type is not its kind's is malformed.
    if (tag.wire_type != kind.wire_type()) return error.WireTypeMismatch;
    return scalar.read(kind, V, reader);
}

/// The bytes of an embedded message: after its length, or between its group tags.
pub fn message_payload(comptime kind: Kind, tag: wire.Tag, reader: *wire.Reader, depth_left: u32) Error![]const u8 {
    // "Message Structure": an embedded message is length-delimited, and a group is written
    // between a start and an end tag ("Groups").
    if (tag.wire_type != kind.wire_type()) return error.WireTypeMismatch;
    if (kind == .group) return reader.group_payload(tag.number, depth_left);
    return reader.length_delimited();
}

fn read_message(comptime M: type, comptime kind: Kind, slot: *M, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode, store: StoreOf(mode)) Error!void {
    const payload = try message_payload(kind, tag, reader, depth_left);
    try merge_depth(M, slot, payload, depth_left - 1, mode, store);
}

fn read_lazy(comptime F: type, comptime kind: Kind, slot: *F, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode, store: StoreOf(mode)) Error!void {
    const payload = try message_payload(kind, tag, reader, depth_left);
    if (mode == .stored) return read_lazy_stored(F, slot, payload, depth_left, store);
    // The payload is checked once here, so `Lazy.get` reads only checked bytes.
    if (mode == .checked) _ = try decode_depth(F.Message, payload, depth_left - 1, .checked, {});
    if (slot.present()) return error.MergeUnsupported;
    slot.* = .{ .bytes = payload };
}

/// With room, the message a `Lazy` payload decodes to stays in `store`, and `Lazy.get` copies
/// it (decision 37). Without, the field keeps the payload alone.
fn read_lazy_stored(comptime F: type, slot: *F, payload: []const u8, depth_left: u32, store: *Store) Error!void {
    const room = store.reserve(F.Message, 1);
    const child = try decode_depth(F.Message, payload, depth_left - 1, .stored, store);
    if (slot.present()) return error.MergeUnsupported;
    const kept = room orelse {
        slot.* = .{ .bytes = payload };
        return;
    };
    kept[0] = child;
    slot.* = .{ .bytes = payload, .value = &kept[0] };
}

pub fn read_repeated(comptime F: type, slot: *F, field_start: usize, bytes: []const u8, number: u32, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode) Error!void {
    if (!view_within(slot.view.bytes, bytes) or slot.items.len != 0) return error.MergeUnsupported;
    if (comptime F.kind.packable()) {
        // "Packed Repeated Fields": a parser accepts the packed form for any packable field.
        if (tag.wire_type == .len) try check_packed(F, try reader.length_delimited());
    }
    if (tag.wire_type != .len or !comptime F.kind.packable()) {
        if (tag.wire_type != F.kind.wire_type()) return error.WireTypeMismatch;
        if (comptime F.kind.holds_message()) {
            const payload = try message_payload(F.kind, tag, reader, depth_left);
            if (mode == .checked) _ = try decode_depth(F.Element, payload, depth_left - 1, .checked, {});
        } else {
            _ = try scalar.read(F.kind, F.Element, reader);
        }
    }
    extend_view(&slot.view, bytes, field_start, reader.position, number);
}

/// Whether a field's view lies in `bytes`, or is not set. A view of another message's bytes
/// means the field already came from a merge, which a view cannot hold (decision 6).
fn view_within(view: []const u8, bytes: []const u8) bool {
    if (view.len == 0) return true;
    const start = @intFromPtr(view.ptr);
    return start >= @intFromPtr(bytes.ptr) and start + view.len <= @intFromPtr(bytes.ptr) + bytes.len;
}

/// Widens a message's span of unknown fields to end at `field_end`. A span of another input means
/// the message came from a merge of two inputs, which one span cannot hold (decisions 6, 24).
fn keep_unknown(unknown: *descriptor.Unknown, bytes: []const u8, field_start: usize, field_end: usize) Error!void {
    assert(field_start < field_end and field_end <= bytes.len);
    if (!view_within(unknown.bytes, bytes)) return error.MergeUnsupported;
    const start = if (unknown.bytes.len == 0) field_start else @intFromPtr(unknown.bytes.ptr) - @intFromPtr(bytes.ptr);
    unknown.bytes = bytes[start..field_end];
}

/// Makes a view hold the field's records from its first through the one that ends at
/// `field_end`. Other fields' records between them stay in it, and the iterator skips them.
pub fn extend_view(view: *descriptor.View, bytes: []const u8, field_start: usize, field_end: usize, number: u32) void {
    assert(field_start < field_end and field_end <= bytes.len);
    const start = if (view.bytes.len == 0) field_start else @intFromPtr(view.bytes.ptr) - @intFromPtr(bytes.ptr);
    view.* = .{ .bytes = bytes[start..field_end], .number = number };
}

fn check_packed(comptime F: type, payload: []const u8) Error!void {
    var packed_reader: wire.Reader = .{ .bytes = payload };
    // Each element takes at least one byte.
    for (0..payload.len + 1) |_| {
        if (packed_reader.at_end()) return;
        _ = try scalar.read(F.kind, F.Element, &packed_reader);
    }
    unreachable;
}

fn read_oneof(comptime T: type, comptime field: Field, comptime oneof: []const u8, message: *T, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode, store: StoreOf(mode)) Error!Read {
    const U = @typeInfo(@FieldType(T, oneof)).optional.child;
    const V = @FieldType(U, field.name);
    const slot = &@field(message, oneof);
    if (comptime !field.kind.holds_message()) {
        const value = try read_value(field.kind, V, tag, reader);
        // A number the closed enum does not name leaves the oneof as it was.
        if (unknown_to_closed(field.kind, V, value)) return .unknown_value;
        slot.* = @unionInit(U, field.name, value);
        return .field;
    }
    if (comptime repeated.is_lazy(V)) {
        var lazy: V = .{};
        try read_lazy(V, field.kind, &lazy, tag, reader, depth_left, mode, store);
        slot.* = @unionInit(U, field.name, lazy);
        return .field;
    }
    // "Oneof": a member that repeats merges when it is still the one set.
    const same = if (slot.*) |active| active == @field(std.meta.Tag(U), field.name) else false;
    if (!same) slot.* = @unionInit(U, field.name, .{});
    try read_message(V, field.kind, &@field(slot.*.?, field.name), tag, reader, depth_left, mode, store);
    return .field;
}
