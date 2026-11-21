//! What the compiler computes once for a message type: where its table holds each field's
//! entry, whether its fields' numbers rise, and an enum of its fields' names.
//!
//! Each function here reads every field of a message, so it raises the compiler's branch
//! quota. The compiler keeps no answer of a function that raises the quota, and none of a
//! function that calls one (docs/performance.md, "The compiler's time"). So each function
//! here is the value of a constant of `table.zig`, which the compiler computes once, and no
//! other code calls it. No other file that the typing of a CEL expression reads raises the
//! quota: a test of `cel/cel_cost_test.zig` requires it.
const std = @import("std");
const constants = @import("constants.zig");
const table = @import("table.zig");

/// For each field of `T`, by its place in the descriptor, the place of its entry in the table
/// of `T`, or none.
pub fn places_of(comptime T: type) [T.protobuf.fields.len]?usize {
    comptime {
        @setEvalBranchQuota(constants.eval_branches_per_rule * (T.protobuf.fields.len + 1));
        var places = [_]?usize{null} ** T.protobuf.fields.len;
        for (table.of(T).fields, 0..) |entry, at| {
            const place = table.place_of(T, entry.number) orelse continue;
            // A field's first entry is its entry: `rules_error` refuses a second one.
            if (places[place] == null) places[place] = at;
        }
        return places;
    }
}

/// Whether the numbers of the fields of `T` rise.
pub fn numbers_rise(comptime T: type) bool {
    comptime {
        @setEvalBranchQuota(constants.eval_branches_per_rule * (T.protobuf.fields.len + 1));
        var previous: u32 = 0;
        for (T.protobuf.fields) |field| {
            if (field.number <= previous) return false;
            previous = field.number;
        }
        return true;
    }
}

/// An enum with one member for each field of `T`, named by the field's name of `kind`, whose
/// value is the field's place in the descriptor.
pub fn names_enum(comptime T: type, comptime kind: table.NameKind) type {
    comptime {
        const fields = T.protobuf.fields;
        @setEvalBranchQuota(constants.eval_branches_per_rule * (fields.len + 1));
        var names = [_][]const u8{""} ** fields.len;
        for (fields, 0..) |field, place| names[place] = if (kind == .zig) field.name else field.proto_name;
        const kept = names;
        return @Enum(u32, .exhaustive, &kept, &std.simd.iota(u32, fields.len));
    }
}
