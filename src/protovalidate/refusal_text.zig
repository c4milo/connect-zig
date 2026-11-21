//! The message of the error an interceptor refuses a message with (decision 47): the first
//! violation's field and what it broke, and the count of the others.
//!
//! A field's path reads as protovalidate's libraries write it: names joined with ".", and a
//! subscript in brackets after its field, `tags[1]` or `labels["env"]`.
const std = @import("std");
const assert = std.debug.assert;
const report_file = @import("report.zig");
const Violation = report_file.Violation;
const Element = report_file.Element;

/// The message of an error that names no violation: the report had no room for one.
pub const no_violation = "the message breaks a rule of its schema";

/// Writes the message for `violations` into `buffer`, and returns it. A text longer than the
/// buffer gives way to the first violation's own message, which is comptime data.
pub fn describe(violations: []const Violation, buffer: []u8) []const u8 {
    if (violations.len == 0) return no_violation;
    const first = &violations[0];
    var writer: std.Io.Writer = .fixed(buffer);
    write(&writer, first, violations.len - 1) catch return first.message.?;
    return writer.buffered();
}

fn write(writer: *std.Io.Writer, first: *const Violation, others: usize) std.Io.Writer.Error!void {
    // A rule of the message itself names no field.
    if (first.field) |path| {
        try write_path(writer, path.elements.items);
        try writer.writeAll(": ");
    }
    try writer.writeAll(first.message.?);
    if (others > 0) try writer.print(" (and {d} more)", .{others});
}

fn write_path(writer: *std.Io.Writer, elements: []const Element) std.Io.Writer.Error!void {
    assert(elements.len > 0);
    for (elements, 0..) |*element, index| {
        if (index > 0) try writer.writeByte('.');
        try writer.writeAll(element.field_name.?);
        const subscript = element.subscript orelse continue;
        switch (subscript) {
            .index, .uint_key => |number| try writer.print("[{d}]", .{number}),
            .int_key => |number| try writer.print("[{d}]", .{number}),
            .bool_key => |flag| try writer.print("[{}]", .{flag}),
            .string_key => |key| try write_key(writer, key),
        }
    }
}

/// A map's string key, between quotes, with a backslash before each quote and backslash of it.
fn write_key(writer: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("[\"");
    for (key) |octet| {
        if (octet == '"' or octet == '\\') try writer.writeByte('\\');
        try writer.writeByte(octet);
    }
    try writer.writeAll("\"]");
}

const testing = std.testing;
const constants = @import("constants.zig");

fn violation_at(elements: []const Element, message: []const u8) Violation {
    return .{ .field = if (elements.len == 0) null else .{ .elements = .of(elements) }, .rule_id = "r", .message = message };
}

fn expect_text(expected: []const u8, violations: []const Violation) !void {
    var buffer: [constants.refusal_message_len_max]u8 = undefined;
    try testing.expectEqualStrings(expected, describe(violations, &buffer));
}

test "the message names the first violation's field, what it broke, and the count of the others" {
    const name = [_]Element{.{ .field_name = "name" }};
    const one = [_]Violation{violation_at(&name, "value is required")};
    try expect_text("name: value is required", &one);
    const three = [_]Violation{ one[0], one[0], one[0] };
    try expect_text("name: value is required (and 2 more)", &three);
    // A rule of the message itself names no field.
    try expect_text("one of a, b must be set", &.{violation_at(&.{}, "one of a, b must be set")});
    try expect_text(no_violation, &.{});
}

test "a path joins its names with dots, and writes each subscript after its field" {
    const nested = [_]Element{ .{ .field_name = "user" }, .{ .field_name = "tags", .subscript = .{ .index = 1 } }, .{ .field_name = "text" } };
    try expect_text("user.tags[1].text: m", &.{violation_at(&nested, "m")});
    const keys = [_]Element{
        .{ .field_name = "a", .subscript = .{ .int_key = -2 } },
        .{ .field_name = "b", .subscript = .{ .uint_key = 3 } },
        .{ .field_name = "c", .subscript = .{ .bool_key = true } },
        .{ .field_name = "d", .subscript = .{ .string_key = "e\"n\\v" } },
    };
    try expect_text("a[-2].b[3].c[true].d[\"e\\\"n\\\\v\"]: m", &.{violation_at(&keys, "m")});
}

test "a text longer than its room gives way to the violation's own message" {
    const long = [_]Element{.{ .field_name = "labels", .subscript = .{ .string_key = "k" ** constants.refusal_message_len_max } }};
    try expect_text("too short", &.{violation_at(&long, "too short")});
    // A text of the room's exact length fits.
    const prefix = "f: ";
    const exact = [_]Element{.{ .field_name = "f" }};
    const message = "m" ** (constants.refusal_message_len_max - prefix.len);
    try expect_text(prefix ++ message, &.{violation_at(&exact, message)});
}
