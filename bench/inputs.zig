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

/// Formats into `text`, which the format fills exactly.
fn print(text: []u8, comptime format: []const u8, arguments: anytype) []const u8 {
    const written = std.fmt.bufPrint(text, format, arguments) catch unreachable;
    assert(written.len == text.len);
    return written;
}
