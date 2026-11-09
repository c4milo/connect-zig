//! The proof harness of the fast paths that act on whole messages (pepegrillo's performance
//! method, step 5), beside protobuf_fast_path_test.zig's harness of single values:
//!
//! - A nested message encodes as a reference encoder writes it, at each child length from 0 to
//!   16 octets and on each side of the lengths whose prefix takes 2 and 3 octets, in every room
//!   from too small to past its length.
//! - A packed field yields the elements a reference wrote, at each count from 0, packed, split
//!   and mixed with unpacked records, for each varint kind and for an open and a closed enum.
//! - A JSON member names a field by its exact JSON or .proto name alone, at each name length.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");
const harness = @import("protobuf_fast_path_test.zig");
const constants = @import("constants.zig");
const Repeated = proto.Repeated;
const Lazy = proto.Lazy;

const varint_len_max = constants.protocol.varint_len_max;
const wire_type_bits = constants.protocol.wire_type_bits;
/// The wire types the reference writes ("Message Structure").
const wire_type_varint = 0;
const wire_type_len = 2;

/// A message that holds bytes, one child and a list of children, as `protoc-gen-connect-zig`
/// writes a recursive message.
const Wrap = struct {
    payload: []const u8 = "",
    child: Lazy(Wrap) = .{},
    children: Repeated(Wrap, .message) = .{},
    pub const FieldNumber = enum(u29) { payload = 1, child = 2, children = 3 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Wrap", .fields = &.{
        proto.field_of(FieldNumber.payload, .bytes, .{}),
        proto.field_of(FieldNumber.child, .message, .{}),
        proto.field_of(FieldNumber.children, .message, .{}),
    } };
};

/// The longest payload the sweeps write: 2^14 + 2, past the lengths whose prefix takes 3 octets.
const payload_len_max = 16_386;
/// Room for the tags and prefixes around a payload, at every level a sweep nests it in.
const prefixes_len_max = 64;
/// The most copies of the payload one message of a sweep holds.
const payload_copies_max = 4;
/// Room for the largest message of a sweep.
const encoded_len_max = payload_copies_max * (payload_len_max + prefixes_len_max);
/// The field number of the packed field, and of the field its records skip over.
const packed_number = 1;
const skipped_number = 2;
/// How far below and above its length a sweep gives an encoding room.
const room_margin = 8;

/// Writes octets one at a time, with varints from the reference, into a buffer it never outgrows.
const Out = struct {
    buffer: []u8,
    len: usize = 0,

    fn varint(out: *Out, value: u64) void {
        var groups: [varint_len_max]u8 = @splat(0);
        const len = harness.reference_write(value, &groups);
        out.octets(groups[0..len]);
    }

    fn octets(out: *Out, bytes: []const u8) void {
        @memcpy(out.buffer[out.len..][0..bytes.len], bytes);
        out.len += bytes.len;
    }

    fn record(out: *Out, number: u32, body: []const u8) void {
        out.varint(@as(u64, number) << wire_type_bits | wire_type_len);
        out.varint(body.len);
        out.octets(body);
    }
};

/// The encoding of `message`, written field by field in number order, each child after the
/// length `reference_len` measures ("Length-Delimited Records").
fn reference_encode(message: *const Wrap, out: *Out) void {
    if (message.payload.len != 0) out.record(@intFromEnum(Wrap.FieldNumber.payload), message.payload);
    if (message.child.value) |child| reference_child(@intFromEnum(Wrap.FieldNumber.child), child, out);
    for (message.children.items) |*child| reference_child(@intFromEnum(Wrap.FieldNumber.children), child, out);
}

fn reference_child(number: u32, child: *const Wrap, out: *Out) void {
    out.varint(@as(u64, number) << wire_type_bits | wire_type_len);
    out.varint(reference_len(child));
    const start = out.len;
    reference_encode(child, out);
    std.debug.assert(out.len - start == reference_len(child));
}

/// The octets of `message`'s encoding: each record's tag, its length's varint and its body.
fn reference_len(message: *const Wrap) usize {
    var len: usize = 0;
    if (message.payload.len != 0) len += record_len(@intFromEnum(Wrap.FieldNumber.payload), message.payload.len);
    if (message.child.value) |child| len += record_len(@intFromEnum(Wrap.FieldNumber.child), reference_len(child));
    for (message.children.items) |*child| len += record_len(@intFromEnum(Wrap.FieldNumber.children), reference_len(child));
    return len;
}

fn record_len(number: u32, body_len: usize) usize {
    var groups: [varint_len_max]u8 = @splat(0);
    const tag_len = harness.reference_write(@as(u64, number) << wire_type_bits | wire_type_len, &groups);
    return tag_len + harness.reference_write(body_len, &groups) + body_len;
}

/// Encodes `message` in every room from `room_margin` below its length to as far above it, and
/// requires the reference's octets, or `error.NoSpaceLeft` where they do not fit.
fn check_encode(message: *const Wrap) !void {
    var want_storage: [encoded_len_max]u8 = @splat(0);
    var want: Out = .{ .buffer = &want_storage };
    reference_encode(message, &want);
    try testing.expectEqual(want.len, try proto.encoded_len(Wrap, message));
    var got: [encoded_len_max]u8 = @splat(0);
    for (want.len -| room_margin..want.len + room_margin + 1) |room| {
        const result = proto.encode(Wrap, message, got[0..room]);
        if (room < want.len) {
            try testing.expectError(error.NoSpaceLeft, result);
        } else {
            try testing.expectEqualSlices(u8, want_storage[0..want.len], try result);
        }
    }
}

test "a nested message encodes as the reference, at each child length and in every room" {
    // Each length from 0 to 16, and those on each side of the lengths whose prefix takes 2 and 3
    // octets.
    const payload_lens = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 124, 125, 126, 127, 128, 129, 130, 16_380, 16_381, 16_382, 16_383, 16_384, 16_385, 16_386 };
    var payload: [payload_len_max]u8 = @splat('x');
    for (payload_lens) |len| {
        const inner: Wrap = .{ .payload = payload[0..len] };
        try check_encode(&.{ .child = .of(&inner) });
        const middle: Wrap = .{ .child = .of(&inner) };
        try check_encode(&.{ .payload = "ab", .child = .of(&middle) });
        const pair = [_]Wrap{ inner, .{ .payload = "c" } };
        try check_encode(&.{ .children = .of(&pair) });
        const parents = [_]Wrap{ .{ .children = .of(&pair) }, middle };
        try check_encode(&.{ .children = .of(&parents), .child = .of(&middle) });
    }
}

test "a chain of children encodes as the reference, at each depth and in every room" {
    var chain: [constants.limits.depth_max / 4]Wrap = @splat(.{});
    var payload: [16]u8 = @splat('y');
    for (0..payload.len + 1) |len| {
        chain[chain.len - 1] = .{ .payload = payload[0..len] };
        for (0..chain.len - 1) |level| chain[level] = .{ .child = .of(&chain[level + 1]) };
        for (&chain) |*top| try check_encode(top);
    }
}

/// A closed enum: a number it does not name stays with the unknown fields, and an iterator over
/// its packed field passes over it (editions, "enum_type").
const Size = enum(i32) {
    unspecified = 0,
    small = 1,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "test.Size", .closed = true, .values = &.{
        .{ .name = "SIZE_UNSPECIFIED", .number = @intFromEnum(@This().unspecified) },
        .{ .name = "SMALL", .number = @intFromEnum(@This().small) },
    } };
};

/// The same numbers, open.
const OpenSize = enum(i32) {
    unspecified = 0,
    small = 1,
    _,
    pub const protobuf: proto.EnumDescriptor = .{ .full_name = "test.OpenSize", .values = &.{
        .{ .name = "SIZE_UNSPECIFIED", .number = @intFromEnum(@This().unspecified) },
        .{ .name = "SMALL", .number = @intFromEnum(@This().small) },
    } };
};

/// The varint a value of `kind` takes on the wire, computed apart from the runtime: int32 and
/// enums sign-extended, sint32 zigzagged ("Base 128 Varints", "Signed Integers").
fn wire_value(comptime kind: proto.Kind, value: anytype) u64 {
    return switch (kind) {
        .int32 => @bitCast(@as(i64, value)),
        .sint32 => @as(u32, @bitCast((value << 1) ^ (value >> (@bitSizeOf(i32) - 1)))),
        .uint64 => value,
        .bool => @intFromBool(value),
        .@"enum" => @bitCast(@as(i64, @intFromEnum(value))),
        else => unreachable,
    };
}

/// The field's records: the first `split` values packed, one unpacked, an unrelated field, and
/// the rest packed. A split at either end leaves an empty packed record there.
fn write_records(comptime kind: proto.Kind, values: anytype, split: usize, out: *Out) void {
    var storage: [encoded_len_max]u8 = @splat(0);
    var body: Out = .{ .buffer = &storage };
    for (values[0..split]) |value| body.varint(wire_value(kind, value));
    out.record(packed_number, storage[0..body.len]);
    if (split < values.len) {
        out.varint(packed_number << wire_type_bits | wire_type_varint);
        out.varint(wire_value(kind, values[split]));
    }
    out.record(skipped_number, "skipped");
    body.len = 0;
    for (values[@min(split + 1, values.len)..]) |value| body.varint(wire_value(kind, value));
    out.record(packed_number, storage[0..body.len]);
}

/// Each count of `values` from none, at each split: the iterator yields them in order, each a
/// closed enum names, and then null.
fn check_packed(comptime T: type, comptime kind: proto.Kind, values: []const T) !void {
    for (0..values.len + 1) |count| {
        for (0..count + 1) |split| try check_packed_split(T, kind, values[0..count], split);
    }
}

fn check_packed_split(comptime T: type, comptime kind: proto.Kind, values: []const T, split: usize) !void {
    var storage: [encoded_len_max]u8 = @splat(0);
    var out: Out = .{ .buffer = &storage };
    write_records(kind, values, split, &out);
    const field: Repeated(T, kind) = .{ .view = .{ .bytes = storage[0..out.len], .number = packed_number } };
    var elements = field.iterator();
    for (values) |want| {
        if (comptime kind == .@"enum" and T.protobuf.closed) {
            if (T.protobuf.name_of(@intFromEnum(want)) == null) continue;
        }
        try testing.expectEqual(want, (try elements.next()).?);
    }
    try testing.expectEqual(@as(?T, null), try elements.next());
}

test "a packed field yields the elements the reference wrote, for each varint kind" {
    var wide: [harness.boundary_values_count]u64 = @splat(0);
    harness.boundary_values(&wide);
    try check_packed(u64, .uint64, &wide);
    const narrow = [_]i32{ 0, 1, -1, 127, 128, -128, 300, std.math.maxInt(i32), std.math.minInt(i32), 16_384 };
    try check_packed(i32, .int32, &narrow);
    try check_packed(i32, .sint32, &narrow);
    try check_packed(bool, .bool, &.{ true, false, true });
    const sizes = [_]i32{ 0, 1, 7, -1, 1, 300, 0 };
    var closed: [sizes.len]Size = undefined;
    var open: [sizes.len]OpenSize = undefined;
    for (sizes, &closed, &open) |size, *closed_size, *open_size| {
        closed_size.* = @enumFromInt(size);
        open_size.* = @enumFromInt(size);
    }
    try check_packed(Size, .@"enum", &closed);
    try check_packed(OpenSize, .@"enum", &open);
}

test "a packed record whose last varint runs past its end is refused after the elements before" {
    // Field 1 packed: 1, then a varint whose continuation bit the record's end cuts.
    const field: Repeated(u64, .uint64) = .{ .view = .{ .bytes = &.{ 0x0a, 0x02, 0x01, 0x80 }, .number = 1 } };
    var elements = field.iterator();
    try testing.expectEqual(@as(u64, 1), (try elements.next()).?);
    try testing.expectError(error.Truncated, elements.next());
}

/// Fields whose .proto names take 1, 7, 16, 17 and 27 octets, and whose JSON names differ.
const Names = struct {
    a: i32 = 0,
    seven_x: i32 = 0,
    field_sixteen_ab: i32 = 0,
    field_seventeen_x: i32 = 0,
    a_very_long_field_name_past: i32 = 0,
    pub const FieldNumber = enum(u29) { a = 1, seven_x = 2, field_sixteen_ab = 3, field_seventeen_x = 4, a_very_long_field_name_past = 5 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Names", .fields = &.{
        proto.field_of(FieldNumber.a, .int32, .{}),
        proto.field_of(FieldNumber.seven_x, .int32, .{ .json_name = "sevenX" }),
        proto.field_of(FieldNumber.field_sixteen_ab, .int32, .{ .json_name = "fieldSixteenAb" }),
        proto.field_of(FieldNumber.field_seventeen_x, .int32, .{ .json_name = "fieldSeventeenX" }),
        proto.field_of(FieldNumber.a_very_long_field_name_past, .int32, .{ .json_name = "aVeryLongFieldNamePast" }),
    } };
};

const name_text_len_max = 64;
/// The value each decoded member holds.
const member_value = 7;

/// Decodes `{"<name>":<member_value>}`: the field it names holds `member_value`, or the member
/// names none.
fn decode_name(name: []const u8) !Names {
    var text: [name_text_len_max]u8 = @splat(0);
    const json_text = try std.fmt.bufPrint(&text, "{{\"{s}\":{d}}}", .{ name, member_value });
    var binary: [name_text_len_max]u8 = @splat(0);
    var tokens: [name_text_len_max]u8 = @splat(0);
    return proto.decode_json(Names, json_text, &binary, &tokens);
}

/// The name decodes into its field alone; with any octet changed, one cut or one added, it
/// names none ("JSON Mapping": a parser accepts the JSON name and the .proto name).
fn check_name(name: []const u8, comptime field: []const u8) !void {
    const decoded = try decode_name(name);
    try testing.expectEqual(@as(i32, member_value), @field(decoded, field));
    var changed: [name_text_len_max]u8 = @splat(0);
    for (0..name.len) |place| {
        @memcpy(changed[0..name.len], name);
        changed[place] = '#';
        try testing.expectError(error.UnknownField, decode_name(changed[0..name.len]));
    }
    try testing.expectError(error.UnknownField, decode_name(name[0 .. name.len - 1]));
    @memcpy(changed[0..name.len], name);
    changed[name.len] = 'z';
    try testing.expectError(error.UnknownField, decode_name(changed[0 .. name.len + 1]));
}

test "a JSON member names a field by its exact JSON or .proto name, at each name length" {
    inline for (Names.protobuf.fields) |field| {
        try check_name(field.json_name, field.name);
        try check_name(field.proto_name, field.name);
    }
}
