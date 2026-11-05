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
    try merge_depth(T, &message, bytes, depth_left);
    return message;
}

/// Merges `bytes` into `message`, as a second occurrence of the message would merge.
pub fn merge_depth(comptime T: type, message: *T, bytes: []const u8, depth_left: u32) Error!void {
    comptime descriptor.check(T);
    assert(bytes.len <= constants.limits.message_len_max);
    if (depth_left == 0) return error.DepthExceeded;
    var reader: wire.Reader = .{ .bytes = bytes };
    // Each field takes at least one byte, so the input's length bounds the fields.
    for (0..bytes.len + 1) |_| {
        if (reader.at_end()) return;
        const tag = try reader.tag();
        const known = try read_known(T, message, bytes, tag, &reader, depth_left);
        if (!known) try reader.skip(tag, depth_left);
    }
    unreachable;
}

fn read_known(comptime T: type, message: *T, bytes: []const u8, tag: wire.Tag, reader: *wire.Reader, depth_left: u32) Error!bool {
    inline for (T.protobuf.fields) |field| {
        if (tag.number == field.number) {
            try read_field(T, field, message, bytes, tag, reader, depth_left);
            return true;
        }
    }
    return false;
}

fn read_field(comptime T: type, comptime field: Field, message: *T, bytes: []const u8, tag: wire.Tag, reader: *wire.Reader, depth_left: u32) Error!void {
    if (field.oneof) |oneof| return read_oneof(T, field, oneof, message, tag, reader, depth_left);
    const F = @FieldType(T, field.name);
    const slot = &@field(message, field.name);
    if (comptime repeated.is_repeated(F)) return read_repeated(F, slot, bytes, field.number, tag, reader, depth_left);
    if (comptime repeated.is_lazy(F)) return read_lazy(F, slot, tag, reader, depth_left);
    if (comptime field.kind == .message) {
        const Child = @typeInfo(F).optional.child;
        if (slot.* == null) slot.* = .{};
        return read_message(Child, &slot.*.?, tag, reader, depth_left);
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

fn read_message(comptime M: type, slot: *M, tag: wire.Tag, reader: *wire.Reader, depth_left: u32) Error!void {
    // "Message Structure": an embedded message is length-delimited.
    if (tag.wire_type != .len) return error.WireTypeMismatch;
    const payload = try reader.length_delimited();
    try merge_depth(M, slot, payload, depth_left - 1);
}

fn read_lazy(comptime F: type, slot: *F, tag: wire.Tag, reader: *wire.Reader, depth_left: u32) Error!void {
    if (tag.wire_type != .len) return error.WireTypeMismatch;
    const payload = try reader.length_delimited();
    // The payload is checked once here, so `Lazy.get` reads only checked bytes.
    _ = try decode_depth(F.Message, payload, depth_left - 1);
    if (slot.present()) return error.MergeUnsupported;
    slot.* = .{ .bytes = payload };
}

fn read_repeated(comptime F: type, slot: *F, bytes: []const u8, number: u32, tag: wire.Tag, reader: *wire.Reader, depth_left: u32) Error!void {
    const view_elsewhere = slot.view.bytes.len != 0 and slot.view.bytes.ptr != bytes.ptr;
    if (view_elsewhere or slot.items.len != 0) return error.MergeUnsupported;
    if (comptime F.kind.packable()) {
        // "Packed Repeated Fields": a parser accepts the packed form for any packable field.
        if (tag.wire_type == .len) return check_packed(F, try reader.length_delimited(), bytes, number, slot);
    }
    if (tag.wire_type != F.kind.wire_type()) return error.WireTypeMismatch;
    if (comptime F.kind == .message) {
        _ = try decode_depth(F.Element, try reader.length_delimited(), depth_left - 1);
    } else {
        _ = try scalar.read(F.kind, F.Element, reader);
    }
    slot.view = .{ .bytes = bytes, .number = number };
}

fn check_packed(comptime F: type, payload: []const u8, bytes: []const u8, number: u32, slot: *F) Error!void {
    var packed_reader: wire.Reader = .{ .bytes = payload };
    // Each element takes at least one byte.
    for (0..payload.len + 1) |_| {
        if (packed_reader.at_end()) {
            slot.view = .{ .bytes = bytes, .number = number };
            return;
        }
        _ = try scalar.read(F.kind, F.Element, &packed_reader);
    }
    unreachable;
}

fn read_oneof(comptime T: type, comptime field: Field, comptime oneof: []const u8, message: *T, tag: wire.Tag, reader: *wire.Reader, depth_left: u32) Error!void {
    const U = @typeInfo(@FieldType(T, oneof)).optional.child;
    const V = @FieldType(U, field.name);
    const slot = &@field(message, oneof);
    if (comptime field.kind != .message) {
        slot.* = @unionInit(U, field.name, try read_value(field.kind, V, tag, reader));
        return;
    }
    if (comptime repeated.is_lazy(V)) {
        var lazy: V = .{};
        try read_lazy(V, &lazy, tag, reader, depth_left);
        slot.* = @unionInit(U, field.name, lazy);
        return;
    }
    // "Oneof": a member that repeats merges when it is still the one set.
    const same = if (slot.*) |active| active == @field(std.meta.Tag(U), field.name) else false;
    if (!same) slot.* = @unionInit(U, field.name, .{});
    try read_message(V, &@field(slot.*.?, field.name), tag, reader, depth_left);
}
