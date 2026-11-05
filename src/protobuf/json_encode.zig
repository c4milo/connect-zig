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
const decode = @import("decode.zig");
const any = @import("any.zig");
const constants = @import("constants.zig");
const Field = descriptor.Field;

pub const Error = json_scalar.EncodeError;

/// The longest Timestamp or Duration text, which `time_text` pins: under one cache line.
const time_text_len = 32;

comptime {
    std.debug.assert(time_text_len == time_text.text_len_max);
}

pub fn write_message(comptime T: type, message: *const T, text: *json.TextWriter, comptime registry: anytype) Error!void {
    comptime descriptor.check(T);
    switch (comptime wkt.form(T)) {
        .message => {},
        .timestamp => return write_time(message.*, time_text.format_timestamp, text),
        .duration => return write_time(message.*, time_text.format_duration, text),
        .field_mask => return write_field_mask(message, text),
        .wrapper => return write_value(T.protobuf.fields[0], @FieldType(T, "value"), message.value, text, registry),
        .struct_object => return write_struct(message, text, constants.limits.json_depth_max),
        .value => return write_json_value(message, text, constants.limits.json_depth_max),
        .list_value => return write_list(message, text, constants.limits.json_depth_max),
        .any => return write_any(message, text, registry),
    }
    try text.begin_object();
    try write_fields(T, message, text, registry);
    try text.end_object();
}

/// Writes a message's fields as members of an object already open.
fn write_fields(comptime T: type, message: *const T, text: *json.TextWriter, comptime registry: anytype) Error!void {
    inline for (T.protobuf.fields) |field| {
        if (field.oneof) |oneof| {
            try write_member(T, field, oneof, message, text, registry);
        } else {
            try write_field(field, @field(message, field.name), text, registry);
        }
    }
}

/// "JSON Mapping", Struct: an object of its fields' values. A depth bound stops a cycle a
/// program built from `Lazy.of` pointers.
fn write_struct(object: *const wkt.Struct, text: *json.TextWriter, depth_left: u32) Error!void {
    if (depth_left == 0) return error.DepthExceeded;
    try text.begin_object();
    var entries = object.fields.iterator();
    for (0..constants.limits.elements_max) |_| {
        const entry = try entries.next() orelse break;
        try text.name(entry.key);
        const value = try entry.value.get() orelse wkt.Value{ .kind = .{ .null_value = .null_value } };
        try write_json_value(&value, text, depth_left - 1);
    }
    try text.end_object();
}

/// "JSON Mapping", Value: the JSON value its kind holds.
fn write_json_value(value: *const wkt.Value, text: *json.TextWriter, depth_left: u32) Error!void {
    if (depth_left == 0) return error.DepthExceeded;
    const kind = value.kind orelse return error.InvalidValue;
    switch (kind) {
        .null_value => try text.null_literal(),
        .number_value => |number| {
            // JSON has no NaN or infinity, and Value spells numbers as JSON numbers.
            if (!std.math.isFinite(number)) return error.InvalidValue;
            try json_scalar.write(.double, f64, number, text);
        },
        .string_value => |string| try text.string(string),
        .bool_value => |flag| try text.boolean(flag),
        .struct_value => |lazy| try write_struct(&((try lazy.get()) orelse wkt.Struct{}), text, depth_left - 1),
        .list_value => |lazy| try write_list(&((try lazy.get()) orelse wkt.ListValue{}), text, depth_left - 1),
    }
}

/// "JSON Mapping", ListValue: an array of its values.
fn write_list(list: *const wkt.ListValue, text: *json.TextWriter, depth_left: u32) Error!void {
    if (depth_left == 0) return error.DepthExceeded;
    try text.begin_array();
    var values = list.values.iterator();
    for (0..constants.limits.elements_max) |_| {
        const value = try values.next() orelse break;
        try write_json_value(&value, text, depth_left - 1);
    }
    try text.end_array();
}

/// "JSON Mapping", Any: an object of "@type" and the message's JSON, under "value" for a
/// well-known type and beside "@type" otherwise. An empty Any is an empty object.
fn write_any(message: *const wkt.Any, text: *json.TextWriter, comptime registry: anytype) Error!void {
    if (message.type_url.len == 0 and message.value.len == 0) {
        try text.begin_object();
        return text.end_object();
    }
    const name = any.full_name_of(message.type_url);
    inline for (registry) |A| {
        if (std.mem.eql(u8, name, A.protobuf.full_name)) return write_any_as(A, message, text, registry);
    }
    return error.UnknownAnyType;
}

fn write_any_as(comptime A: type, message: *const wkt.Any, text: *json.TextWriter, comptime registry: anytype) Error!void {
    const inner = try decode.decode_depth(A, message.value, constants.limits.depth_max);
    try text.begin_object();
    try text.name("@type");
    try text.string(message.type_url);
    if (comptime any.nests_value(A)) {
        try text.name("value");
        try write_message(A, &inner, text, registry);
    } else {
        try write_fields(A, &inner, text, registry);
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

fn write_field(comptime field: Field, item: anytype, text: *json.TextWriter, comptime registry: anytype) Error!void {
    const F = @TypeOf(item);
    if (comptime repeated.is_repeated(F)) {
        if (item.is_empty()) return;
        try text.name(field.json_name);
        return if (comptime F.kind == .message and F.Element.protobuf.map_entry)
            write_map(F, &item, text, registry)
        else
            write_array(field, F, &item, text, registry);
    }
    if (comptime repeated.is_lazy(F)) {
        const child = try item.get() orelse return;
        try text.name(field.json_name);
        return write_message(F.Message, &child, text, registry);
    }
    switch (@typeInfo(F)) {
        .optional => |optional| {
            const set = item orelse return;
            try text.name(field.json_name);
            try write_value(field, optional.child, set, text, registry);
        },
        else => {
            if (scalar.is_default(F, item)) return;
            try text.name(field.json_name);
            try write_value(field, F, item, text, registry);
        },
    }
}

fn write_value(comptime field: Field, comptime V: type, item: V, text: *json.TextWriter, comptime registry: anytype) Error!void {
    if (comptime field.kind == .message) return write_message(V, &item, text, registry);
    try json_scalar.write(field.kind, V, item, text);
}

fn write_member(comptime T: type, comptime field: Field, comptime oneof: []const u8, message: *const T, text: *json.TextWriter, comptime registry: anytype) Error!void {
    const U = @typeInfo(@FieldType(T, oneof)).optional.child;
    const active = @field(message, oneof) orelse return;
    if (active != @field(std.meta.Tag(U), field.name)) return;
    const V = @FieldType(U, field.name);
    const item = @field(active, field.name);
    try text.name(field.json_name);
    if (comptime repeated.is_lazy(V)) {
        const child = (try item.get()).?;
        return write_message(V.Message, &child, text, registry);
    }
    try write_value(field, V, item, text, registry);
}

fn write_array(comptime field: Field, comptime F: type, item: *const F, text: *json.TextWriter, comptime registry: anytype) Error!void {
    try text.begin_array();
    var elements = item.iterator();
    for (0..constants.limits.elements_max) |_| {
        const element = try elements.next() orelse break;
        try write_value(field, F.Element, element, text, registry);
    }
    try text.end_array();
}

fn write_map(comptime F: type, item: *const F, text: *json.TextWriter, comptime registry: anytype) Error!void {
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
            .optional => |optional| try write_value(value_field, optional.child, entry.value orelse .{}, text, registry),
            else => try write_value(value_field, V, entry.value, text, registry),
        }
    }
    try text.end_object();
}
