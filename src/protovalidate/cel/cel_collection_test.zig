//! Tests of lists and maps in an expression: a message's repeated fields and maps as CEL
//! values, with `size`, `in`, an index and the macros.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const constants = @import("../constants.zig");
const program = @import("cel_program.zig");
const type_file = @import("cel_type.zig");
const Scope = type_file.Scope;
const Env = type_file.Env;
const Error = type_file.Error;

const Item = struct {
    a: i32 = 0,
    pub const FieldNumber = enum(u29) { a = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Item", .fields = &.{proto.field_of(FieldNumber.a, .int32, .{})} };
};

const CountsEntry = struct {
    key: []const u8 = "",
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message.CountsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

const ItemsEntry = struct {
    key: i32 = 0,
    value: ?Item = null,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message.ItemsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .int32, .{}), proto.field_of(FieldNumber.value, .message, .{}),
    } };
};

const Message = struct {
    numbers: proto.Repeated(i32, .int32) = .{},
    names: proto.Repeated([]const u8, .string) = .{},
    items: proto.Repeated(Item, .message) = .{},
    counts: proto.Repeated(CountsEntry, .message) = .{},
    by_id: proto.Repeated(ItemsEntry, .message) = .{},
    pick: i32 = 0,
    pub const FieldNumber = enum(u29) { numbers = 1, names = 2, items = 3, counts = 4, by_id = 5, pick = 6 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.numbers, .int32, .{}), proto.field_of(FieldNumber.names, .string, .{}),
        proto.field_of(FieldNumber.items, .message, .{}), proto.field_of(FieldNumber.counts, .message, .{}),
        proto.field_of(FieldNumber.by_id, .message, .{}), proto.field_of(FieldNumber.pick, .int32, .{}),
    } };
};

const scope: Scope = .{ .types = &.{*const Message} };

fn run(comptime text: []const u8, message: *const Message) Error!program.Type(text, scope) {
    var env: Env = .{};
    return program.run(text, scope, .{message}, &env);
}

fn expect_true(comptime text: []const u8, message: *const Message) !void {
    try testing.expect(try run(text, message));
}

fn expect_false(comptime text: []const u8, message: *const Message) !void {
    try testing.expect(!try run(text, message));
}

fn expect_problem(comptime text: []const u8, comptime expected: []const u8) !void {
    const problem = comptime program.problem_of(text, scope);
    try testing.expectEqualStrings("`" ++ text ++ "`: " ++ expected, problem orelse return error.TestExpectedProblem);
}

const two = 2;
const four = 4;
const six = 6;
/// A map with the key "b" twice: its last entry is the map's.
const sample: Message = .{
    .numbers = .of(&.{ two, four, six }),
    .names = .of(&.{ "ann", "bob" }),
    .items = .of(&.{ .{ .a = 1 }, .{ .a = two } }),
    .counts = .of(&.{ .{ .key = "a", .value = 1 }, .{ .key = "b", .value = four }, .{ .key = "b", .value = two } }),
    .by_id = .of(&.{ .{ .key = 1, .value = .{ .a = four } }, .{ .key = two } }),
    .pick = four,
};

test "size counts a list's elements and a map's keys" {
    try expect_true("this.numbers.size() == 3 && size(this.names) == 2 && this.items.size() == 2", &sample);
    try expect_true("this.counts.size() == 2 && this.by_id.size() == 2", &sample);
    try expect_true("this.numbers.size() == 0 && this.counts.size() == 0", &.{});
    try expect_true("uint(this.numbers.size()) >= 3u", &sample);
}

/// Room for `sample` encoded.
const encoded_len_max = 256;

test "a list read from the message's octets has the size and the elements of a stored one" {
    var octets: [encoded_len_max]u8 = undefined;
    const encoded = try proto.encode(Message, &sample, &octets);
    // `decode` leaves each repeated field a view of the octets, where `.of` stores its elements.
    const viewed = try proto.decode(Message, encoded);
    try testing.expect(viewed.numbers.items.len == 0 and viewed.numbers.view.bytes.len != 0);
    try expect_true("this.numbers.size() == 3 && size(this.names) == 2 && this.items.size() == 2", &viewed);
    try expect_true("this.numbers[0] == 2 && this.numbers[2] == 6 && this.names[1] == 'bob' && this.items[1].a == 2", &viewed);
    try testing.expectError(error.Unevaluable, run("this.numbers[3] == 0", &viewed));
    try testing.expectError(error.Unevaluable, run("this.numbers[0 - 1] == 0", &viewed));
    try expect_true("this.counts.size() == 2 && this.counts['b'] == 2", &viewed);
}

test "in finds a value among a list's elements and a map's keys" {
    try expect_true("this.pick in this.numbers && 6 in this.numbers && 'bob' in this.names", &sample);
    try expect_false("5 in this.numbers || 'cy' in this.names || this.pick in [1, 2, 3]", &sample);
    try expect_true("this.pick in [2, 4] && 'b' in this.counts && 2 in this.by_id && !('c' in this.counts)", &sample);
    try expect_false("this.pick in this.numbers", &.{ .pick = four });
    // Behind `dyn`, `in` still reads a list or a map: any other right side fails as it runs.
    try testing.expectError(error.Unevaluable, run("dyn(this.pick) in this.pick", &sample));
    try expect_true("dyn(this.pick) in this.numbers && !(dyn('four') in this.numbers) && !(dyn(4) in this.counts)", &sample);
}

test "an index takes a list's element and a map's value" {
    try expect_true("this.numbers[0] == 2 && this.numbers[2] == 6 && this.names[1] == 'bob'", &sample);
    try expect_true("this.items[1].a == 2", &sample);
    try expect_true("this.counts['a'] == 1 && this.by_id[1].a == 4", &sample);
    // The last entry of a key is the map's value, and a value that is not set is a default.
    try expect_true("this.counts['b'] == 2 && this.by_id[2].a == 0", &sample);
    try testing.expectError(error.Unevaluable, run("this.numbers[3] == 0", &sample));
    try testing.expectError(error.Unevaluable, run("this.numbers[0 - 1] == 0", &sample));
    try testing.expectError(error.Unevaluable, run("this.counts['c'] == 0", &sample));
    try expect_true("[7, 8][1] == 8", &sample);
}

test "all and exists read each element of a list, and each key of a map" {
    try expect_true("this.numbers.all(n, n % 2 == 0) && this.names.all(n, n.size() == 3)", &sample);
    try expect_false("this.numbers.all(n, n > 2)", &sample);
    try expect_true("this.numbers.exists(n, n > 4) && !this.numbers.exists(n, n > 6)", &sample);
    try expect_true("this.items.all(e, e.a > 0) && this.items.exists(e, e.a == 2)", &sample);
    try expect_true("this.counts.all(k, this.counts[k] <= 2) && this.by_id.all(k, this.by_id[k].a != 1)", &sample);
    try expect_true("this.counts.exists(k, k == 'b') && !this.counts.exists(k, k == 'c')", &sample);
    // An empty list has no element to break `all`, and none to satisfy `exists`.
    try expect_true("this.numbers.all(n, n > 100) && !this.numbers.exists(n, n < 100)", &.{});
    // A macro's variable hides the name before it, and a macro reads names outside it.
    try expect_true("this.numbers.all(n, this.numbers.exists(m, m == n) && n <= this.pick + 2)", &sample);
    try expect_true("this.numbers.exists(this, this == 6)", &sample);
    // A variable named `now` is the variable, not the time.
    try expect_true("this.numbers.all(now, now > 0)", &sample);
    // A list literal is a list: a macro reads each of its elements.
    try expect_true("[2, 4, 6].all(n, n in this.numbers) && [1, 4].exists(n, n == this.pick)", &sample);
    try expect_false("['ann', 'cy'].all(n, n in this.names) || [1, 2].exists(n, n > 2)", &sample);
    try expect_true("['ann', 'ann', 'bob'].exists_one(n, n == 'bob') && ![1, 1].exists_one(n, n == 1)", &sample);
}

test "exists_one is true for one element alone, and reads a map's repeated key once" {
    try expect_true("this.numbers.exists_one(n, n > 4)", &sample);
    try expect_false("this.numbers.exists_one(n, n > 2)", &sample);
    try expect_false("this.numbers.exists_one(n, n > 6)", &sample);
    try expect_true("this.counts.exists_one(k, k == 'b')", &sample);
    try expect_false("this.counts.exists_one(k, k != 'c')", &sample);
}

test "a macro absorbs a failing element as the logic operators do" {
    // 6 / (n - 4) fails for the element 4.
    try expect_false("this.numbers.all(n, 6 / (n - 4) > 100)", &sample);
    try expect_true("this.numbers.exists(n, 6 / (n - 4) == 3)", &sample);
    try testing.expectError(error.Unevaluable, run("this.numbers.all(n, 6 / (n - 4) < 100)", &sample));
    try testing.expectError(error.Unevaluable, run("this.numbers.exists(n, 6 / (n - 4) > 100)", &sample));
    try testing.expectError(error.Unevaluable, run("this.numbers.exists_one(n, 6 / (n - 4) == 3)", &sample));
}

test "an expression reads no more elements than its limit" {
    var numbers: [constants.compared_items_max + 1]i32 = undefined;
    for (&numbers, 0..) |*number, index| number.* = @intCast(index);
    const long: Message = .{ .numbers = .of(&numbers) };
    // One pass reads each element once, and a pass for each element reads them all again.
    try expect_true("this.numbers.all(n, n >= 0)", &long);
    try testing.expectError(error.TooManyItems, run("this.numbers.all(n, this.numbers.all(m, m >= 0 && n >= 0))", &long));
    const most: Message = .{ .numbers = .of(numbers[0 .. constants.compared_items_max - 1]) };
    try expect_true("this.numbers.all(n, this.numbers.all(m, m >= 0 && n >= 0))", &most);
}

test "a mistake with a list or a map is a problem of the build" {
    try expect_problem("this.numbers[0u]", "found no matching overload for `[]` applied to (list(int), uint)");
    try expect_problem("this.counts[1]", "found no matching overload for `[]` applied to (map(string, int), int)");
    try expect_problem("this.pick[0]", "found no matching overload for `[]` applied to (int, int)");
    try expect_problem("'a' in this.numbers", "found no matching overload for `in` applied to (string, list(int))");
    // A list holds values of its elements' type: a number of another type is no element.
    try expect_problem("4u in this.numbers", "found no matching overload for `in` applied to (uint, list(int))");
    try expect_problem("4.0 in this.numbers", "found no matching overload for `in` applied to (double, list(int))");
    try expect_problem("1 in this.pick", "found no matching overload for `in` applied to (int, int)");
    try expect_problem("this.pick.all(n, true)", "the macro `all` reads a list or a map, not a int");
    try expect_problem("this.numbers.all(n, n)", "the macro `all` takes a bool for each element, not a int");
    try expect_problem("this.numbers.all(n)", "the macro `all` takes a name and an expression");
    try expect_problem("this.numbers.all(1, true)", "the macro `all` takes a name and an expression");
    // A macro reads its target: a call of its name with no target is a call of a function.
    try expect_problem("all(this.numbers, true)", "found no matching overload for `all` applied to (list(int), bool)");
    try expect_problem("this.numbers.all(n, m > 0)", "undeclared reference to `m`");
    try expect_problem("this.numbers.filter(n, n)", "the macro `filter` takes a bool for each element, not a int");
    try expect_problem("this.numbers.map(n, n, n)", "the macro `map` takes a bool for each element, not a int");
    try expect_problem("this.pick.filter(n, true)", "the macro `filter` reads a list or a map, not a int");
    try expect_problem("this.numbers.map(n)", "the macro `map` takes a name and an expression");
    try expect_problem("this.numbers.filter(n, n > 0, n)", "the macro `filter` takes a name and an expression");
    try expect_problem("this.numbers.filter(n, m > 0)", "undeclared reference to `m`");
    try expect_problem("[1, 'a']", "a list literal holds a int and a string");
    try expect_problem("[]", "an empty list literal has no type");
    try expect_problem("this.pick.size()", "found no matching overload for `size` applied to (int)");
}

test "filter and map give a list that each read computes" {
    const message: Message = .{
        .numbers = .of(&.{ 1, 5, 2, 8 }),
        .names = .of(&.{ "ada", "", "bob" }),
        .items = .of(&.{ .{ .a = 3 }, .{ .a = 9 } }),
        .counts = .of(&.{ .{ .key = "x", .value = 1 }, .{ .key = "y", .value = 7 }, .{ .key = "x", .value = 2 } }),
        .pick = 2,
    };
    try expect_true("this.numbers.filter(n, n > 2).size() == 2 && this.numbers.filter(n, n > 2)[1] == 8", &message);
    try expect_true("this.numbers.map(n, n * 2).all(n, n % 2 == 0) && 16 in this.numbers.map(n, n * 2)", &message);
    try expect_true("!(5 in this.numbers.map(n, n * 2)) && this.numbers.map(n, n > 2, n * 10)[0] == 50", &message);
    try expect_true("this.numbers.map(n, n > 2, n * 10).size() == 2 && this.names.filter(s, s != '').size() == 2", &message);
    try expect_true("this.items.map(i, i.a).exists_one(a, a == 9) && this.items.filter(i, i.a > 5).map(i, i.a)[0] == 9", &message);
    // A predicate reads the expression's other names, and a map gives each key once.
    try expect_true("this.numbers.filter(n, n > this.pick).size() == 2", &message);
    try expect_true("this.counts.filter(k, k != '').size() == 2 && this.counts.filter(k, this.counts[k] > 1).size() == 2", &message);
    try expect_true("this.counts.map(k, this.counts[k]).all(v, v == 2 || v == 7)", &message);
    try expect_true("this.numbers.filter(n, n > 100).size() == 0 && !this.numbers.filter(n, n > 100).exists(n, true)", &message);
    // A literal's `map` keeps its length, and its `filter` is computed as it is read.
    try expect_true("[1, 2, 3].filter(n, n != 2).size() == 2 && [1, 2].map(n, n + 1)[1] == 3", &message);
    // A failure inside the list fails the read, and an index past its end fails.
    try testing.expectError(error.Unevaluable, run("this.numbers.map(n, 10 / (n - 5)).size() > 0", &message));
    try testing.expectError(error.Unevaluable, run("this.numbers.filter(n, 10 / (n - 5) > 0).size() > 0", &message));
    try testing.expectError(error.Unevaluable, run("this.numbers.filter(n, n > 2)[2] == 0", &message));
}
