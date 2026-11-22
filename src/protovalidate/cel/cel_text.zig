//! The CEL values an expression writes as it runs: `+` of two strings or two bytes values,
//! `string` of a number or a bool (CEL language definition, "Arithmetic Operators" and "Types
//! and Conversions"), and
//! `+` of two lists. A string and a bytes value are written into the room that `Env.text`
//! gives, the free part of the report's storage, so the library holds no buffer of its own. A
//! list is joined as it is read, and needs no room.
//!
//! Text that a part of an expression no longer needs is given back: a comparison, a `size` or
//! any other part whose value holds no text frees what it wrote once its value is known.
const std = @import("std");
const proto = @import("protobuf");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const list_file = @import("cel_list.zig");
const lazy = @import("cel_lazy_list.zig");
const constants = @import("../constants.zig");
const timestamp_file = @import("cel_timestamp.zig");
const duration_file = @import("cel_duration.zig");
const Node = node_file.Node;
const Env = type_file.Env;
const Error = type_file.Error;
const Text = type_file.Text;
const Bytes = type_file.Bytes;

/// The type of `left + right` for a string, a bytes value or a list, or null. Two lists join
/// when their elements are of one type; two list literals join into one literal.
pub fn Concatenated(comptime L: type, comptime R: type) ?type {
    if (L == []const u8 or L == Bytes) return if (L == R) L else null;
    if (!list_file.is_list(L) or !list_file.is_list(R)) return null;
    if (list_file.ElementOf(L) != list_file.ElementOf(R)) return null;
    if (@typeInfo(L) == .array and @typeInfo(R) == .array) return [@typeInfo(L).array.len + @typeInfo(R).array.len]list_file.ElementOf(L);
    return lazy.Joined(L, R);
}

/// `left + right`: a string or a bytes value written into the room, or two lists joined.
pub fn concat(left: anytype, right: anytype, env: *Env) Error!Concatenated(@TypeOf(left), @TypeOf(right)).? {
    const L = @TypeOf(left);
    if (comptime L == []const u8) return join(left, right, env);
    if (comptime L == Bytes) return .{ .octets = try join(left.octets, right.octets, env) };
    if (comptime @typeInfo(L) == .array and @typeInfo(@TypeOf(right)) == .array) return left ++ right;
    return .{ .left = left, .right = right };
}

/// The octets of `left` and then `right`. When `left` is the last text written, `right` is
/// written after it, and nothing is copied twice: `a + b + c` writes each part once.
fn join(left: []const u8, right: []const u8, env: *Env) Error![]const u8 {
    if (right.len == 0) return left;
    if (left.len == 0) return right;
    const text = env.text orelse return error.ReportFull;
    const start = if (ends_where_writes_go(text, left)) text.len - left.len else start: {
        const start = text.len;
        try text.write(left);
        break :start start;
    };
    try text.write(right);
    return text.room[start..text.len];
}

/// Whether `octets` lie in `text`'s room and end where its next octet goes.
fn ends_where_writes_go(text: *const Text, octets: []const u8) bool {
    const room_start = @intFromPtr(text.room.ptr);
    const octets_start = @intFromPtr(octets.ptr);
    return octets_start >= room_start and octets_start + octets.len == room_start + text.len;
}

/// Whether `string` of a `T` is written here: an int, a uint, a double, a bool, a timestamp
/// or a duration.
pub fn converts(comptime T: type) bool {
    return T == i64 or T == u64 or T == f64 or T == bool or T == proto.wkt.Timestamp or T == proto.wkt.Duration;
}

/// `string(value)`: "converts integer values to base 10 representation", a bool to "true" or
/// "false", and a double as cel-go writes it (`format_double`).
pub fn to_string(value: anytype, env: *Env) Error![]const u8 {
    const T = @TypeOf(value);
    if (comptime T == bool) return if (value) "true" else "false";
    const text = env.text orelse return error.ReportFull;
    const start = text.len;
    if (comptime T == f64) {
        try format_double(value, text);
    } else if (comptime T == proto.wkt.Timestamp) {
        try timestamp_file.write(value, text);
    } else if (comptime T == proto.wkt.Duration) {
        try duration_file.write(value, text);
    } else {
        const written = std.fmt.bufPrint(text.unwritten(), "{d}", .{value}) catch return text.overflow();
        text.len += written.len;
    }
    return text.room[start..text.len];
}

/// The longest text of a double in Zig's shortest scientific form: a sign, 17 digits, a point,
/// an `e` and a sign and three digits of exponent.
const scientific_len_max = 32;
/// Go's `strconv.FormatFloat(d, 'g', -1, 64)`, which cel-go's `string(double)` calls, writes a
/// double with an exponent past this one, or under `fixed_exponent_min`, in scientific form.
const fixed_exponent_max = 5;
const fixed_exponent_min = -4;
/// Go writes an exponent of at least two digits.
const exponent_digits_min = 2;

/// A double as Go's `strconv.FormatFloat(d, 'g', -1, 64)` writes it: the fewest digits that
/// read back as the double, in fixed form for an exponent of -4 to 5, as in `1.5` and `100000`,
/// and in scientific form past it, as in `1e+06` and `1.5e-05`. CEL language definition,
/// "Types and Conversions", says only that `string` "converts a double to a string"
/// (docs/specs/README.md).
fn format_double(value: f64, text: *Text) Error!void {
    if (std.math.isNan(value)) return text.write("NaN");
    if (std.math.isInf(value)) return text.write(if (value > 0) "+Inf" else "-Inf");
    var scientific: [scientific_len_max]u8 = undefined;
    const shortest = std.fmt.bufPrint(&scientific, "{e}", .{value}) catch unreachable;
    const parts = Scientific.of(shortest);
    if (parts.negative) try text.write("-");
    if (parts.exponent > fixed_exponent_max or parts.exponent < fixed_exponent_min) return write_scientific(parts, text);
    return write_fixed(parts, text);
}

/// A double's shortest digits and the power of ten of its first one.
const Scientific = struct {
    negative: bool,
    /// The first digit, then the digits after the point, with no point.
    first: u8,
    rest: []const u8,
    exponent: i32,

    /// The parts of Zig's `{e}` of a double, as in `-1.25e-3`.
    fn of(shortest: []const u8) Scientific {
        const negative = shortest[0] == '-';
        const unsigned = if (negative) shortest[1..] else shortest;
        const e = std.mem.indexOfScalar(u8, unsigned, 'e').?;
        const mantissa = unsigned[0..e];
        // The digits after the first one follow a point.
        const rest = if (mantissa.len > 1) mantissa["1.".len..] else "";
        const exponent = std.fmt.parseInt(i32, unsigned[e + 1 ..], constants.decimal_base) catch unreachable;
        return .{ .negative = negative, .first = mantissa[0], .rest = rest, .exponent = exponent };
    }
};

fn write_scientific(parts: Scientific, text: *Text) Error!void {
    try text.write(&.{parts.first});
    if (parts.rest.len != 0) {
        try text.write(".");
        try text.write(parts.rest);
    }
    try text.write(if (parts.exponent < 0) "e-" else "e+");
    const written = std.fmt.bufPrint(text.unwritten(), "{d:0>[1]}", .{ @abs(parts.exponent), exponent_digits_min }) catch return text.overflow();
    text.len += written.len;
}

/// The digits with the point where the exponent puts it, and zeros to fill the places before
/// or after them.
fn write_fixed(parts: Scientific, text: *Text) Error!void {
    if (parts.exponent < 0) {
        try text.write("0.");
        for (0..@abs(parts.exponent) - 1) |_| try text.write("0");
        try text.write(&.{parts.first});
        return text.write(parts.rest);
    }
    const whole: usize = @intCast(parts.exponent);
    try text.write(&.{parts.first});
    try text.write(parts.rest[0..@min(whole, parts.rest.len)]);
    if (whole > parts.rest.len) {
        for (0..whole - parts.rest.len) |_| try text.write("0");
    }
    if (parts.rest.len > whole) {
        try text.write(".");
        try text.write(parts.rest[whole..]);
    }
}

/// Whether `node` may write text as it runs: a `+`, a `string` or a `format` in it. A `+` of
/// two numbers counts too, which costs one saved length.
pub fn writes(comptime node: *const Node) bool {
    return Writes(node).value;
}

/// The compiler answers `writes` of each part once: each part's answer reads its children's.
fn Writes(comptime node: *const Node) type {
    return struct {
        const value = writes_in(node);
    };
}

fn writes_in(comptime node: *const Node) bool {
    return switch (node.*) {
        .binary => |binary| binary.op == .add or writes(binary.left) or writes(binary.right),
        .unary => |unary| writes(unary.of),
        .select => |select| writes(select.of),
        .index => |index| writes(index.of) or writes(index.at),
        .conditional => |conditional| writes(conditional.condition) or writes(conditional.then) or writes(conditional.otherwise),
        .call => |call| call.function == .string or call.function == .format or (call.target != null and writes(call.target.?)) or any_writes(call.arguments),
        .list => |elements| any_writes(elements),
        else => false,
    };
}

fn any_writes(comptime nodes: []const Node) bool {
    for (nodes) |*node| {
        if (writes(node)) return true;
    }
    return false;
}

/// Whether a value of type `T` holds no text the room keeps: a bool, a number, null, a
/// timestamp, a duration or a message, or a wrapper of one.
pub fn holds_no_text(comptime T: type) bool {
    if (@typeInfo(T) == .optional) return holds_no_text(@typeInfo(T).optional.child);
    if (type_file.is_message(T)) return true;
    return switch (T) {
        bool, i64, u64, f64, type_file.Null, type_file.Failing, proto.wkt.Timestamp, proto.wkt.Duration => true,
        @import("cel_type_value.zig").TypeValue => true,
        else => false,
    };
}

/// Whether a list of `L` writes text for its elements as it is read: a `map` whose values are
/// text it writes, or a list made from one. Whoever reads such a list frees each element's
/// text once it is done with the element. The list cannot: `format` writes between two reads.
pub fn writes_elements(comptime L: type) bool {
    return @typeInfo(L) == .@"struct" and @hasDecl(L, "writes_text") and L.writes_text;
}

/// The text written before the next element of a list of `L` is read.
pub fn mark_element(comptime L: type, env: *const Env) usize {
    return if (comptime writes_elements(L)) mark(env) else 0;
}

/// Frees the text the element read after `mark_element` wrote, for a list that writes any.
pub fn free_element(comptime L: type, env: *Env, written: usize) void {
    if (comptime writes_elements(L)) free(env, written);
}

/// The length of the text written so far, which `free` gives back to.
pub fn mark(env: *const Env) usize {
    const text = env.text orelse return 0;
    return text.len;
}

/// Frees the text written since `written`: no value still read holds it.
pub fn free(env: *Env, written: usize) void {
    const text = env.text orelse return;
    std.debug.assert(written <= text.len);
    text.len = written;
}

const testing = std.testing;

fn expect_double(value: f64, expected: []const u8) !void {
    var room: [scientific_len_max]u8 = undefined;
    var text: Text = .{ .room = &room };
    try format_double(value, &text);
    try testing.expectEqualStrings(expected, room[0..text.len]);
}

test "a double is written as Go's FormatFloat writes it with 'g' and the fewest digits" {
    try expect_double(1.5, "1.5");
    try expect_double(100, "100");
    try expect_double(100000, "100000");
    try expect_double(1e6, "1e+06");
    try expect_double(1234567, "1.234567e+06");
    try expect_double(-2.25, "-2.25");
    try expect_double(0.0001, "0.0001");
    try expect_double(0.00001, "1e-05");
    try expect_double(1.5e-7, "1.5e-07");
    try expect_double(1e300, "1e+300");
    try expect_double(0.1, "0.1");
    try expect_double(0, "0");
    try expect_double(-0.0, "-0");
    try expect_double(123.456, "123.456");
    try expect_double(std.math.nan(f64), "NaN");
    try expect_double(std.math.inf(f64), "+Inf");
    try expect_double(-std.math.inf(f64), "-Inf");
}

test "a text that ends where the room's next octet goes grows in place" {
    var room: [scientific_len_max]u8 = undefined;
    var text: Text = .{ .room = &room };
    var env: Env = .{ .text = &text };
    const ab = try join("a", "b", &env);
    const abc = try join(ab, "c", &env);
    try testing.expectEqualStrings("abc", abc);
    // "ab" was written once, and "c" after it.
    try testing.expectEqual(@as(usize, "abc".len), text.len);
    const again = try join(ab, "d", &env);
    try testing.expectEqualStrings("abd", again);
    try testing.expectEqual(@as(usize, "abc".len + "abd".len), text.len);
    // A side that is empty is the other side, and writes nothing.
    try testing.expectEqualStrings("x", try join("", "x", &env));
    try testing.expectEqualStrings("x", try join("x", "", &env));
    try testing.expectEqual(@as(usize, "abc".len + "abd".len), text.len);
    var none: Env = .{};
    try testing.expectError(error.ReportFull, join("a", "b", &none));
}
