//! Tests of CEL's `format` (CEL strings extension, "string.format(list) -> string"): each
//! conversion, the cases the text states, and the problems that stop the build.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const program = @import("cel_program.zig");
const type_file = @import("cel_type.zig");
const Scope = type_file.Scope;
const Env = type_file.Env;
const Text = type_file.Text;
const Error = type_file.Error;

const Message = struct {
    name: []const u8 = "",
    data: []const u8 = "",
    count: i32 = 0,
    big: u64 = 0,
    ratio: f64 = 0,
    on: bool = false,
    wrapped: ?proto.wkt.StringValue = null,
    pub const FieldNumber = enum(u29) { name = 1, data = 2, count = 3, big = 4, ratio = 5, on = 6, wrapped = 7 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),     proto.field_of(FieldNumber.data, .bytes, .{}),
        proto.field_of(FieldNumber.count, .int32, .{}),     proto.field_of(FieldNumber.big, .uint64, .{}),
        proto.field_of(FieldNumber.ratio, .double, .{}),    proto.field_of(FieldNumber.on, .bool, .{}),
        proto.field_of(FieldNumber.wrapped, .message, .{}),
    } };
};

const scope: Scope = .{ .types = &.{*const Message} };

/// The longest text a test formats.
const text_len_max = 256;

/// Requires `text` to give `expected` for `message`, in a room of `text_len_max` octets.
fn expect_text(comptime text: []const u8, message: *const Message, expected: []const u8) !void {
    var room: [text_len_max]u8 = undefined;
    var written: Text = .{ .room = &room };
    var env: Env = .{ .text = &written };
    try testing.expectEqualStrings(expected, try program.run(text, scope, .{message}, &env));
}

fn expect_problem(comptime text: []const u8, comptime expected: []const u8) !void {
    const problem = comptime program.problem_of(text, scope);
    try testing.expectEqualStrings("`" ++ text ++ "`: " ++ expected, problem orelse return error.TestExpectedProblem);
}

/// The numbers of `sample`, which the expected texts state too.
const count = -26;
const big = 255;
const sample: Message = .{ .name = "ada", .data = "a\xff\xfeb\xc3", .count = count, .big = big, .ratio = 2.5, .on = true };

test "s writes each type as its text states" {
    try expect_text("'name: `%s`'.format([this.name])", &sample, "name: `ada`");
    try expect_text("'%s %s %s %s'.format([this.on, this.count, this.big, this.ratio])", &sample, "true -26 255 2.5");
    try expect_text("'%s, %s, %s'.format([3.0, 0.1, 1e21])", &sample, "3, 0.1, 1000000000000000000000");
    try expect_text("'%s %s %s'.format([0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0])", &sample, "NaN Infinity -Infinity");
    try expect_text("'%s'.format([null])", &sample, "null");
    try expect_text("'%s'.format([[1, 2, 3]])", &sample, "[1, 2, 3]");
    try expect_text("'%s, %s'.format([duration('8747s'), duration('-1.5s')])", &sample, "8747s, -1.5s");
    try expect_text("'%s'.format([timestamp('2009-11-10T23:00:00.5+01:00')])", &sample, "2009-11-10T22:00:00.5Z");
    try expect_text("'%s %s'.format([type(1), dyn(duration('1s'))])", &sample, "int 1s");
    try expect_text("'%%%s%% and %%'.format([this.count])", &sample, "%-26% and %");
    try expect_text("'%%'.format([])", &sample, "%");
    try expect_text("'%s'.format([['a', 'b']])", &sample, "[a, b]");
    try expect_text("'no conversion'.format([])", &sample, "no conversion");
}

test "s of bytes writes one replacement for each run of octets that are not UTF-8" {
    try expect_text("'%s'.format([this.data])", &sample, "a\u{fffd}b\u{fffd}");
    try expect_text("'%s'.format([b'caf\\xc3\\xa9'])", &sample, "caf\u{e9}");
}

test "a wrapper writes its value, or null" {
    try expect_text("'%s'.format([this.wrapped])", &sample, "null");
    const wrapped: Message = .{ .wrapped = .{ .value = "held" } };
    try expect_text("'%s'.format([this.wrapped])", &wrapped, "held");
}

test "d, x and X write numbers, and x and X each octet of a text" {
    try expect_text("'%d %d'.format([this.count, this.big])", &sample, "-26 255");
    try expect_text("'%x %X %x'.format([this.count, this.big, 255u])", &sample, "-1a FF ff");
    try expect_text("'%x %X'.format(['Az', b'\\x00\\xff'])", &sample, "417a 00FF");
    try expect_text("'%x'.format([-9223372036854775807 - 1])", &sample, "-8000000000000000");
}

test "a format inside a value writes its text first, and the outer one after it" {
    try expect_text("'(%s)'.format(['<%s>'.format([this.name])])", &sample, "(<ada>)");
    try expect_text("this.count < 0 ? 'negative: %d'.format([this.count]) : ''", &sample, "negative: -26");
}

test "a text past the room fails with ReportFull" {
    // "ada!" takes 4 octets: a room of 4 holds it, and a room of 3 does not.
    var room: [4]u8 = undefined;
    var whole: Text = .{ .room = &room };
    var fits: Env = .{ .text = &whole };
    try testing.expectEqualStrings("ada!", try program.run("'%s!'.format([this.name])", scope, .{&sample}, &fits));
    var part: Text = .{ .room = room[0..3] };
    var short: Env = .{ .text = &part };
    try testing.expectError(error.ReportFull, program.run("'%s!'.format([this.name])", scope, .{&sample}, &short));
    var none: Env = .{};
    try testing.expectError(error.ReportFull, program.run("'%d'.format([this.count])", scope, .{&sample}, &none));
}

test "a format the module cannot read stops the build" {
    try expect_problem("this.name.format([1])", "the text of `format` is no string literal, and this module reads it as it compiles");
    try expect_problem("'%s'.format(this.name)", "the values of `format` are no list literal, and this module types each one as it compiles");
    try expect_problem("'%s %s'.format([1])", "the text of `format` has another count of conversions than its list has values");
    try expect_problem("'%f'.format([1.5])", "`format` does not read the conversion `%f` yet");
    try expect_problem("'50%'.format([])", "the text of `format` ends with a `%`");
    try expect_problem("'%d'.format(['a'])", "`%d` of `format` takes no string");
    try expect_problem("'%x'.format([true])", "`%x` of `format` takes no bool");
    try expect_problem("format('%s', [1])", "`format` is called on its text: `'...'.format([...])`");
}
