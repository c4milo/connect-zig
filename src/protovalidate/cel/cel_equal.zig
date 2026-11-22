//! `==` and `!=` of two values that may be lists. "Two `list` values equal if their entries at
//! each ordinal are equal" (CEL language definition, "Lists and Maps"): the lists have one
//! length, and each element equals the element at its place in the other. Any other two values
//! are equal as `cel_value.zig` says.
const std = @import("std");
const proto = @import("protobuf");
const type_file = @import("cel_type.zig");
const value_file = @import("cel_value.zig");
const list_file = @import("cel_list.zig");
const text_file = @import("cel_text.zig");
const Env = type_file.Env;
const Error = type_file.Error;
const NoElement = type_file.NoElement;

/// Whether `==` and `!=` take a `L` and a `R`: two lists whose elements `==` takes, or two
/// values that `cel_value.zig` says it takes. `[]` holds no element, so its elements are taken
/// with any other list's: "the type-checker uses homogeneous equality" (CEL language definition,
/// "Equality").
pub fn equatable(comptime L: type, comptime R: type) bool {
    if (list_file.is_list(L) and list_file.is_list(R)) return elements_equatable(list_file.ElementOf(L), list_file.ElementOf(R));
    return value_file.equatable(L, R);
}

fn elements_equatable(comptime L: type, comptime R: type) bool {
    return L == NoElement or R == NoElement or equatable(L, R);
}

/// Whether a `L` and a `R` may be equal as an expression runs: two lists, whose elements are
/// compared as they run, or two values `cel_value.zig` says may be equal.
pub fn equal_as_they_run(comptime L: type, comptime R: type) bool {
    if (list_file.is_list(L) and list_file.is_list(R)) return true;
    return value_file.equal_as_they_run(L, R);
}

/// `left == right`. Two lists are read element by element, which may fail as a read of either
/// does, and two values of unlike types are not equal.
pub fn equal(left: anytype, right: anytype, env: *Env) Error!bool {
    const L = @TypeOf(left);
    const R = @TypeOf(right);
    if (comptime list_file.is_list(L) and list_file.is_list(R)) return equal_lists(left, right, env);
    if (comptime !value_file.equal_as_they_run(L, R)) return false;
    return value_file.equal(left, right);
}

fn equal_lists(left: anytype, right: anytype, env: *Env) Error!bool {
    const L = @TypeOf(left);
    const R = @TypeOf(right);
    if (lengths_differ(left, right)) return false;
    // The two elements, and the text either writes, are read here alone.
    const writes = comptime text_file.writes_elements(L) or text_file.writes_elements(R);
    var lefts = list_file.iterate(left);
    var rights = list_file.iterate(right);
    for (0..proto.constants.limits.elements_max) |_| {
        const written = if (writes) text_file.mark(env) else 0;
        defer if (writes) text_file.free(env, written);
        const one = try lefts.next(env);
        const other = try rights.next(env);
        if (one == null or other == null) return one == null and other == null;
        if (!try equal(one.?, other.?, env)) return false;
    }
    unreachable;
}

/// Whether two lists' lengths are known and differ. A list literal's length and a stored
/// list's are known, so two such lists of two lengths read no element.
fn lengths_differ(left: anytype, right: anytype) bool {
    const left_len = known_len(left) orelse return false;
    const right_len = known_len(right) orelse return false;
    return left_len != right_len;
}

/// A list's length when it is known without a read of its elements, or null.
fn known_len(list: anytype) ?usize {
    const T = @TypeOf(list);
    if (comptime @typeInfo(T) == .array) return @typeInfo(T).array.len;
    if (comptime @hasDecl(T, "stored")) {
        if (list.stored()) |items| return items.len;
    }
    return null;
}

const testing = std.testing;
/// The build target's CPU features, which `matches` searches with in the tests.
const testing_cpu_features = @import("codec").Features.target();
const program = @import("cel_program.zig");

const Message = struct {
    numbers: proto.Repeated(i32, .int32) = .{},
    names: proto.Repeated([]const u8, .string) = .{},
    pub const FieldNumber = enum(u29) { numbers = 1, names = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.numbers, .int32, .{}), proto.field_of(FieldNumber.names, .string, .{}),
    } };
};

const scope: type_file.Scope = .{ .types = &.{*const Message} };

fn run(comptime text: []const u8, message: *const Message) Error!program.Type(text, scope) {
    var env: Env = .{ .cpu_features = &testing_cpu_features };
    return program.run(text, scope, .{message}, &env);
}

fn expect_true(comptime text: []const u8, message: *const Message) !void {
    try testing.expect(try run(text, message));
}

fn expect_problem(comptime text: []const u8, comptime expected: []const u8) !void {
    const problem = comptime program.problem_of(text, scope);
    try testing.expectEqualStrings("`" ++ text ++ "`: " ++ expected, problem orelse return error.TestExpectedProblem);
}

const two = 2;
const four = 4;
const sample: Message = .{ .numbers = .of(&.{ two, four }), .names = .of(&.{ "ann", "bob" }) };
/// Room for `sample` encoded.
const encoded_len_max = 32;

test "two lists are equal when the elements at each place are" {
    try expect_true("[1, 2] == [1, 2] && [1, 2] != [2, 1] && [1] != [1, 2] && [1, 2] != [1]", &sample);
    try expect_true("['a'] == ['a'] && ['case'] != ['cAse'] && [[1], [2]] == [[1], [2]] && [[1]] != [[2]]", &sample);
    try expect_true("this.numbers == [2, 4] && [2, 4] == this.numbers && this.numbers != [2, 4, 6]", &sample);
    try expect_true("this.names == ['ann', 'bob'] && this.numbers.map(n, n * 2) == [4, 8] && this.numbers.filter(n, n > 2) == [4]", &sample);
    try expect_true("this.numbers == this.numbers && [2] in [[1], [2]] && !([3] in [[1], [2]])", &sample);
    // A filter's length is known once it is read: a list longer than the other is not equal.
    try expect_true("this.numbers.filter(n, n > 0) != [2] && [2] != this.numbers.filter(n, n > 0)", &sample);
    // Two lists of known lengths that differ read no element.
    var counted: Env = .{ .cpu_features = &testing_cpu_features, .steps = 0 };
    try testing.expect(try program.run("this.numbers != [2, 4, 6] && [1] != [1, 2]", scope, .{&sample}, &counted));
    var octets: [encoded_len_max]u8 = undefined;
    const viewed = try proto.decode(Message, try proto.encode(Message, &sample, &octets));
    try testing.expect(viewed.numbers.items.len == 0 and viewed.numbers.view.bytes.len != 0);
    try expect_true("this.numbers == [2, 4] && this.numbers != [2] && this.names == ['ann', 'bob']", &viewed);
    // Behind `dyn` the elements are compared as they run: numbers of two types may be equal.
    try expect_true("dyn([1, 2]) == [1u, 2u] && dyn([1]) != ['1'] && dyn([1]) != 1 && dyn([]) != null", &sample);
    try expect_problem("[1] == [1.0]", "found no matching overload for `==` applied to (list(int), list(double))");
    try expect_problem("[1] == 1", "found no matching overload for `==` applied to (list(int), int)");
}

test "the empty list literal holds no element, and is a list of any type" {
    try expect_true("[] == [] && !([] != []) && [] != [1] && [1] != [] && [[]] == [[]] && this.numbers != []", &sample);
    try expect_true("size([]) == 0 && !(7 in []) && !('a' in []) && type([]) == list", &sample);
    try expect_true("[] + [3, 4] == [3, 4] && [1, 2] + [] == [1, 2] && ([] + []).size() == 0", &sample);
    try expect_true("[].all(e, e > 0) && ![].exists(e, e == 2) && ![].exists_one(a, a == 7)", &sample);
    try expect_true("[].map(n, n / 2) == [] && [].filter(n, n % 2 == 0).size() == 0", &sample);
    try testing.expectError(error.Unevaluable, run("[][0] == 1", &sample));
}
