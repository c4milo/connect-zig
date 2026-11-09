//! Encodes a generated struct into storage the caller owns, fields in number order ("Field
//! Order": serializers write known fields in field-number order). One walk serves both
//! `encoded_len` and `encode`, through a `Sink` that counts or writes, so the two cannot disagree.
//!
//! What is written follows field presence (proto3 language guide, "Field Presence"): an
//! implicit-presence scalar is left off at its default, a `?T` field is written when set, a
//! oneof writes its set member even at its default, and a repeated packable field is packed.
const std = @import("std");
const assert = std.debug.assert;
const wire = @import("wire.zig");
const descriptor = @import("descriptor.zig");
const scalar = @import("scalar.zig");
const repeated = @import("repeated.zig");
const decode = @import("decode.zig");
const constants = @import("constants.zig");
const Field = descriptor.Field;
const Kind = descriptor.Kind;

pub const Error = wire.Error || wire.Writer.WriteError;

/// Counts the bytes a message takes, or writes them when `writer` is set.
const Sink = struct {
    writer: ?*wire.Writer,
    len: usize = 0,
    /// The buffer had no room for a length placeholder, so every child from here is measured
    /// before it is written: retrying the placeholder at each level would repeat the work.
    measured: bool = false,

    fn varint(sink: *Sink, number: u64) Error!void {
        if (sink.writer) |writer| try writer.varint(number);
        sink.len += wire.varint_len(number);
    }

    fn tag(sink: *Sink, number: u32, wire_type: wire.WireType) Error!void {
        try sink.varint((wire.Tag{ .number = number, .wire_type = wire_type }).encode());
    }

    fn raw(sink: *Sink, octets: []const u8) Error!void {
        if (sink.writer) |writer| try writer.bytes(octets);
        sink.len += octets.len;
    }

    fn value(sink: *Sink, comptime kind: Kind, comptime V: type, item: V) Error!void {
        if (sink.writer) |writer| try scalar.write(kind, V, item, writer);
        sink.len += scalar.len(kind, V, item);
    }
};

/// The bytes `encode` writes for `message`.
pub fn encoded_len(comptime T: type, message: *const T) Error!usize {
    var sink: Sink = .{ .writer = null };
    try encode_message(T, message, &sink);
    return sink.len;
}

/// Encodes `message` at the end of `writer`'s bytes.
pub fn encode_into(comptime T: type, message: *const T, writer: *wire.Writer) Error!void {
    const start = writer.len;
    var sink: Sink = .{ .writer = writer };
    try encode_message(T, message, &sink);
    assert(writer.len - start == sink.len);
}

fn encode_message(comptime T: type, message: *const T, sink: *Sink) Error!void {
    comptime descriptor.check(T);
    if (comptime T.protobuf.map_entry) return encode_entry(T, message, sink);
    inline for (T.protobuf.fields) |field| {
        if (field.oneof) |oneof| {
            try encode_member(T, field, oneof, message, sink);
        } else {
            try encode_field(field, @field(message, field.name), sink);
        }
    }
    if (comptime descriptor.keeps_unknown(T)) try encode_unknown(T, @field(message, descriptor.unknown_field).bytes, sink);
}

/// Writes the unknown fields a message kept, as they came, after its known fields. The span may
/// hold known records between unknown ones; those were written above, from the struct.
fn encode_unknown(comptime T: type, bytes: []const u8, sink: *Sink) Error!void {
    var reader: wire.Reader = .{ .bytes = bytes };
    // Each record takes at least one byte.
    for (0..bytes.len + 1) |_| {
        if (reader.at_end()) return;
        const start = reader.position;
        const tag = try reader.tag();
        try reader.skip(tag, constants.limits.depth_max);
        const record = bytes[start..reader.position];
        if (!descriptor.knows(T, tag.number) or try closed_value_unknown(T, record)) try sink.raw(record);
    }
    unreachable;
}

/// Whether `record` holds a number its singular field's closed enum does not name. `decode` kept
/// it with the unknown fields and left the field as it was, so it goes back out from here. A
/// repeated field's records go out from its view, unknown numbers among them.
fn closed_value_unknown(comptime T: type, record: []const u8) Error!bool {
    var reader: wire.Reader = .{ .bytes = record };
    const tag = try reader.tag();
    if (tag.wire_type != .varint) return false;
    inline for (T.protobuf.fields) |field| {
        if (comptime field.kind != .@"enum") continue;
        const V = comptime singular_enum(T, field) orelse continue;
        if (tag.number == field.number) return decode.unknown_to_closed(.@"enum", V, try scalar.read(.@"enum", V, &reader));
    }
    return false;
}

/// The enum type of a singular or oneof enum field, or null for a repeated one.
fn singular_enum(comptime T: type, comptime field: Field) ?type {
    const F = if (field.oneof) |oneof| @FieldType(@typeInfo(@FieldType(T, oneof)).optional.child, field.name) else @FieldType(T, field.name);
    if (repeated.is_repeated(F)) return null;
    return switch (@typeInfo(F)) {
        .optional => |optional| optional.child,
        else => F,
    };
}

/// A map entry writes its key and its value even at their defaults, as Go and C++ write them, so
/// the bytes match theirs ("Maps": an entry is a message of key 1 and value 2).
fn encode_entry(comptime T: type, entry: *const T, sink: *Sink) Error!void {
    inline for (T.protobuf.fields) |field| {
        const item = @field(entry, field.name);
        const F = @TypeOf(item);
        if (comptime repeated.is_lazy(F)) {
            const child = try item.get() orelse F.Message{};
            try encode_child(F.Message, field.kind, field.number, &child, sink);
        } else switch (@typeInfo(F)) {
            .optional => |optional| try encode_present(field, optional.child, item orelse .{}, sink),
            else => try encode_present(field, F, item, sink),
        }
    }
}

fn encode_field(comptime field: Field, item: anytype, sink: *Sink) Error!void {
    const F = @TypeOf(item);
    if (comptime repeated.is_repeated(F)) return encode_repeated(field, F, &item, sink);
    if (comptime repeated.is_lazy(F)) {
        const child = try item.get() orelse return;
        return encode_child(F.Message, field.kind, field.number, &child, sink);
    }
    switch (@typeInfo(F)) {
        .optional => |optional| {
            const set = item orelse return;
            try encode_present(field, optional.child, set, sink);
        },
        else => {
            if (scalar.is_default(F, item)) return;
            try encode_present(field, F, item, sink);
        },
    }
}

/// Writes a field that is set, whatever its value.
fn encode_present(comptime field: Field, comptime V: type, item: V, sink: *Sink) Error!void {
    if (comptime field.kind.holds_message()) return encode_child(V, field.kind, field.number, &item, sink);
    try sink.tag(field.number, field.kind.wire_type());
    try sink.value(field.kind, V, item);
}

fn encode_member(comptime T: type, comptime field: Field, comptime oneof: []const u8, message: *const T, sink: *Sink) Error!void {
    const U = @typeInfo(@FieldType(T, oneof)).optional.child;
    const active = @field(message, oneof) orelse return;
    if (active != @field(std.meta.Tag(U), field.name)) return;
    const V = @FieldType(U, field.name);
    const item = @field(active, field.name);
    if (comptime repeated.is_lazy(V)) {
        const child = try item.get() orelse return;
        return encode_child(V.Message, field.kind, field.number, &child, sink);
    }
    try encode_present(field, V, item, sink);
}

fn encode_child(comptime M: type, comptime kind: Kind, number: u32, child: *const M, sink: *Sink) Error!void {
    if (comptime kind == .group) {
        // "Groups": the fields sit between a start and an end tag, with no length before them.
        try sink.tag(number, .start_group);
        try encode_message(M, child, sink);
        return sink.tag(number, .end_group);
    }
    const writer = sink.writer orelse {
        // A counting sink needs the child's length alone, which one walk gives.
        const child_len = try encoded_len(M, child);
        try sink.tag(number, .len);
        try sink.varint(child_len);
        sink.len += child_len;
        return;
    };
    try sink.tag(number, .len);
    if (sink.measured) return write_child_measured(M, child, sink);
    const tag_end = writer.len;
    const tag_sink_len = sink.len;
    write_child_once(M, child, sink, writer) catch |failure| switch (failure) {
        // The placeholder took up to four octets more than the length will. In a buffer sized
        // to the message, measure first, then write.
        error.NoSpaceLeft => {
            writer.len = tag_end;
            sink.len = tag_sink_len;
            sink.measured = true;
            try write_child_measured(M, child, sink);
        },
        else => |other| return other,
    };
}

fn write_child_measured(comptime M: type, child: *const M, sink: *Sink) Error!void {
    try sink.varint(try encoded_len(M, child));
    try encode_message(M, child, sink);
}

/// Writes a child once, behind a placeholder for its length, then writes the length and moves the
/// child up to meet it. Measuring the child first would walk its subtree at every level of
/// nesting, and a deep message would cost its depth times its size.
fn write_child_once(comptime M: type, child: *const M, sink: *Sink, writer: *wire.Writer) Error!void {
    const at = try writer.padded_varint();
    const start = writer.len;
    const sink_start = sink.len;
    try encode_message(M, child, sink);
    const child_len = writer.len - start;
    assert(sink.len - sink_start == child_len);
    const prefix_len = wire.varint_len(child_len);
    @memmove(writer.buffer[at + prefix_len ..][0..child_len], writer.buffer[start..writer.len]);
    writer.len = at;
    try writer.varint(child_len);
    writer.len += child_len;
    sink.len += prefix_len;
}

fn encode_repeated(comptime field: Field, comptime F: type, item: *const F, sink: *Sink) Error!void {
    if (item.is_empty()) return;
    if (comptime F.kind.packable() and field.@"packed") {
        try encode_packed(field, F, item, sink);
    } else {
        try encode_each(field, F, item, sink);
    }
    if (comptime repeated.holds_closed(F)) try encode_closed_unknown(field, F, item.view, sink);
}

/// Writes back what a decoded closed-enum field kept out of its elements: each number the enum
/// does not name, as a record of its own, and each map entry that holds one, whole. Go's and
/// upb's runtimes keep them with the unknown fields in the same form (editions, "enum_type").
fn encode_closed_unknown(comptime field: Field, comptime F: type, view: descriptor.View, sink: *Sink) Error!void {
    var reader: wire.Reader = .{ .bytes = view.bytes };
    // Each record takes at least one byte.
    for (0..view.bytes.len + 1) |_| {
        if (reader.at_end()) return;
        const start = reader.position;
        const tag = try reader.tag();
        if (tag.number != view.number) {
            try reader.skip(tag, constants.limits.depth_max);
            continue;
        }
        if (comptime F.kind == .@"enum") {
            try encode_unknown_numbers(field, F.Element, tag, &reader, sink);
        } else {
            const payload = try decode.message_payload(F.kind, tag, &reader, constants.limits.depth_max);
            if (try repeated.entry_value_unknown(F.Element, payload)) try sink.raw(view.bytes[start..reader.position]);
        }
    }
    unreachable;
}

/// Writes each number of one record, packed or not, that the closed enum `V` does not name.
fn encode_unknown_numbers(comptime field: Field, comptime V: type, tag: wire.Tag, reader: *wire.Reader, sink: *Sink) Error!void {
    var values: wire.Reader = if (tag.wire_type == .len) .{ .bytes = try reader.length_delimited() } else reader.*;
    // Each number takes at least one byte; an unpacked record holds one.
    for (0..values.bytes.len + 1) |_| {
        const value = try scalar.read(.@"enum", V, &values);
        if (decode.unknown_to_closed(.@"enum", V, value)) {
            try sink.tag(field.number, .varint);
            try sink.value(.@"enum", V, value);
        }
        if (tag.wire_type != .len) {
            reader.* = values;
            return;
        }
        if (values.at_end()) return;
    }
    unreachable;
}

fn encode_each(comptime field: Field, comptime F: type, item: *const F, sink: *Sink) Error!void {
    // A program's items are a slice: one loop over it, without an iterator call per element.
    if (item.items.len != 0) return encode_each_item(field, F, item.items, sink);
    var elements = item.iterator();
    for (0..constants.limits.elements_max) |_| {
        const element = try elements.next() orelse return;
        if (comptime F.kind.holds_message()) {
            try encode_child(F.Element, F.kind, field.number, &element, sink);
        } else {
            try sink.tag(field.number, F.kind.wire_type());
            try sink.value(F.kind, F.Element, element);
        }
    }
    unreachable;
}

fn encode_each_item(comptime field: Field, comptime F: type, items: []const F.Element, sink: *Sink) Error!void {
    for (items) |*element| {
        if (comptime F.kind.holds_message()) {
            try encode_child(F.Element, F.kind, field.number, element, sink);
        } else {
            try sink.tag(field.number, F.kind.wire_type());
            try sink.value(F.kind, F.Element, element.*);
        }
    }
}

fn encode_packed(comptime field: Field, comptime F: type, item: *const F, sink: *Sink) Error!void {
    if (item.items.len != 0) return encode_packed_items(field, F, item.items, sink);
    var payload_len: usize = 0;
    var counting = item.iterator();
    for (0..constants.limits.elements_max) |_| {
        const element = try counting.next() orelse break;
        payload_len += scalar.len(F.kind, F.Element, element);
    }
    if (payload_len == 0) return;
    try sink.tag(field.number, .len);
    try sink.varint(payload_len);
    if (sink.writer == null) {
        sink.len += payload_len;
        return;
    }
    var elements = item.iterator();
    for (0..constants.limits.elements_max) |_| {
        const element = try elements.next() orelse return;
        try sink.value(F.kind, F.Element, element);
    }
    unreachable;
}

/// A program's items, packed ("Packed Repeated Fields"): their length in one loop, then their
/// values in another, each straight from the slice.
fn encode_packed_items(comptime field: Field, comptime F: type, items: []const F.Element, sink: *Sink) Error!void {
    var payload_len: usize = 0;
    for (items) |element| payload_len += scalar.len(F.kind, F.Element, element);
    // Each element takes an octet at least, so a set field writes a record.
    assert(payload_len >= items.len);
    try sink.tag(field.number, .len);
    try sink.varint(payload_len);
    const writer = sink.writer orelse {
        sink.len += payload_len;
        return;
    };
    const start = writer.len;
    for (items) |element| try scalar.write(F.kind, F.Element, element, writer);
    assert(writer.len - start == payload_len);
    sink.len += payload_len;
}
