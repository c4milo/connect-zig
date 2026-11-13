//! The proof harness of the flat child (pepegrillo's performance method, step 5): `encode`
//! measures a child that holds no message and no repeated field before it writes it, where any
//! other child is written behind a guessed length and moved. A flat child encodes as a reference
//! encoder writes it, at each payload length from 0 to 16 octets and on each side of the lengths
//! whose prefix takes 2 and 3 octets, alone and in a list, in every room from too small to past
//! its length.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf.zig");
const harness = @import("protobuf_fast_path_test.zig");
const constants = @import("constants.zig");

const varint_len_max = constants.protocol.varint_len_max;
const wire_type_bits = constants.protocol.wire_type_bits;
/// The wire types the reference writes ("Message Structure").
const wire_type_varint = 0;
const wire_type_len = 2;

/// A flat message: bytes and a number.
const Leaf = struct {
    payload: []const u8 = "",
    count: u32 = 0,
    pub const FieldNumber = enum(u29) { payload = 1, count = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Leaf", .fields = &.{
        proto.field_of(FieldNumber.payload, .bytes, .{}),
        proto.field_of(FieldNumber.count, .uint32, .{}),
    } };
};

/// A message of flat children: one singular, and a list.
const Branch = struct {
    first: ?Leaf = null,
    rest: proto.Repeated(Leaf, .message) = .{},
    pub const FieldNumber = enum(u29) { first = 1, rest = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Branch", .fields = &.{
        proto.field_of(FieldNumber.first, .message, .{}),
        proto.field_of(FieldNumber.rest, .message, .{}),
    } };
};

/// The longest payload the sweep writes: 2^14 + 2, past the lengths whose prefix takes 3 octets.
const payload_len_max = 16_386;
/// The most leaves one branch of the sweep holds, and room for each one's tags and prefixes.
const leaves_max = 3;
const prefixes_len_max = 32;
const encoded_len_max = leaves_max * (payload_len_max + prefixes_len_max);
/// How far below and above its length the sweep gives an encoding room.
const room_margin = 8;
/// A count whose varint takes two octets.
const count_two_octets = 300;

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

    fn tag(out: *Out, number: u32, wire_type: u64) void {
        out.varint(@as(u64, number) << wire_type_bits | wire_type);
    }
};

/// A leaf's fields in number order, each left off at its default ("Default Values").
fn reference_leaf(leaf: *const Leaf, out: *Out) void {
    if (leaf.payload.len != 0) {
        out.tag(@intFromEnum(Leaf.FieldNumber.payload), wire_type_len);
        out.varint(leaf.payload.len);
        out.octets(leaf.payload);
    }
    if (leaf.count != 0) {
        out.tag(@intFromEnum(Leaf.FieldNumber.count), wire_type_varint);
        out.varint(leaf.count);
    }
}

/// A leaf as a child: its tag, its length, then its fields ("Length-Delimited Records").
fn reference_child(number: u32, leaf: *const Leaf, out: *Out) void {
    var storage: [payload_len_max + prefixes_len_max]u8 = @splat(0);
    var body: Out = .{ .buffer = &storage };
    reference_leaf(leaf, &body);
    out.tag(number, wire_type_len);
    out.varint(body.len);
    out.octets(storage[0..body.len]);
}

fn reference_branch(branch: *const Branch, out: *Out) void {
    if (branch.first) |*first| reference_child(@intFromEnum(Branch.FieldNumber.first), first, out);
    for (branch.rest.items) |*leaf| reference_child(@intFromEnum(Branch.FieldNumber.rest), leaf, out);
}

/// Encodes `branch` in every room from `room_margin` below its length to as far above it, and
/// requires the reference's octets, or `error.NoSpaceLeft` where they do not fit.
fn check_encode(branch: *const Branch) !void {
    var want_storage: [encoded_len_max]u8 = @splat(0);
    var want: Out = .{ .buffer = &want_storage };
    reference_branch(branch, &want);
    try testing.expectEqual(want.len, try proto.encoded_len(Branch, branch));
    var got: [encoded_len_max]u8 = @splat(0);
    for (want.len -| room_margin..want.len + room_margin + 1) |room| {
        const result = proto.encode(Branch, branch, got[0..room]);
        if (room < want.len) {
            try testing.expectError(error.NoSpaceLeft, result);
        } else {
            try testing.expectEqualSlices(u8, want_storage[0..want.len], try result);
        }
    }
}

test "a flat child encodes as the reference, at each length, alone and in a list, in every room" {
    // Each length from 0 to 16, and those on each side of the lengths whose prefix takes 2 and 3
    // octets.
    const payload_lens = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 124, 125, 126, 127, 128, 129, 130, 16_380, 16_381, 16_382, 16_383, 16_384, 16_385, 16_386 };
    var payload: [payload_len_max]u8 = @splat('x');
    for (payload_lens) |len| {
        for ([_]u32{ 0, 1, count_two_octets }) |count| {
            const leaf: Leaf = .{ .payload = payload[0..len], .count = count };
            try check_encode(&.{ .first = leaf });
            const list = [leaves_max]Leaf{ leaf, .{ .payload = "c" }, leaf };
            try check_encode(&.{ .rest = .of(&list) });
            try check_encode(&.{ .first = .{ .count = 1 }, .rest = .of(list[0..2]) });
        }
    }
}
