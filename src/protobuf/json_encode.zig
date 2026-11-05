//! Writes a message in proto3 JSON through stdx's `json.TextWriter` (proto3 JSON mapping).
//!
//! Members are named by `json_name`. A field that the binary encoding leaves off at its default is
//! left off here too ("JSON Mapping": "fields with default values are omitted"). A repeated field
//! is an array, a map an object, and a well-known type takes its own form.
const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const descriptor = @import("descriptor.zig");
const scalar = @import("scalar.zig");
const repeated = @import("repeated.zig");
const json_scalar = @import("json_scalar.zig");
const wkt = @import("wkt.zig");
const time_text = @import("time_text.zig");
const constants = @import("constants.zig");
const Field = descriptor.Field;

pub const Error = json_scalar.EncodeError;

/// The longest Timestamp or Duration text, which `time_text` pins: under one cache line.
const time_text_len = 32;

comptime {
    std.debug.assert(time_text_len == time_text.text_len_max);
}

pub fn write_message(comptime T: type, message: *const T, text: *json.TextWriter) Error!void {
    comptime descriptor.check(T);
    switch (comptime wkt.form(T)) {
        .message => {},
        .timestamp => return write_time(message.*, time_text.format_timestamp, text),
        .duration => return write_time(message.*, time_text.format_duration, text),
        .field_mask => return write_field_mask(message, text),
        .wrapper => return write_value(T.protobuf.fields[0], @FieldType(T, "value"), message.value, text),
        .unsupported => return error.Unsupported,
    }
    try text.begin_object();
    inline for (T.protobuf.fields) |field| {
        if (field.oneof) |oneof| {
            try write_member(T, field, oneof, message, text);
        } else {
            try write_field(field, @field(message, field.name), text);
        }
    }
    try text.end_object();
}

fn write_time(message: anytype, comptime format: anytype, text: *json.TextWriter) Error!void {
    var buffer: [time_text_len]u8 = undefined;
    const written = format(.{ .seconds = message.seconds, .nanos = message.nanos }, &buffer) catch |failure| switch (failure) {
        error.NoSpaceLeft => unreachable,
        else => |refusal| return refusal,
    };
    try text.string(written);
}

/// "JSON Mapping", FieldMask: the paths in lowerCamelCase, joined by commas, as one string.
fn write_field_mask(message: *const wkt.FieldMask, text: *json.TextWriter) Error!void {
    var paths = message.paths.iterator();
    var first = true;
    for (0..constants.limits.elements_max) |_| {
        const path = try paths.next() orelse break;
        if (!first) try text.write(.{ .string = .more }, ",");
        first = false;
        try write_camel_path(path, text);
    }
    try text.write(.{ .string = .last }, "");
}

fn write_camel_path(path: []const u8, text: *json.TextWriter) Error!void {
    var upper_next = false;
    for (path) |octet| {
        // A path is lowercase snake case, so a camel round trip is exact.
        if (octet >= 'A' and octet <= 'Z') return error.InvalidFieldMask;
        if (octet == '_') {
            if (upper_next) return error.InvalidFieldMask;
            upper_next = true;
            continue;
        }
        const out = if (upper_next) std.ascii.toUpper(octet) else octet;
        upper_next = false;
        try text.write(.{ .string = .more }, &.{out});
    }
    if (upper_next) return error.InvalidFieldMask;
}

fn write_field(comptime field: Field, item: anytype, text: *json.TextWriter) Error!void {
    const F = @TypeOf(item);
    if (comptime repeated.is_repeated(F)) {
        if (item.is_empty()) return;
        try text.name(field.json_name);
        return if (comptime F.kind == .message and F.Element.protobuf.map_entry)
            write_map(F, &item, text)
        else
            write_array(field, F, &item, text);
    }
    if (comptime repeated.is_lazy(F)) {
        const child = try item.get() orelse return;
        try text.name(field.json_name);
        return write_message(F.Message, &child, text);
    }
    switch (@typeInfo(F)) {
        .optional => |optional| {
            const set = item orelse return;
            try text.name(field.json_name);
            try write_value(field, optional.child, set, text);
        },
        else => {
            if (scalar.is_default(F, item)) return;
            try text.name(field.json_name);
            try write_value(field, F, item, text);
        },
    }
}

fn write_value(comptime field: Field, comptime V: type, item: V, text: *json.TextWriter) Error!void {
    if (comptime field.kind == .message) return write_message(V, &item, text);
    try json_scalar.write(field.kind, V, item, text);
}

fn write_member(comptime T: type, comptime field: Field, comptime oneof: []const u8, message: *const T, text: *json.TextWriter) Error!void {
    const U = @typeInfo(@FieldType(T, oneof)).optional.child;
    const active = @field(message, oneof) orelse return;
    if (active != @field(std.meta.Tag(U), field.name)) return;
    const V = @FieldType(U, field.name);
    const item = @field(active, field.name);
    try text.name(field.json_name);
    if (comptime repeated.is_lazy(V)) {
        const child = (try item.get()).?;
        return write_message(V.Message, &child, text);
    }
    try write_value(field, V, item, text);
}

fn write_array(comptime field: Field, comptime F: type, item: *const F, text: *json.TextWriter) Error!void {
    try text.begin_array();
    var elements = item.iterator();
    for (0..constants.limits.elements_max) |_| {
        const element = try elements.next() orelse break;
        try write_value(field, F.Element, element, text);
    }
    try text.end_array();
}

fn write_map(comptime F: type, item: *const F, text: *json.TextWriter) Error!void {
    const Entry = F.Element;
    const key_field = Entry.protobuf.fields[0];
    const value_field = Entry.protobuf.fields[1];
    comptime assert(key_field.number == 1 and value_field.number == 2);
    try text.begin_object();
    var entries = item.iterator();
    for (0..constants.limits.elements_max) |_| {
        const entry = try entries.next() orelse break;
        try json_scalar.write_key(key_field.kind, @FieldType(Entry, "key"), entry.key, text);
        const V = @FieldType(Entry, "value");
        switch (@typeInfo(V)) {
            .optional => |optional| try write_value(value_field, optional.child, entry.value orelse .{}, text),
            else => try write_value(value_field, V, entry.value, text),
        }
    }
    try text.end_object();
}
