//! Decodes an encoded message into a generated struct, copying nothing: strings and bytes are
//! slices of the input, and repeated fields are views of it. The input must outlive the struct.
//!
//! Merge semantics follow "Last One Wins" in the encoding guide: a scalar that repeats keeps its
//! last value, a singular message that repeats merges, and a oneof keeps the member read last.
//! Unknown fields, groups included, are skipped and dropped (docs/decisions.md entry 5).
const std = @import("std");
const assert = std.debug.assert;
const wire = @import("wire.zig");
const descriptor = @import("descriptor.zig");
const scalar = @import("scalar.zig");
const repeated = @import("repeated.zig");
const constants = @import("constants.zig");
const Field = descriptor.Field;
const Kind = descriptor.Kind;

pub const Error = wire.Error;

/// Decodes `bytes` as a `T`, following messages at most `depth_left` deep.
pub fn decode_depth(comptime T: type, bytes: []const u8, depth_left: u32) Error!T {
    var message: T = .{};
    try merge_depth(T, &message, bytes, depth_left, .checked);
    return message;
}

/// How far a decode checks the payloads it keeps as bytes: `Lazy` fields and repeated message
/// fields.
pub const Mode = enum {
    /// Each kept payload is decoded once and thrown away, so a malformed one fails here.
    checked,
    /// Kept payloads are not decoded. `Lazy.get` and a repeated field's iterator use it for
    /// bytes `decode` already checked: checking again at every level would cost each level its
    /// whole subtree. Bytes a program set itself fail when that level is read, never earlier.
    shallow,
};

/// Decodes one level of `bytes`, which leaves its `Lazy` and repeated message payloads unchecked.
pub fn decode_shallow(comptime T: type, bytes: []const u8) Error!T {
    var message: T = .{};
    try merge_depth(T, &message, bytes, constants.limits.depth_max, .shallow);
    return message;
}

/// Merges `bytes` into `message`, as a second occurrence of the message would merge.
pub fn merge_depth(comptime T: type, message: *T, bytes: []const u8, depth_left: u32, comptime mode: Mode) Error!void {
    comptime descriptor.check(T);
    assert(bytes.len <= constants.limits.message_len_max);
    if (depth_left == 0) return error.DepthExceeded;
    var reader: wire.Reader = .{ .bytes = bytes };
    // Each field takes at least one byte, so the input's length bounds the fields.
    for (0..bytes.len + 1) |_| {
        if (reader.at_end()) return;
        const field_start = reader.position;
        const tag = try reader.tag();
        const known = try read_known(T, message, field_start, bytes, tag, &reader, depth_left, mode);
        if (!known) try reader.skip(tag, depth_left);
    }
    unreachable;
}

/// `field_start` is where the field's tag starts in `bytes`, where a repeated field's view
/// starts, so the view holds the field's records and not the whole message.
fn read_known(comptime T: type, message: *T, field_start: usize, bytes: []const u8, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode) Error!bool {
    inline for (T.protobuf.fields) |field| {
        if (tag.number == field.number) {
            try read_field(T, field, message, field_start, bytes, tag, reader, depth_left, mode);
            return true;
        }
    }
    return false;
}

fn read_field(comptime T: type, comptime field: Field, message: *T, field_start: usize, bytes: []const u8, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode) Error!void {
    if (field.oneof) |oneof| return read_oneof(T, field, oneof, message, tag, reader, depth_left, mode);
    const F = @FieldType(T, field.name);
    const slot = &@field(message, field.name);
    if (comptime repeated.is_repeated(F)) return read_repeated(F, slot, field_start, bytes, field.number, tag, reader, depth_left, mode);
    if (comptime repeated.is_lazy(F)) return read_lazy(F, slot, tag, reader, depth_left, mode);
    if (comptime field.kind == .message) {
        const Child = @typeInfo(F).optional.child;
        if (slot.* == null) slot.* = .{};
        return read_message(Child, &slot.*.?, tag, reader, depth_left, mode);
    }
    const V = switch (@typeInfo(F)) {
        .optional => |optional| optional.child,
        else => F,
    };
    slot.* = try read_value(field.kind, V, tag, reader);
}

fn read_value(comptime kind: Kind, comptime V: type, tag: wire.Tag, reader: *wire.Reader) Error!V {
    // "Message Structure": a known field whose wire type is not its kind's is malformed.
    if (tag.wire_type != kind.wire_type()) return error.WireTypeMismatch;
    return scalar.read(kind, V, reader);
}

fn read_message(comptime M: type, slot: *M, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode) Error!void {
    // "Message Structure": an embedded message is length-delimited.
    if (tag.wire_type != .len) return error.WireTypeMismatch;
    const payload = try reader.length_delimited();
    try merge_depth(M, slot, payload, depth_left - 1, mode);
}

fn read_lazy(comptime F: type, slot: *F, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode) Error!void {
    if (tag.wire_type != .len) return error.WireTypeMismatch;
    const payload = try reader.length_delimited();
    // The payload is checked once here, so `Lazy.get` reads only checked bytes.
    if (mode == .checked) _ = try decode_depth(F.Message, payload, depth_left - 1);
    if (slot.present()) return error.MergeUnsupported;
    slot.* = .{ .bytes = payload };
}

fn read_repeated(comptime F: type, slot: *F, field_start: usize, bytes: []const u8, number: u32, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode) Error!void {
    if (!view_within(slot.view.bytes, bytes) or slot.items.len != 0) return error.MergeUnsupported;
    if (comptime F.kind.packable()) {
        // "Packed Repeated Fields": a parser accepts the packed form for any packable field.
        if (tag.wire_type == .len) try check_packed(F, try reader.length_delimited());
    }
    if (tag.wire_type != .len or !comptime F.kind.packable()) {
        if (tag.wire_type != F.kind.wire_type()) return error.WireTypeMismatch;
        if (comptime F.kind == .message) {
            const payload = try reader.length_delimited();
            if (mode == .checked) _ = try decode_depth(F.Element, payload, depth_left - 1);
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

/// Makes a view hold the field's records from its first through the one that ends at
/// `field_end`. Other fields' records between them stay in it, and the iterator skips them.
fn extend_view(view: *descriptor.View, bytes: []const u8, field_start: usize, field_end: usize, number: u32) void {
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

fn read_oneof(comptime T: type, comptime field: Field, comptime oneof: []const u8, message: *T, tag: wire.Tag, reader: *wire.Reader, depth_left: u32, comptime mode: Mode) Error!void {
    const U = @typeInfo(@FieldType(T, oneof)).optional.child;
    const V = @FieldType(U, field.name);
    const slot = &@field(message, oneof);
    if (comptime field.kind != .message) {
        slot.* = @unionInit(U, field.name, try read_value(field.kind, V, tag, reader));
        return;
    }
    if (comptime repeated.is_lazy(V)) {
        var lazy: V = .{};
        try read_lazy(V, &lazy, tag, reader, depth_left, mode);
        slot.* = @unionInit(U, field.name, lazy);
        return;
    }
    // "Oneof": a member that repeats merges when it is still the one set.
    const same = if (slot.*) |active| active == @field(std.meta.Tag(U), field.name) else false;
    if (!same) slot.* = @unionInit(U, field.name, .{});
    try read_message(V, &@field(slot.*.?, field.name), tag, reader, depth_left, mode);
}
