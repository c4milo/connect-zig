//! Reads every field of a message and folds what it read into one number, as bench/go/walk.go
//! does. A decoded message here is lazy: strings and bytes point into the input, and a repeated
//! field or a recursive one is decoded when it is read. Walking it does the work that Go's
//! `proto.Unmarshal` does up front, so "decode+walk" compares like with like.
//!
//! The fold adds, with wrapping: each integer and enum as a sign-extended 64-bit value, each bool
//! as 0 or 1, each float's bits, and each string's and bytes field's length. A message folds its
//! fields in field-number order, a repeated field its elements in order. A tree, which holds no
//! scalar, adds one for each node.
const std = @import("std");
const proto = @import("protobuf");
const bench = @import("bench_v1");
const inputs = @import("inputs.zig");

const Error = proto.Error;

pub fn small(message: *const bench.Small) Error!u64 {
    var sum: u64 = int(message.id);
    sum +%= int(message.created);
    sum +%= @intFromBool(message.active);
    sum +%= message.name.len;
    sum +%= @as(u64, @bitCast(message.score));
    return sum;
}

pub fn medium(message: *const bench.Medium) Error!u64 {
    var sum: u64 = message.id;
    sum +%= message.name.len;
    sum +%= int(@intFromEnum(message.status));
    if (message.home) |home| sum +%= try address(home);
    sum +%= try each(@TypeOf(message.samples), &message.samples, sample);
    sum +%= try each(@TypeOf(message.tags), &message.tags, text);
    sum +%= try each(@TypeOf(message.counters), &message.counters, counter);
    if (message.contact) |contact| sum +%= try contact_sum(contact);
    sum +%= try each(@TypeOf(message.previous), &message.previous, address);
    sum +%= message.checksum;
    sum +%= @as(u32, @bitCast(message.ratio));
    sum +%= int(message.delta);
    return sum;
}

fn contact_sum(contact: @typeInfo(@FieldType(bench.Medium, "contact")).optional.child) Error!u64 {
    return switch (contact) {
        .email, .phone => |value| value.len,
        .office => |office| try address(office),
    };
}

fn address(message: bench.Address) Error!u64 {
    return message.street.len +% message.city.len +% message.country.len +% message.postal_code;
}

fn counter(entry: bench.Medium.CountersEntry) Error!u64 {
    return entry.key.len +% int(entry.value);
}

fn sample(value: i64) Error!u64 {
    return int(value);
}

fn text(value: []const u8) Error!u64 {
    return value.len;
}

fn signed(value: i32) Error!u64 {
    return int(value);
}

fn record(message: bench.Record) Error!u64 {
    var sum: u64 = message.id;
    sum +%= message.key.len;
    sum +%= message.payload.len;
    sum +%= try each(@TypeOf(message.values), &message.values, signed);
    sum +%= @as(u64, @bitCast(message.weight));
    sum +%= int(@intFromEnum(message.status));
    return sum;
}

pub fn large(message: *const bench.Large) Error!u64 {
    return message.name.len +% message.description.len +% try each(@TypeOf(message.records), &message.records, record);
}

/// Follows the chain of children one level at a time, as deep as the benchmark builds it.
pub fn deep(message: *const bench.Deep) Error!u64 {
    var sum: u64 = 0;
    var node = message.*;
    for (0..inputs.deep_levels_count) |_| {
        sum +%= int(node.level);
        sum +%= node.label.len;
        node = try node.child.get() orelse return sum;
    }
    return error.DepthExceeded;
}

pub fn varints(message: *const bench.Varints) Error!u64 {
    var sum: u64 = int(message.int32_one);
    sum +%= int(message.int32_two);
    sum +%= int(message.int32_negative);
    sum +%= int(message.int64_three);
    sum +%= int(message.int64_eight);
    sum +%= message.uint32_four;
    sum +%= message.uint32_five;
    sum +%= message.uint64_six;
    sum +%= message.uint64_ten;
    sum +%= int(message.sint32_one);
    sum +%= int(message.sint32_three);
    sum +%= int(message.sint64_seven);
    sum +%= int(message.sint64_nine);
    sum +%= @intFromBool(message.flag);
    sum +%= int(@intFromEnum(message.status));
    sum +%= message.uint64_two;
    return sum;
}

pub fn strings(message: *const bench.Strings) Error!u64 {
    var sum: u64 = message.one.len;
    sum +%= message.three.len;
    sum +%= message.seven.len;
    sum +%= message.eight.len;
    sum +%= message.fifteen.len;
    sum +%= message.sixteen.len;
    sum +%= message.thirty_one.len;
    sum +%= message.thirty_two.len;
    sum +%= message.sixty_four.len;
    sum +%= message.latin.len;
    sum +%= message.cjk.len;
    return sum;
}

/// A tree holds no scalar, so its walk counts the nodes it reads, itself included.
pub fn tree(message: *const bench.Tree) Error!u64 {
    return tree_node(message.*);
}

fn tree_node(message: bench.Tree) Error!u64 {
    return 1 +% try each(@TypeOf(message.children), &message.children, tree_node);
}

fn real(value: f64) Error!u64 {
    return @bitCast(value);
}

fn unsigned(value: u64) Error!u64 {
    return value;
}

pub fn packed_scalars(message: *const bench.Packed) Error!u64 {
    var sum = try each(@TypeOf(message.small), &message.small, signed);
    sum +%= try each(@TypeOf(message.wide), &message.wide, unsigned);
    sum +%= try each(@TypeOf(message.zigzag), &message.zigzag, signed);
    sum +%= try each(@TypeOf(message.reals), &message.reals, real);
    return sum;
}

fn each(comptime Field: type, field: *const Field, comptime fold: fn (Field.Element) Error!u64) Error!u64 {
    var elements = field.iterator();
    var sum: u64 = 0;
    for (0..proto.constants.limits.elements_max) |_| {
        const element = try elements.next() orelse return sum;
        sum +%= try fold(element);
    }
    unreachable;
}

/// An integer as Go's uint64(int64(value)) reads it: sign-extended, then reinterpreted.
fn int(value: anytype) u64 {
    const wide: i64 = value;
    return @bitCast(wide);
}

comptime {
    std.debug.assert(inputs.deep_levels_count < proto.constants.limits.depth_max);
}
