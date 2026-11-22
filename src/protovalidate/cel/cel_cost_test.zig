//! Tests of what an expression costs the compiler (docs/performance.md, "The compiler's time").
//!
//! The compiler counts the branches and the calls of one comptime evaluation against a quota:
//! 1000, or what `@setEvalBranchQuota` raised it to. It counts a call it answers from its
//! memory as the call counted when it ran, so the count of an evaluation is the same in each
//! build. A test here states a cost as a quota, and the tests do not build when the code takes
//! more: the commit that pays for a higher cost raises the quota and says why.
//!
//! - Typing the reference expressions fits `typing_branches_max`.
//! - No file on the typing's path raises the quota. The compiler keeps no answer of a
//!   function that raises it, nor of a function that calls one, so one such call makes the
//!   compiler type each part of an expression again for each question about it.
//!
//! `cel_parse.zig` holds the test of what reading an expression's text costs.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const proto = @import("protobuf");
const parser = @import("cel_parse.zig");
const check = @import("cel_check.zig");
const program = @import("cel_program.zig");
const type_file = @import("cel_type.zig");
const Scope = type_file.Scope;

const Leaf = struct {
    name: []const u8 = "",
    count: i32 = 0,
    pub const FieldNumber = enum(u29) { name = 1, count = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "cost.Leaf", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}), proto.field_of(FieldNumber.count, .int32, .{}),
    } };
};

const CountsEntry = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "cost.Message.CountsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

/// A message with a field of each kind an expression reads in its own way.
const Message = struct {
    name: []const u8 = "",
    count: i32 = 0,
    ratio: f64 = 0,
    names: proto.Repeated([]const u8, .string) = .{},
    counts: proto.Repeated(CountsEntry, .message) = .{},
    took: ?proto.wkt.Duration = null,
    at: ?proto.wkt.Timestamp = null,
    leaf: ?Leaf = null,
    pub const FieldNumber = enum(u29) { name = 1, count = 2, ratio = 3, names = 4, counts = 5, took = 6, at = 7, leaf = 8 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "cost.Message", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),    proto.field_of(FieldNumber.count, .int32, .{}),
        proto.field_of(FieldNumber.ratio, .double, .{}),   proto.field_of(FieldNumber.names, .string, .{}),
        proto.field_of(FieldNumber.counts, .message, .{}), proto.field_of(FieldNumber.took, .message, .{}),
        proto.field_of(FieldNumber.at, .message, .{}),     proto.field_of(FieldNumber.leaf, .message, .{}),
    } };
};

const scope: Scope = .{ .types = &.{*const Message} };

/// Expressions that together hold each kind of part, each family of operators, a function of
/// each table, each macro, and a field of each kind of `Message`.
const reference = [_][]const u8{
    "this.name.size() < 100 && !this.name.startsWith('x') || this.name.endsWith('y')",
    "this.count % 4 == 0 || -this.count > 2 || this.count + 1 <= 10 * this.count",
    "this.ratio / 2.0 >= 1.5 && !this.ratio.isNan() && double(this.count) != this.ratio",
    "this.names.all(x, x.size() > 3) && this.names.size() < 23 && 'a' in this.names",
    "this.names.exists(x, x.contains('b')) || this.names.exists_one(x, x == this.name)",
    "this.counts.all(key, this.counts[key] >= 4) && !('k' in this.counts) && this.counts.size() != 1",
    "this.took < duration('5s') || this.took >= duration('6h') || this.at < now",
    "has(this.leaf) ? this.leaf.name.size() != 6 : this.leaf.count == 0",
    "this.name in ['a', 'b', 'c'] && [1, 2, 3].all(n, n < this.count) && this.names[0] != ''",
    "this.name.isEmail() || this.name.isIp(4) || this.name.isHostname() || string(this.name) == 'z'",
    "dyn(this.count) == 1 && int(this.name) < 5 && uint(this.count) > 2u && bool('true')",
    "[this.count, 2].map(n, n * 2).all(n, n > 1) && bytes(this.name).size() == 0 && this.leaf.count != 7",
};

/// The branches the compiler may take to type the reference expressions: the count measured
/// when the constant was written, and 2% more.
const typing_branches_max = 2_280;

test "the compiler types the reference expressions within their budget of branches" {
    comptime {
        @setEvalBranchQuota(typing_branches_max);
        for (reference) |text| {
            // The parse is a constant of its own, whose branches this evaluation does not
            // count.
            const tree = parser.tree_of(text);
            switch (check.type_of(tree, scope)) {
                .ok => {},
                .problem => |problem| @compileError(text ++ ": " ++ problem),
            }
        }
    }
}

/// The files that hold the typing of an expression and what it calls, the table's searches
/// among them. `table_once.zig` and `cel_time_literal.zig` are not: each of their functions is
/// a constant's value.
const typing_files = [_][]const u8{
    "cel_check.zig",    "cel_collection.zig", "cel_select.zig",   "cel_type.zig",      "cel_list.zig",
    "cel_function.zig", "cel_library.zig",    "cel_value.zig",    "cel_time.zig",      "cel_number.zig",
    "cel_eval.zig",     "cel_node.zig",       "../shape.zig",     "../value.zig",      "../table.zig",
    "cel_text.zig",     "cel_timestamp.zig",  "cel_duration.zig", "cel_lazy_list.zig", "cel_type_value.zig",
};

test "no file on the typing's path raises the compiler's branch quota" {
    // The name in two parts, so that this file does not hold it either.
    const builtin_name = "@setEval" ++ "BranchQuota";
    inline for (typing_files) |name| {
        try testing.expect(std.mem.indexOf(u8, @embedFile(name), builtin_name) == null);
    }
}
