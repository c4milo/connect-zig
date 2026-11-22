//! Tests of the values an expression writes: `+` of strings, bytes and lists, and `string` of
//! a number or a bool (CEL language definition, "Arithmetic Operators" and "Types and
//! Conversions").
const std = @import("std");
const testing = std.testing;
/// The build target's CPU features, which `matches` searches with in the tests.
const testing_cpu_features = @import("codec").Features.target();
const proto = @import("protobuf");
const program = @import("cel_program.zig");
const type_file = @import("cel_type.zig");
const Scope = type_file.Scope;
const Env = type_file.Env;
const Text = type_file.Text;

const Message = struct {
    name: []const u8 = "",
    data: []const u8 = "",
    count: i32 = 0,
    big: u64 = 0,
    ratio: f64 = 0,
    numbers: proto.Repeated(i32, .int32) = .{},
    pub const FieldNumber = enum(u29) { name = 1, data = 2, count = 3, big = 4, ratio = 5, numbers = 6 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),  proto.field_of(FieldNumber.data, .bytes, .{}),
        proto.field_of(FieldNumber.count, .int32, .{}),  proto.field_of(FieldNumber.big, .uint64, .{}),
        proto.field_of(FieldNumber.ratio, .double, .{}), proto.field_of(FieldNumber.numbers, .int32, .{}),
    } };
};

const scope: Scope = .{ .types = &.{*const Message} };

/// The room of the tests that read a written value, which holds each of them.
const room_len = 64;

/// The value of `text` for `message`, in a room of `room_len` octets, and the octets left
/// written once the value is known.
fn run(comptime text: []const u8, message: *const Message, room: *[room_len]u8, written: *usize) !program.Type(text, scope) {
    var held: Text = .{ .room = room };
    var env: Env = .{ .cpu_features = &testing_cpu_features, .text = &held };
    const value = try program.run(text, scope, .{message}, &env);
    written.* = held.len;
    return value;
}

fn expect_true(comptime text: []const u8, message: *const Message) !void {
    var room: [room_len]u8 = undefined;
    var written: usize = 0;
    try testing.expect(try run(text, message, &room, &written));
    // A bool holds no text, so the expression gives back each octet it wrote.
    try testing.expectEqual(@as(usize, 0), written);
}

/// The numbers of `sample`, which the expected texts state too.
const count = -26;
const big = 255;
const sample: Message = .{ .name = "ada", .data = "\x01\x02", .count = count, .big = big, .ratio = 2.5 };

test "+ joins two strings and two bytes values" {
    try expect_true("this.name + '!' == 'ada!' && '' + this.name == 'ada' && this.name + '' == 'ada'", &sample);
    try expect_true("(this.name + ' ' + this.name).size() == 7 && (this.name + this.name).startsWith('adaa')", &sample);
    try expect_true("b'\\x00' + bytes(this.data) == b'\\x00\\x01\\x02' && (bytes(this.data) + b'').size() == 2", &sample);
    var room: [room_len]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqualStrings("ada, ada", try run("this.name + ', ' + this.name", &sample, &room, &written));
    // Each part is written once: the second `+` writes after the first.
    try testing.expectEqual(@as(usize, "ada, ada".len), written);
}

test "string writes an int, a uint, a double and a bool" {
    try expect_true("string(this.count) == '-26' && string(this.big) == '255' && string(7u) == '7'", &sample);
    try expect_true("string(this.ratio) == '2.5' && string(1e6) == '1e+06' && string(100.0) == '100'", &sample);
    try expect_true("string(true) == 'true' && string(this.count < 0) == 'true'", &sample);
    try expect_true("'n=' + string(this.count) == 'n=-26' && string(this.count).size() == 3", &sample);
}

test "+ joins two lists, and a list literal with another stays a literal" {
    const message: Message = .{ .numbers = .of(&.{ 4, 5 }) };
    try expect_true("(this.numbers + this.numbers).size() == 4 && (this.numbers + [9])[2] == 9", &message);
    try expect_true("([1, 2] + [3]).size() == 3 && 3 in [1] + [3] && (this.numbers + [9]).all(n, n > 3)", &message);
}

test "a macro gives back the text each element's expression wrote" {
    // Each element writes three octets, more than the room holds for all of them at once.
    const many = [_]i32{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 };
    const message: Message = .{ .numbers = .of(&many) };
    try expect_true("this.numbers.all(n, string(n) + '!' != '')", &message);
    try expect_true("this.numbers.map(n, string(n) + '!').all(s, s.size() == 3)", &message);
    // A filter that leaves out each element but the last reads them all in one step.
    try expect_true("this.numbers.map(n, string(n) + '!').filter(s, s == '32!').size() == 1", &message);
    try expect_true("'32!' in this.numbers.map(n, string(n) + '!') && this.numbers.map(n, string(n) + '!')[22] == '32!'", &message);
    // `==` of two lists reads the two elements at each place, and gives back their text.
    try expect_true("this.numbers.map(n, string(n) + '!') == this.numbers.map(m, string(m) + '!')", &message);
    try expect_true("this.numbers.map(n, string(n) + '!').map(s, s.size()) == this.numbers.map(n, 3)", &message);
}

test "text past the room fails the expression" {
    var room: [room_len]u8 = undefined;
    var written: usize = 0;
    const long: Message = .{ .name = "a" ** room_len };
    try testing.expectError(error.ReportFull, run("this.name + '!' == ''", &long, &room, &written));
    var none: Env = .{ .cpu_features = &testing_cpu_features };
    try testing.expectError(error.ReportFull, program.run("string(this.count) == ''", scope, .{&sample}, &none));
}

fn expect_problem(comptime text: []const u8, comptime expected: []const u8) !void {
    const problem = comptime program.problem_of(text, scope);
    try testing.expectEqualStrings("`" ++ text ++ "`: " ++ expected, problem orelse return error.TestExpectedProblem);
}

test "a + of two types the module does not join is a problem of the build" {
    try expect_problem("this.name + b'a'", "found no matching overload for `+` applied to (string, bytes)");
    try expect_problem("this.numbers + ['a']", "found no matching overload for `+` applied to (list(int), list(string))");
}
