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
    inline for (T.protobuf.fields) |field| {
        if (field.oneof) |oneof| {
            try encode_member(T, field, oneof, message, sink);
        } else {
            try encode_field(field, @field(message, field.name), sink);
        }
    }
}

fn encode_field(comptime field: Field, item: anytype, sink: *Sink) Error!void {
    const F = @TypeOf(item);
    if (comptime repeated.is_repeated(F)) return encode_repeated(field, F, &item, sink);
    if (comptime repeated.is_lazy(F)) {
        const child = try item.get() orelse return;
        return encode_child(F.Message, field.number, &child, sink);
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
    if (comptime field.kind == .message) return encode_child(V, field.number, &item, sink);
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
        return encode_child(V.Message, field.number, &child, sink);
    }
    try encode_present(field, V, item, sink);
}

fn encode_child(comptime M: type, number: u32, child: *const M, sink: *Sink) Error!void {
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
    std.mem.copyForwards(u8, writer.buffer[at + prefix_len ..][0..child_len], writer.buffer[start..writer.len]);
    writer.len = at;
    try writer.varint(child_len);
    writer.len += child_len;
    sink.len += prefix_len;
}

fn encode_repeated(comptime field: Field, comptime F: type, item: *const F, sink: *Sink) Error!void {
    if (item.is_empty()) return;
    if (comptime F.kind.packable() and field.@"packed") return encode_packed(field, F, item, sink);
    var elements = item.iterator();
    for (0..constants.limits.elements_max) |_| {
        const element = try elements.next() orelse return;
        if (comptime F.kind == .message) {
            try encode_child(F.Element, field.number, &element, sink);
        } else {
            try sink.tag(field.number, F.kind.wire_type());
            try sink.value(F.kind, F.Element, element);
        }
    }
    unreachable;
}

fn encode_packed(comptime field: Field, comptime F: type, item: *const F, sink: *Sink) Error!void {
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
