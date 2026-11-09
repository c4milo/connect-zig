//! The fixed messages the benchmark encodes, built the same way by bench/go/inputs.go. Nothing
//! here is random: every value follows from its index, so Zig and Go encode the same message, and
//! tools/bench_check.sh compares their bytes.
//!
//! `build` fills the storage the messages point into. Call it once, before reading a message.
const std = @import("std");
const assert = std.debug.assert;
const bench = @import("bench_v1");

const Small = bench.Small;
const Medium = bench.Medium;
const Address = bench.Address;
const Record = bench.Record;
const Large = bench.Large;
const Deep = bench.Deep;
const Varints = bench.Varints;
const Strings = bench.Strings;
const Tree = bench.Tree;
const Packed = bench.Packed;

pub const small: Small = .{
    .id = 12_345,
    .created = 1_700_000_000_123,
    .active = true,
    .name = "alice@example.com",
    .score = 98.625,
};

/// The medium message's counts: 64 samples, 16 tags, 16 map entries and 4 previous addresses
/// make about 1 KB.
pub const medium_samples_count = 64;
pub const medium_tags_count = 16;
pub const medium_counters_count = 16;
pub const medium_previous_count = 4;
/// Sample i is i * i * sample_scale - sample_offset, so some are negative and take 10 bytes.
const sample_scale = 1009;
const sample_offset = 50_000;
/// Counter i holds (i + 1) * counter_scale: never zero, see `build_medium`.
const counter_scale = 1_000_003;
const previous_postal_code_first = 10_000;
/// "tag-00", "counter-00" and "00 Main Street": two digits after a fixed prefix.
const tag_len = "tag-00".len;
const counter_key_len = "counter-00".len;
const previous_street_len = "00 Main Street".len;

/// The large message: 1000 records of 128 payload bytes and 8 values each, about 180 KB.
pub const large_records_count = 1000;
pub const record_payload_len = 128;
pub const record_values_count = 8;
const record_id_first = 1_000_000;
/// "record-00000": five digits after the prefix.
const record_key_len = "record-00000".len;
/// Payload byte j of record i is (i * payload_record_step + j * payload_byte_step) mod 256.
const payload_record_step = 31;
const payload_byte_step = 7;
/// Value j of record i is (i * value_record_step + j * value_index_step) mod value_modulus,
/// less value_offset: values from -1000 to 1000.
const value_record_step = 13;
const value_index_step = 17;
const value_modulus = 2001;
const value_offset = 1000;
/// Record i weighs i * weight_step.
const weight_step = 0.5;
/// Record i has status i mod status_count.
const status_count = 4;

/// The deep message: 50 messages, each the child of the one before.
pub const deep_levels_count = 50;
/// "level-00": two digits after the prefix.
const deep_label_len = "level-00".len;

var samples: [medium_samples_count]i64 align(@alignOf(i64)) = undefined;
var tags: [medium_tags_count][]const u8 align(@alignOf([]const u8)) = undefined;
var tag_text: [medium_tags_count][tag_len]u8 align(1) = undefined;
var counters: [medium_counters_count]Medium.CountersEntry align(@alignOf(Medium.CountersEntry)) = undefined;
var counter_text: [medium_counters_count][counter_key_len]u8 align(1) = undefined;
var previous: [medium_previous_count]Address align(@alignOf(Address)) = undefined;
var previous_text: [medium_previous_count][previous_street_len]u8 align(1) = undefined;
pub var medium: Medium align(@alignOf(Medium)) = .{};

var records: [large_records_count]Record align(@alignOf(Record)) = undefined;
var record_keys: [large_records_count][record_key_len]u8 align(1) = undefined;
var record_payloads: [large_records_count][record_payload_len]u8 align(1) = undefined;
var record_values: [large_records_count][record_values_count]i32 align(@alignOf(i32)) = undefined;
pub var large: Large align(@alignOf(Large)) = .{};

var deep_nodes: [deep_levels_count]Deep align(@alignOf(Deep)) = undefined;
var deep_labels: [deep_levels_count][deep_label_len]u8 align(1) = undefined;

/// The outermost of the deep messages.
pub fn deep() *const Deep {
    return &deep_nodes[0];
}

pub fn build() void {
    build_medium();
    build_large();
    build_deep();
    build_tree();
    build_packed();
}

fn build_medium() void {
    for (&samples, 0..) |*sample, i| {
        const index: i64 = @intCast(i);
        sample.* = index * index * sample_scale - sample_offset;
    }
    for (&tags, &tag_text, 0..) |*tag, *text, i| tag.* = print(text, "tag-{d:0>2}", .{i});
    // A map entry whose value is zero is left out: Go writes a map entry's zero value and this
    // library does not, and both are valid ("Maps", encoding guide), so the bytes would differ.
    for (&counters, &counter_text, 0..) |*counter, *text, i| {
        const index: i64 = @intCast(i);
        counter.* = .{ .key = print(text, "counter-{d:0>2}", .{i}), .value = (index + 1) * counter_scale };
    }
    for (&previous, &previous_text, 0..) |*address, *text, i| {
        const index: u32 = @intCast(i);
        address.* = .{
            .street = print(text, "{d:0>2} Main Street", .{i}),
            .city = "Springfield",
            .country = "US",
            .postal_code = previous_postal_code_first + index,
        };
    }
    medium = .{
        .id = 9_876_543_210,
        .name = "Medium benchmark record",
        .status = .status_active,
        .home = .{ .street = "1600 Amphitheatre Parkway", .city = "Mountain View", .country = "US", .postal_code = 94_043 },
        .samples = .of(&samples),
        .tags = .of(&tags),
        .counters = .of(&counters),
        .contact = .{ .office = .{ .street = "500 Terry Francine Street", .city = "San Francisco", .country = "US", .postal_code = 94_158 } },
        .previous = .of(&previous),
        .checksum = 0xdead_beef_cafe_f00d,
        .ratio = 0.75,
        .delta = -12_345,
    };
}

/// The phrase the large message's description repeats: ASCII, Latin, CJK and a dash, so a
/// parser's UTF-8 check takes every length of character. bench/go/inputs.go repeats the same.
const description_phrase = "A batch of records: données, 日本語のテキスト, ünïcode — end. ";
const description_repeats = 100;
const description = description_phrase ** description_repeats;

fn build_large() void {
    for (&records, 0..) |*record, i| {
        for (&record_payloads[i], 0..) |*octet, j| octet.* = @truncate(i * payload_record_step + j * payload_byte_step);
        for (&record_values[i], 0..) |*value, j| {
            const raw: i32 = @intCast((i * value_record_step + j * value_index_step) % value_modulus);
            value.* = raw - value_offset;
        }
        const index: u64 = @intCast(i);
        record.* = .{
            .id = record_id_first + index,
            .key = print(&record_keys[i], "record-{d:0>5}", .{i}),
            .payload = &record_payloads[i],
            .values = .of(&record_values[i]),
            .weight = @as(f64, @floatFromInt(i)) * weight_step,
            .status = @enumFromInt(i % status_count),
        };
    }
    large = .{ .name = "Large benchmark batch", .records = .of(&records), .description = description };
}

fn build_deep() void {
    for (&deep_nodes, &deep_labels, 0..) |*node, *label, i| {
        node.* = .{ .level = @intCast(i + 1), .label = print(label, "level-{d:0>2}", .{i}) };
        if (i + 1 < deep_levels_count) node.child = .of(&deep_nodes[i + 1]);
    }
    assert(!deep_nodes[deep_levels_count - 1].child.present());
}

/// Every varint kind at each length from 1 to 10 bytes, as the comment of each value counts.
pub const varints: Varints = .{
    .int32_one = 100,
    .int32_two = 300,
    // A negative int32 is sign-extended to ten bytes ("Base 128 Varints").
    .int32_negative = -1,
    .int64_three = 100_000,
    .int64_eight = 1 << 50,
    .uint32_four = 1 << 22,
    .uint32_five = 4_000_000_000,
    .uint64_six = 1 << 36,
    .uint64_ten = std.math.maxInt(u64),
    // Zigzag: -5 is 9, one byte; -50,000 is 99,999, three bytes.
    .sint32_one = -5,
    .sint32_three = -50_000,
    // Zigzag: -2^44 is 2^45 - 1, seven bytes; 2^60 is 2^61, nine bytes.
    .sint64_seven = -(1 << 44),
    .sint64_nine = 1 << 60,
    .flag = true,
    .status = .status_closed,
    .uint64_two = 200,
};

/// The text every ASCII string of `strings` is a prefix of. bench/go/inputs.go uses the same.
const ascii_text = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-_";

pub const strings: Strings = .{
    .one = ascii_text[0..1],
    .three = ascii_text[0..3],
    .seven = ascii_text[0..7],
    .eight = ascii_text[0..8],
    .fifteen = ascii_text[0..15],
    .sixteen = ascii_text[0..16],
    .thirty_one = ascii_text[0..31],
    .thirty_two = ascii_text[0..32],
    .sixty_four = ascii_text[0..64],
    .latin = "données, ünïcode",
    .cjk = "日本語のテキスト",
};

/// The tree: each node above the last level holds `tree_fanout` children, `tree_levels_count`
/// levels below the root, so 1 + 4 + 16 + 64 + 256 = 341 nodes.
pub const tree_fanout = 4;
pub const tree_levels_count = 4;
var tree_level_1: [tree_fanout]Tree align(@alignOf(Tree)) = undefined;
var tree_level_2: [tree_fanout * tree_fanout]Tree align(@alignOf(Tree)) = undefined;
var tree_level_3: [tree_fanout * tree_fanout * tree_fanout]Tree align(@alignOf(Tree)) = undefined;
/// The leaves, which hold no children.
var tree_level_4: [tree_fanout * tree_fanout * tree_fanout * tree_fanout]Tree align(@alignOf(Tree)) = @splat(.{});
pub var tree: Tree align(@alignOf(Tree)) = .{};

fn build_tree() void {
    link_level(&tree_level_3, &tree_level_4);
    link_level(&tree_level_2, &tree_level_3);
    link_level(&tree_level_1, &tree_level_2);
    tree = .{ .children = .of(&tree_level_1) };
}

/// Gives node i of `parents` the `tree_fanout` children from `tree_fanout` * i.
fn link_level(parents: []Tree, children: []const Tree) void {
    assert(children.len == parents.len * tree_fanout);
    for (parents, 0..) |*parent, i| parent.* = .{ .children = .of(children[i * tree_fanout ..][0..tree_fanout]) };
}

/// The packed message: `packed_count` elements in each field. Element i of `small` is i, of
/// `wide` 2^i, of `zigzag` i - `packed_count` / 2, and of `reals` i * `real_step`.
pub const packed_count = 64;
const real_step = 0.25;
var packed_small: [packed_count]i32 align(@alignOf(i32)) = undefined;
var packed_wide: [packed_count]u64 align(@alignOf(u64)) = undefined;
var packed_zigzag: [packed_count]i32 align(@alignOf(i32)) = undefined;
var packed_reals: [packed_count]f64 align(@alignOf(f64)) = undefined;
pub var packed_scalars: Packed align(@alignOf(Packed)) = .{};

fn build_packed() void {
    for (&packed_small, &packed_wide, &packed_zigzag, &packed_reals, 0..) |*small_value, *wide, *zigzag, *real, i| {
        const index: i32 = @intCast(i);
        small_value.* = index;
        wide.* = @as(u64, 1) << @intCast(i);
        zigzag.* = index - packed_count / 2;
        real.* = @as(f64, @floatFromInt(i)) * real_step;
    }
    packed_scalars = .{
        .small = .of(&packed_small),
        .wide = .of(&packed_wide),
        .zigzag = .of(&packed_zigzag),
        .reals = .of(&packed_reals),
    };
}

/// Formats into `text`, which the format fills exactly.
fn print(text: []u8, comptime format: []const u8, arguments: anytype) []const u8 {
    const written = std.fmt.bufPrint(text, format, arguments) catch unreachable;
    assert(written.len == text.len);
    return written;
}
