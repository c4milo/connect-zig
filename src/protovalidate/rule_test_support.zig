//! What the tests of the rules share: a message of one field with rules, and the ids of the
//! rules a value of it breaks.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const table = @import("table.zig");
const constants = @import("constants.zig");
const report_file = @import("report.zig");
const walk_file = @import("walk.zig");
const validate_file = @import("validate.zig");

/// A message whose one field, `val`, is a `Field` of `kind` with `rules`.
pub fn One(comptime Field: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules) type {
    return struct {
        val: Field,
        pub const FieldNumber = enum(u29) { val = 1 };
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.One", .fields = &.{proto.field_of(FieldNumber.val, kind, .{})} };
        pub const protovalidate: table.Rules = .{ .fields = &.{.{ .number = @intFromEnum(FieldNumber.val), .rules = rules }} };
    };
}

/// The longest list of ids a test compares, as text.
const ids_len_max = 1024;

/// Requires `value` to break the rules whose ids `expected` lists, joined with spaces, in the
/// order the walk reports them: "" for a value that passes.
pub fn expect(comptime Field: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules, value: Field, expected: []const u8) !void {
    return expect_at(Field, kind, rules, value, .{ .cpu_features = .target() }, expected);
}

pub fn expect_at(comptime Field: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules, value: Field, options: walk_file.Options, expected: []const u8) !void {
    const T = One(Field, kind, rules);
    var storage: [constants.report_bytes_default]u8 align(report_file.storage_alignment) = undefined;
    var report: report_file.Report = .init(&storage);
    const message: T = .{ .val = value };
    validate_file.validate(T, &message, options, &report) catch |failure| switch (failure) {
        error.Invalid => {},
        else => return failure,
    };
    var buffer: [ids_len_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (report.violations(), 0..) |violation, index| try writer.print("{s}{s}", .{ if (index == 0) "" else " ", violation.rule_id.? });
    try testing.expectEqualStrings(expected, writer.buffered());
}

/// The message of the one violation `value` reports.
pub fn expect_message(comptime Field: type, comptime kind: proto.Kind, comptime rules: pb.FieldRules, value: Field, expected: []const u8) !void {
    const T = One(Field, kind, rules);
    var storage: [constants.report_bytes_default]u8 align(report_file.storage_alignment) = undefined;
    var report: report_file.Report = .init(&storage);
    const message: T = .{ .val = value };
    try testing.expectError(error.Invalid, validate_file.validate(T, &message, .{ .cpu_features = .target() }, &report));
    try testing.expectEqual(@as(usize, 1), report.violations().len);
    try testing.expectEqualStrings(expected, report.violations()[0].message.?);
}
