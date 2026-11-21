//! `Report`: the violations `validate` found, in storage the caller owns (decision 47).
//!
//! The storage holds each `buf.validate.Violation` from its start. From its end it holds what a
//! violation points to: the elements of its field's path. A violation's rule path, its rule id
//! and a standard rule's message are comptime data, which take no storage.
//!
//! `add` and `Path` are what the module's own files call. A program calls `Report`'s methods.
const std = @import("std");
const assert = std.debug.assert;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const constants = @import("constants.zig");

pub const Violation = pb.Violation;
pub const Element = pb.FieldPathElement;

/// The alignment of a report's storage: a violation's.
pub const storage_alignment = @alignOf(Violation);

comptime {
    // An element lies at the storage's end, where `add` aligns it down to a violation's
    // alignment, so it needs no stricter one.
    assert(@alignOf(Element) <= storage_alignment);
}

/// One step of a field's path, which the walk keeps on its stack: the field of the message that
/// holds it, and the step of that message's own field, up to the message `validate` took.
pub const Path = struct {
    parent: ?*const Path,
    element: Element,

    /// The steps from the root to this one.
    pub fn depth(path: *const Path) usize {
        var steps: usize = 1;
        var step = path;
        for (0..constants.path_depth_max) |_| {
            step = step.parent orelse return steps;
            steps += 1;
        }
        unreachable;
    }
};

pub const Report = struct {
    storage: []align(storage_alignment) u8,
    /// The violations written, which lie from the storage's start.
    count: usize = 0,
    /// The octets taken from the storage's end.
    tail_len: usize = 0,
    /// Whether `validate` stopped because the storage was full: the message breaks more rules
    /// than the report holds.
    truncated: bool = false,

    /// A report with no violation, over `storage`, which must outlive it.
    pub fn init(storage: []align(storage_alignment) u8) Report {
        return .{ .storage = storage };
    }

    /// The violations, in the order `validate` found them. Each points into the storage, into
    /// comptime data, and, for a map's string key, into the message `validate` read.
    pub fn violations(report: *const Report) []const Violation {
        assert(report.count * @sizeOf(Violation) + report.tail_len <= report.storage.len);
        const all: [*]const Violation = @ptrCast(report.storage.ptr);
        return all[0..report.count];
    }

    /// Forgets every violation, so the report takes another message's.
    pub fn clear(report: *Report) void {
        report.* = .{ .storage = report.storage };
    }

    /// The octets `encode` writes.
    pub fn encoded_len(report: *const Report) proto.EncodeError!usize {
        const message: pb.Violations = .{ .violations = .of(report.violations()) };
        return proto.encoded_len(pb.Violations, &message);
    }

    /// Encodes the violations as a `buf.validate.Violations` into `buffer`, and returns the
    /// octets written: what an RPC error carries as a detail of that name.
    pub fn encode(report: *const Report, buffer: []u8) proto.EncodeError![]u8 {
        const message: pb.Violations = .{ .violations = .of(report.violations()) };
        return proto.encode(pb.Violations, &message, buffer);
    }
};

/// What `add` writes beside the field's path.
pub const Entry = struct {
    /// The path of the rule within `buf.validate.FieldRules`, or none for a rule of a message
    /// or of a oneof.
    rule: ?pb.FieldPath = null,
    rule_id: []const u8,
    message: []const u8,
    /// Whether the rule read a map entry's key, not its value.
    for_key: bool = false,
};

/// Writes one violation of the field at `path`, or of the message itself when `path` is null.
/// Returns false, and marks the report truncated, when the storage has no room for it.
pub fn add(report: *Report, path: ?*const Path, entry: Entry) bool {
    assert(entry.rule_id.len != 0);
    const depth = if (path) |leaf| leaf.depth() else 0;
    const front_len = (report.count + 1) * @sizeOf(Violation);
    const elements_len = depth * @sizeOf(Element);
    const tail_len = std.mem.alignForward(usize, report.tail_len + elements_len, storage_alignment);
    if (front_len + tail_len > report.storage.len) {
        report.truncated = true;
        return false;
    }
    const start = report.storage.len - tail_len;
    const elements: []Element = @as([*]Element, @ptrCast(@alignCast(report.storage.ptr + start)))[0..depth];
    var step = path;
    for (0..depth) |index| {
        elements[depth - 1 - index] = step.?.element;
        step = step.?.parent;
    }
    assert(step == null);
    const all: [*]Violation = @ptrCast(report.storage.ptr);
    all[report.count] = .{
        .field = if (depth == 0) null else .{ .elements = .of(elements) },
        .rule = entry.rule,
        .rule_id = entry.rule_id,
        .message = entry.message,
        .for_key = if (entry.for_key) true else null,
    };
    report.count += 1;
    report.tail_len = tail_len;
    return true;
}

const testing = std.testing;

fn step_named(name: []const u8, parent: ?*const Path) Path {
    return .{ .parent = parent, .element = .{ .field_name = name } };
}

test "a report keeps each violation with its field's path, root first" {
    var storage: [constants.report_bytes_default]u8 align(storage_alignment) = undefined;
    var report: Report = .init(&storage);
    const outer = step_named("outer", null);
    const inner = step_named("inner", &outer);
    try testing.expect(add(&report, &inner, .{ .rule_id = "string.min_len", .message = "too short" }));
    try testing.expect(add(&report, null, .{ .rule_id = "message.oneof", .message = "one of a, b", .for_key = true }));
    const list = report.violations();
    try testing.expectEqual(@as(usize, 2), list.len);
    const elements = list[0].field.?.elements.items;
    try testing.expectEqual(@as(usize, 2), elements.len);
    try testing.expectEqualStrings("outer", elements[0].field_name.?);
    try testing.expectEqualStrings("inner", elements[1].field_name.?);
    try testing.expectEqualStrings("string.min_len", list[0].rule_id.?);
    try testing.expectEqualStrings("too short", list[0].message.?);
    try testing.expectEqual(@as(?bool, null), list[0].for_key);
    // A rule of the message itself names no field.
    try testing.expect(list[1].field == null);
    try testing.expectEqual(@as(?bool, true), list[1].for_key);
    try testing.expect(!report.truncated);
}

test "a full report refuses a violation, keeps the ones it holds and says it is truncated" {
    // Room for two violations and the one path element of the first.
    var storage: [2 * @sizeOf(Violation) + @sizeOf(Element)]u8 align(storage_alignment) = undefined;
    var report: Report = .init(&storage);
    const field = step_named("name", null);
    try testing.expect(add(&report, &field, .{ .rule_id = "a", .message = "" }));
    // A second path element has no room, and a violation with no path still has.
    try testing.expect(!add(&report, &field, .{ .rule_id = "b", .message = "" }));
    try testing.expect(report.truncated);
    try testing.expectEqual(@as(usize, 1), report.violations().len);
    try testing.expect(add(&report, null, .{ .rule_id = "c", .message = "" }));
    try testing.expect(!add(&report, null, .{ .rule_id = "d", .message = "" }));
    try testing.expectEqual(@as(usize, 2), report.violations().len);
    try testing.expectEqualStrings("name", report.violations()[0].field.?.elements.items[0].field_name.?);
    report.clear();
    try testing.expectEqual(@as(usize, 0), report.violations().len);
    try testing.expect(!report.truncated);
}

test "a report encodes as buf.validate.Violations" {
    var storage: [constants.report_bytes_default]u8 align(storage_alignment) = undefined;
    var report: Report = .init(&storage);
    const field: Path = .{ .parent = null, .element = .{ .field_number = 1, .field_name = "name", .field_type = .type_string, .subscript = .{ .index = 1 } } };
    try testing.expect(add(&report, &field, .{ .rule_id = "string.min_len", .message = "too short" }));
    var buffer: [256]u8 = undefined;
    const bytes = try report.encode(&buffer);
    try testing.expectEqual(bytes.len, try report.encoded_len());
    const decoded = try proto.decode(pb.Violations, bytes);
    var each = decoded.violations.iterator();
    const violation = (try each.next()).?;
    try testing.expectEqualStrings("string.min_len", violation.rule_id.?);
    var elements = violation.field.?.elements.iterator();
    const element = (try elements.next()).?;
    try testing.expectEqualStrings("name", element.field_name.?);
    try testing.expectEqual(@as(?i32, 1), element.field_number);
    try testing.expectEqual(@as(u64, 1), element.subscript.?.index);
    try testing.expect(try each.next() == null);
}
