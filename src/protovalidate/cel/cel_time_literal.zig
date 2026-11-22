//! The timestamp or the duration that an expression's literal text names, as in
//! `timestamp('2023-12-25T00:00:00Z')` and `duration('90s')`, and the text of `string` of a
//! constant. The compiler computes each once, as a constant's value with a branch quota of its
//! own. The file is not on the typing's path, whose functions raise no quota, so the compiler
//! keeps their answers (docs/performance.md, "The compiler's time").
const proto = @import("protobuf");
const constants = @import("../constants.zig");
const timestamp_file = @import("cel_timestamp.zig");
const duration_file = @import("cel_duration.zig");
const type_file = @import("cel_type.zig");
const codec = @import("codec");
const text_file = @import("cel_text.zig");

/// The longest text of `string` of a constant: a double in scientific form, or a timestamp of
/// RFC 3339 with nine digits of fraction.
const text_len_max = "-2023-12-25T00:00:00.123456789Z".len;

/// The text of `string(operand)` for a constant `operand`, a number, a bool, a timestamp or a
/// duration.
pub fn Text(comptime operand: anytype) type {
    return struct {
        pub const value: []const u8 = text: {
            @setEvalBranchQuota(constants.cel_branches_per_octet * text_len_max);
            var room: [text_len_max]u8 = undefined;
            var written: type_file.Text = .{ .room = &room };
            // A literal's text calls no `matches`, so it searches with no feature.
            const features: codec.Features = .none();
            var env: type_file.Env = .{ .cpu_features = &features, .text = &written };
            const text = text_file.to_string(operand, &env) catch unreachable;
            const copy = text[0..text.len].*;
            break :text &copy;
        };
    };
}

/// Whether `text` names a `T`, which the typing asks once for each literal.
pub fn Valid(comptime T: type, comptime text: []const u8) type {
    return struct {
        pub const value: bool = value: {
            @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
            break :value parse(T, text) != null;
        };
    };
}

/// The `T` that `text`, a literal the typing found valid, names.
pub fn Literal(comptime T: type, comptime text: []const u8) type {
    return struct {
        pub const value: T = value: {
            @setEvalBranchQuota(constants.cel_branches_per_octet * (text.len + 1));
            break :value parse(T, text).?;
        };
    };
}

/// The `T` that `text` names, or null: a duration's text, or a timestamp's of RFC 3339.
pub fn parse(comptime T: type, text: []const u8) ?T {
    if (comptime T == proto.wkt.Duration) return duration_file.parse(text);
    return timestamp_file.parse(text);
}
