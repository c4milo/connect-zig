//! Reads the JSON forms of Struct, Value, ListValue and Any into their binary encoding, beside
//! `json_decode.zig`, which calls here from `message_body` ("JSON Mapping").
const std = @import("std");
const json = @import("json");
const wire = @import("wire.zig");
const scalar = @import("scalar.zig");
const json_scalar = @import("json_scalar.zig");
const json_decode = @import("json_decode.zig");
const wkt = @import("wkt.zig");
const any = @import("any.zig");
const Transcoder = json_decode.Transcoder;
const Error = json_decode.Error;

const ValueNumber = wkt.Value.FieldNumber;
const entry_key: u32 = @intFromEnum(wkt.Struct.FieldsEntry.FieldNumber.key);
const entry_value: u32 = @intFromEnum(wkt.Struct.FieldsEntry.FieldNumber.value);
const struct_fields: u32 = @intFromEnum(wkt.Struct.FieldNumber.fields);
const list_values: u32 = @intFromEnum(wkt.ListValue.FieldNumber.values);
const any_type_url: u32 = @intFromEnum(wkt.Any.FieldNumber.type_url);
const any_value: u32 = @intFromEnum(wkt.Any.FieldNumber.value);

/// Value: one JSON value of any kind, written as the member of `kind` it stands for.
pub fn value_body(transcoder: *Transcoder, first: json.TextReader.Item, depth_left: u32) Error!void {
    if (depth_left == 0) return error.DepthExceeded;
    const writer = &transcoder.writer;
    switch (first) {
        .null => {
            // A oneof member is written at its default, so the null kind stays set.
            try writer.tag(@intFromEnum(ValueNumber.null_value), .varint);
            try writer.varint(0);
        },
        .number => |octets| {
            try writer.tag(@intFromEnum(ValueNumber.number_value), .i64);
            try scalar.write(.double, f64, try json_scalar.parse_float(f64, octets, false), writer);
        },
        .string => |octets| {
            try writer.tag(@intFromEnum(ValueNumber.string_value), .len);
            try scalar.write(.string, []const u8, octets, writer);
        },
        .true, .false => {
            try writer.tag(@intFromEnum(ValueNumber.bool_value), .varint);
            try writer.varint(@intFromBool(first == .true));
        },
        .begin_object => try nested(@intFromEnum(ValueNumber.struct_value), struct_body, transcoder, first, depth_left - 1),
        .begin_array => try nested(@intFromEnum(ValueNumber.list_value), list_body, transcoder, first, depth_left - 1),
        else => return error.UnexpectedToken,
    }
}

/// Writes field `number` as a message whose body `body` writes, behind a length it patches.
fn nested(number: u32, comptime body: anytype, transcoder: *Transcoder, first: json.TextReader.Item, depth_left: u32) Error!void {
    try transcoder.writer.tag(number, .len);
    const at = try transcoder.writer.padded_varint();
    try body(transcoder, first, depth_left);
    json_decode.patch(&transcoder.writer, at);
}

/// Struct: an object, each member an entry of its `fields` map.
pub fn struct_body(transcoder: *Transcoder, first: json.TextReader.Item, depth_left: u32) Error!void {
    if (depth_left == 0) return error.DepthExceeded;
    if (first != .begin_object) return error.UnexpectedToken;
    const writer = &transcoder.writer;
    // Each member takes at least one token, and the text bounds the tokens.
    for (0..transcoder.reader.input.len + 1) |_| {
        const name = switch (try transcoder.next()) {
            .end_object => return,
            .name => |octets| octets,
            else => return error.UnexpectedToken,
        };
        try writer.tag(struct_fields, .len);
        const entry_at = try writer.padded_varint();
        // The name's octets live until the next read, so the key is written first.
        try writer.tag(entry_key, .len);
        try scalar.write(.string, []const u8, name, writer);
        try nested(entry_value, value_body, transcoder, try transcoder.next(), depth_left - 1);
        json_decode.patch(writer, entry_at);
    }
    unreachable;
}

/// ListValue: an array, each element one of its `values`.
pub fn list_body(transcoder: *Transcoder, first: json.TextReader.Item, depth_left: u32) Error!void {
    if (depth_left == 0) return error.DepthExceeded;
    if (first != .begin_array) return error.UnexpectedToken;
    for (0..transcoder.reader.input.len + 1) |_| {
        const element = try transcoder.next();
        if (element == .end_array) return;
        try nested(list_values, value_body, transcoder, element, depth_left - 1);
    }
    unreachable;
}

/// Any: an object of "@type" and the message's JSON. "@type" may stand after the members it
/// types, so a copy of the reader looks for it first; the members are read after it.
pub fn any_body(transcoder: *Transcoder, first: json.TextReader.Item, depth_left: u32, comptime registry: []const type) Error!void {
    if (first != .begin_object) return error.UnexpectedToken;
    var ahead = transcoder.reader;
    const index = try find_type(&ahead, &transcoder.writer, registry) orelse {
        // An Any with no "@type" is the empty Any, whose object holds nothing.
        if (try transcoder.next() != .end_object) return error.UnexpectedToken;
        return;
    };
    inline for (registry, 0..) |A, each| {
        if (each == index) return any_value_of(A, transcoder, depth_left, registry);
    }
    unreachable;
}

fn any_value_of(comptime A: type, transcoder: *Transcoder, depth_left: u32, comptime registry: []const type) Error!void {
    const writer = &transcoder.writer;
    try writer.tag(any_value, .len);
    const at = try writer.padded_varint();
    if (comptime any.nests_value(A) or A == wkt.Empty) {
        try value_member(A, transcoder, depth_left, registry);
    } else {
        try json_decode.members(A, transcoder, depth_left - 1, .with_type, registry);
    }
    json_decode.patch(writer, at);
}

/// Reads an Any's members for a well-known type: "@type", and the type's JSON under "value".
fn value_member(comptime A: type, transcoder: *Transcoder, depth_left: u32, comptime registry: []const type) Error!void {
    var seen = false;
    for (0..transcoder.reader.input.len + 1) |_| {
        const name = switch (try transcoder.next()) {
            // Empty may leave "value" out, as Go writes it.
            .end_object => return if (seen or A == wkt.Empty) {} else error.UnexpectedToken,
            .name => |octets| octets,
            else => return error.UnexpectedToken,
        };
        const is_type = std.mem.eql(u8, name, "@type");
        if (!is_type and !std.mem.eql(u8, name, "value")) return error.UnknownField;
        const member = try transcoder.next();
        if (is_type) continue;
        if (seen) return error.UnexpectedToken;
        seen = true;
        try json_decode.message_body(A, transcoder, member, depth_left - 1, registry);
    }
    unreachable;
}

/// Finds the "@type" member of the object `ahead` stands in, writes it as the Any's type URL,
/// and returns the index of its type in `registry`, or null when the object has none.
fn find_type(ahead: *json.TextReader, writer: *wire.Writer, comptime registry: []const type) Error!?usize {
    for (0..ahead.input.len + 1) |_| {
        const name = switch (try next_item(ahead)) {
            .end_object => return null,
            .name => |octets| octets,
            else => return error.UnexpectedToken,
        };
        if (!std.mem.eql(u8, name, "@type")) {
            try skip_value(ahead);
            continue;
        }
        const url = switch (try next_item(ahead)) {
            .string => |octets| octets,
            else => return error.UnexpectedToken,
        };
        // The URL's octets live until the next read, so it is written and matched now.
        try writer.tag(any_type_url, .len);
        try scalar.write(.string, []const u8, url, writer);
        const full_name = any.full_name_of(url);
        inline for (registry, 0..) |A, index| {
            if (std.mem.eql(u8, full_name, A.protobuf.full_name)) return index;
        }
        return error.UnknownAnyType;
    }
    unreachable;
}

fn next_item(reader: *json.TextReader) Error!json.TextReader.Item {
    return try reader.next() orelse error.UnexpectedToken;
}

/// Skips one value, nested or not. The reader already bounds the nesting.
fn skip_value(reader: *json.TextReader) Error!void {
    var depth: usize = 0;
    for (0..reader.input.len + 1) |_| {
        switch (try next_item(reader)) {
            .begin_object, .begin_array => depth += 1,
            .end_object, .end_array => depth -= 1,
            else => {},
        }
        if (depth == 0) return;
    }
    unreachable;
}
