//! Reads proto3 JSON by writing the binary encoding it stands for into a caller buffer, which
//! `decode` then reads (decision 9). Tokens come from stdx's `json.TextReader`, whose storage
//! holds each token's octets until the next call, so each value is written before the next read.
//!
//! A nested message's length is written as a 5-byte padded varint and patched at its end. A
//! parser accepts a varint longer than it needs ("Base 128 Varints"), so `decode` reads it.
const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const codec = @import("codec");
const wire = @import("wire.zig");
const descriptor = @import("descriptor.zig");
const scalar = @import("scalar.zig");
const repeated = @import("repeated.zig");
const json_scalar = @import("json_scalar.zig");
const wkt = @import("wkt.zig");
const time_text = @import("time_text.zig");
const constants = @import("constants.zig");
const Field = descriptor.Field;
const Kind = descriptor.Kind;

pub const Error = json_scalar.DecodeError;

const Transcoder = struct {
    reader: json.TextReader,
    writer: wire.Writer,

    fn next(transcoder: *Transcoder) Error!json.Item {
        const item = try transcoder.reader.next();
        return item orelse error.UnexpectedToken;
    }
};

/// Writes the binary encoding of the one JSON text `text` holds, read as a `T`, into `binary`,
/// with `tokens` as the reader's storage for one token's octets.
pub fn transcode(comptime T: type, text: []const u8, binary: []u8, tokens: []u8) Error![]const u8 {
    var transcoder: Transcoder = .{
        .reader = json.TextReader.init(text, tokens, .text, codec.Features.target()),
        .writer = .{ .buffer = binary },
    };
    if (!transcoder.reader.next_text()) return error.UnexpectedToken;
    const first = try transcoder.next();
    try message_body(T, &transcoder, first, constants.limits.json_depth_max);
    if (try transcoder.reader.next() != null) return error.UnexpectedToken;
    return transcoder.writer.written();
}

fn message_body(comptime T: type, transcoder: *Transcoder, first: json.Item, depth_left: u32) Error!void {
    comptime descriptor.check(T);
    if (depth_left == 0) return error.DepthExceeded;
    switch (comptime wkt.form(T)) {
        .message => {},
        .timestamp => return write_time(transcoder, first, time_text.parse_timestamp),
        .duration => return write_time(transcoder, first, time_text.parse_duration),
        .field_mask => return write_field_mask(transcoder, first),
        .wrapper => return write_single(T.protobuf.fields[0], @FieldType(T, "value"), transcoder, first, depth_left),
        .unsupported => return error.Unsupported,
    }
    // "JSON Mapping": a message is an object.
    if (first != .begin_object) return error.UnexpectedToken;
    // Each member takes at least one token, and the text bounds the tokens.
    for (0..transcoder.reader.input.len + 1) |_| {
        const member = try transcoder.next();
        switch (member) {
            .end_object => return,
            .name => |name| try read_member(T, transcoder, field_index(T, name) orelse return error.UnknownField, depth_left),
            else => return error.UnexpectedToken,
        }
    }
    unreachable;
}

/// The index of the field a member names by its JSON name or its .proto name ("JSON Mapping":
/// a parser accepts both).
fn field_index(comptime T: type, name: []const u8) ?usize {
    inline for (T.protobuf.fields, 0..) |field, index| {
        if (std.mem.eql(u8, name, field.json_name) or std.mem.eql(u8, name, field.proto_name)) return index;
    }
    return null;
}

fn read_member(comptime T: type, transcoder: *Transcoder, index: usize, depth_left: u32) Error!void {
    const value = try transcoder.next();
    inline for (T.protobuf.fields, 0..) |field, each| {
        if (each == index) return read_field(T, field, transcoder, value, depth_left);
    }
    unreachable;
}

fn read_field(comptime T: type, comptime field: Field, transcoder: *Transcoder, value: json.Item, depth_left: u32) Error!void {
    const F = if (field.oneof) |oneof| @FieldType(@typeInfo(@FieldType(T, oneof)).optional.child, field.name) else @FieldType(T, field.name);
    // "JSON Mapping": null is the default of every field, but NullValue's.
    if (value == .null and !comptime is_null_value(F)) return;
    if (comptime repeated.is_repeated(F)) {
        if (comptime F.kind == .message and F.Element.protobuf.map_entry) return read_map(field, F.Element, transcoder, value, depth_left);
        return read_array(field, F.Element, transcoder, value, depth_left);
    }
    const V = comptime value_type(F);
    try write_single(field, V, transcoder, value, depth_left);
}

fn value_type(comptime F: type) type {
    if (repeated.is_lazy(F)) return F.Message;
    return switch (@typeInfo(F)) {
        .optional => |optional| optional.child,
        else => F,
    };
}

fn is_null_value(comptime V: type) bool {
    const inner = if (repeated.is_repeated(V)) V.Element else value_type(V);
    if (!descriptor.is_enum(inner)) return false;
    return std.mem.eql(u8, inner.protobuf.full_name, "google.protobuf.NullValue");
}

fn read_array(comptime field: Field, comptime E: type, transcoder: *Transcoder, value: json.Item, depth_left: u32) Error!void {
    if (value != .begin_array) return error.UnexpectedToken;
    for (0..transcoder.reader.input.len + 1) |_| {
        const element = try transcoder.next();
        if (element == .end_array) return;
        // "JSON Mapping": null is not an element of a repeated field.
        if (element == .null and !comptime is_null_value(E)) return error.UnexpectedToken;
        try write_single(field, E, transcoder, element, depth_left);
    }
    unreachable;
}

fn read_map(comptime field: Field, comptime Entry: type, transcoder: *Transcoder, value: json.Item, depth_left: u32) Error!void {
    if (value != .begin_object) return error.UnexpectedToken;
    const key_field = Entry.protobuf.fields[0];
    const value_field = Entry.protobuf.fields[1];
    for (0..transcoder.reader.input.len + 1) |_| {
        const member = try transcoder.next();
        const key = switch (member) {
            .end_object => return,
            .name => |name| name,
            else => return error.UnexpectedToken,
        };
        try transcoder.writer.tag(field.number, .len);
        const at = try transcoder.writer.padded_varint();
        // The key's octets live until the next read, so the key is written first.
        try write_key(key_field, @FieldType(Entry, "key"), &transcoder.writer, key);
        const entry_value = try transcoder.next();
        if (entry_value == .null) return error.UnexpectedToken;
        try write_single(value_field, comptime value_type(@FieldType(Entry, "value")), transcoder, entry_value, depth_left);
        patch(&transcoder.writer, at);
    }
    unreachable;
}

fn patch(writer: *wire.Writer, at: usize) void {
    const body_len = writer.len - at - constants.limits.padded_length_len;
    writer.patch_padded(at, body_len);
}

fn write_key(comptime field: Field, comptime K: type, writer: *wire.Writer, key: []const u8) Error!void {
    try writer.tag(field.number, field.kind.wire_type());
    switch (field.kind) {
        .string => try scalar.write(.string, []const u8, key, writer),
        // "JSON Mapping": a bool key is the string "true" or "false".
        .bool => try scalar.write(.bool, bool, try parse_bool_key(key), writer),
        else => try scalar.write(field.kind, K, try json_scalar.parse_integer(K, key), writer),
    }
}

fn parse_bool_key(key: []const u8) Error!bool {
    if (std.mem.eql(u8, key, "true")) return true;
    if (std.mem.eql(u8, key, "false")) return false;
    return error.UnexpectedToken;
}

/// Writes one value of `field`, with its tag, from the token `value`.
fn write_single(comptime field: Field, comptime V: type, transcoder: *Transcoder, value: json.Item, depth_left: u32) Error!void {
    const writer = &transcoder.writer;
    if (comptime field.kind == .message) {
        try writer.tag(field.number, .len);
        const at = try writer.padded_varint();
        try message_body(V, transcoder, value, depth_left - 1);
        return patch(writer, at);
    }
    try writer.tag(field.number, field.kind.wire_type());
    switch (comptime field.kind) {
        .string => try scalar.write(.string, []const u8, try string_of(value), writer),
        .bytes => try json_scalar.write_base64_field(try string_of(value), writer),
        .bool => try scalar.write(.bool, bool, try bool_of(value), writer),
        .float, .double => try scalar.write(field.kind, V, try float_of(V, value), writer),
        .@"enum" => try scalar.write(.@"enum", V, try enum_of(V, value), writer),
        else => try scalar.write(field.kind, V, try integer_of(V, value), writer),
    }
}

fn string_of(value: json.Item) Error![]const u8 {
    return switch (value) {
        .string => |octets| octets,
        else => error.UnexpectedToken,
    };
}

fn bool_of(value: json.Item) Error!bool {
    return switch (value) {
        .true => true,
        .false => false,
        else => error.UnexpectedToken,
    };
}

fn integer_of(comptime V: type, value: json.Item) Error!V {
    return switch (value) {
        .number, .string => |octets| json_scalar.parse_integer(V, octets),
        else => error.UnexpectedToken,
    };
}

fn float_of(comptime V: type, value: json.Item) Error!V {
    return switch (value) {
        .number => |octets| json_scalar.parse_float(V, octets, false),
        .string => |octets| json_scalar.parse_float(V, octets, true),
        else => error.UnexpectedToken,
    };
}

fn enum_of(comptime V: type, value: json.Item) Error!V {
    return switch (value) {
        .string => |name| @enumFromInt(V.protobuf.number_of(name) orelse return error.InvalidEnum),
        .number => |octets| @enumFromInt(try json_scalar.parse_integer(i32, octets)),
        .null => @enumFromInt(0),
        else => error.UnexpectedToken,
    };
}

fn write_time(transcoder: *Transcoder, value: json.Item, comptime parse: anytype) Error!void {
    const instant = parse(try string_of(value)) catch |failure| switch (failure) {
        error.NoSpaceLeft => unreachable,
        else => |refusal| return refusal,
    };
    const writer = &transcoder.writer;
    if (instant.seconds != 0) {
        try writer.tag(@intFromEnum(wkt.Timestamp.FieldNumber.seconds), .varint);
        try scalar.write(.int64, i64, instant.seconds, writer);
    }
    if (instant.nanos != 0) {
        try writer.tag(@intFromEnum(wkt.Timestamp.FieldNumber.nanos), .varint);
        try scalar.write(.int32, i32, instant.nanos, writer);
    }
}

/// "JSON Mapping", FieldMask: lowerCamelCase paths joined by commas, each written in snake case.
fn write_field_mask(transcoder: *Transcoder, value: json.Item) Error!void {
    const joined = try string_of(value);
    if (joined.len == 0) return;
    var paths = std.mem.splitScalar(u8, joined, ',');
    for (0..joined.len + 1) |_| {
        const path = paths.next() orelse return;
        try write_snake_path(&transcoder.writer, path);
    }
    unreachable;
}

fn write_snake_path(writer: *wire.Writer, path: []const u8) Error!void {
    var len = path.len;
    for (path) |octet| {
        // A snake-case path holds no "_" once written in camel case.
        if (octet == '_') return error.InvalidFieldMask;
        if (std.ascii.isUpper(octet)) len += 1;
    }
    try writer.tag(1, .len);
    try writer.varint(len);
    for (path) |octet| {
        if (std.ascii.isUpper(octet)) {
            try writer.byte('_');
            try writer.byte(std.ascii.toLower(octet));
        } else try writer.byte(octet);
    }
}

const testing = std.testing;

const Chain = struct {
    next: repeated.Lazy(Chain) = .{},
    pub const FieldNumber = enum(u29) { next = 1 };
    pub const protobuf: descriptor.Descriptor = .{ .full_name = "test.Chain", .fields = &.{
        descriptor.field_of(FieldNumber.next, .message, .{}),
    } };
};

test "the transcoder itself refuses nesting past its bound, before decode reads it" {
    const deep = "{\"next\":" ** constants.limits.json_depth_max ++ "{}" ++ "}" ** constants.limits.json_depth_max;
    var binary: [4096]u8 = undefined;
    var tokens: [64]u8 = undefined;
    try testing.expectError(error.DepthExceeded, transcode(Chain, deep, &binary, &tokens));
    const fits = "{\"next\":" ** 3 ++ "{}" ++ "}" ** 3;
    const bytes = try transcode(Chain, fits, &binary, &tokens);
    try testing.expectEqual(@as(usize, 3 * (1 + constants.limits.padded_length_len)), bytes.len);
}
