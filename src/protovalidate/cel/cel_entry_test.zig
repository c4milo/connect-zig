//! Tests of a macro over a map whose expression reads the map at its variable,
//! `m.all(k, m[k] > 0)`, which binds each entry's value beside its key (`cel_entry.zig`).
const std = @import("std");
const testing = std.testing;
/// The build target's CPU features, which `matches` searches with in the tests.
const testing_cpu_features = @import("codec").Features.target();
const proto = @import("protobuf");
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
    key: []const u8 = "",
    value: ?Item = null,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message.ItemsEntry", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .string, .{}), proto.field_of(FieldNumber.value, .message, .{}),
    } };
};

/// Two maps of string keys to ints, and one of string keys to messages.
const Message = struct {
    counts: proto.Repeated(CountsEntry, .message) = .{},
    limits: proto.Repeated(CountsEntry, .message) = .{},
    items: proto.Repeated(ItemsEntry, .message) = .{},
    pub const FieldNumber = enum(u29) { counts = 1, limits = 2, items = 3 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Message", .fields = &.{
        proto.field_of(FieldNumber.counts, .message, .{}), proto.field_of(FieldNumber.limits, .message, .{}),
        proto.field_of(FieldNumber.items, .message, .{}),
    } };
};

/// `this`, and a second message, `that`.
const scope: Scope = .{ .names = &.{ "this", "that" }, .types = &.{ *const Message, *const Message } };

fn run(comptime text: []const u8, message: *const Message, that: *const Message, steps: usize) Error!bool {
    var env: Env = .{ .cpu_features = &testing_cpu_features, .steps = steps };
    return program.run(text, scope, .{ message, that }, &env);
}

/// The steps an expression may take in the tests that do not count them.
const steps_max = 64;

fn expect(comptime text: []const u8, message: *const Message, that: *const Message, expected: bool) !void {
    try testing.expectEqual(expected, try run(text, message, that, steps_max));
}

const two = 2;
const four = 4;
const seven = 7;
const nine = 9;
/// Maps with the key "b" twice: the last entry is the map's.
const sample: Message = .{
    .counts = .of(&.{ .{ .key = "a", .value = 1 }, .{ .key = "b", .value = four }, .{ .key = "b", .value = two } }),
    .limits = .of(&.{ .{ .key = "a", .value = nine }, .{ .key = "b", .value = nine } }),
    .items = .of(&.{ .{ .key = "a", .value = .{ .a = four } }, .{ .key = "b", .value = .{ .a = 1 } }, .{ .key = "b" } }),
};
const second: Message = .{ .counts = .of(&.{ .{ .key = "a", .value = seven }, .{ .key = "b", .value = seven } }) };

test "a macro reads the value of each key's last entry" {
    try expect("this.counts.all(k, this.counts[k] <= 2)", &sample, &second, true);
    try expect("this.counts.exists(k, this.counts[k] == 4)", &sample, &second, false);
    try expect("this.counts.exists_one(k, this.counts[k] == 2) && this.counts.exists_one(k, this.counts[k] < 3) == false", &sample, &second, true);
    // An earlier entry of a key that fails gives no verdict either.
    const zero_first: Message = .{ .counts = .of(&.{ .{ .key = "b", .value = 0 }, .{ .key = "b", .value = two } }) };
    try expect("this.counts.all(k, 4 / this.counts[k] > 1) && !this.counts.exists(k, 4 / this.counts[k] > 2)", &zero_first, &second, true);
    // A value that is not set is the message's default.
    try expect("this.items.all(k, this.items[k].a != 1) && this.items.exists(k, this.items[k].a == 0)", &sample, &second, true);
}

/// Room for `sample` encoded.
const encoded_len_max = 128;

test "a macro over a map that lies in the message's octets reads each entry's value" {
    var octets: [encoded_len_max]u8 = undefined;
    const viewed = try proto.decode(Message, try proto.encode(Message, &sample, &octets));
    try testing.expect(viewed.counts.items.len == 0 and viewed.counts.view.bytes.len != 0);
    try expect("this.counts.all(k, this.counts[k] <= 2) && !this.counts.exists(k, this.counts[k] == 4)", &viewed, &second, true);
    try expect("this.items.all(k, this.items[k].a != 1) && this.items.exists_one(k, this.items[k].a == 4)", &viewed, &second, true);
}

test "an index reads the binding of its own map and variable alone" {
    // Another map at the same key is searched.
    try expect("this.counts.all(k, this.limits[k] == 9)", &sample, &second, true);
    try expect("this.counts.all(k, this.counts[k] < 3 && this.limits[k] == 9)", &sample, &second, true);
    // An inner macro's variable hides the key.
    try expect("this.counts.all(k, ['a'].all(k, this.counts[k] == 1))", &sample, &second, true);
    // An inner macro's variable hides the map's name.
    try expect("this.counts.all(k, [that].all(this, this.counts[k] == 7))", &sample, &second, true);
    // The variable of a macro over a list binds no entry.
    try expect("['a', 'b'].all(k, this.counts[k] < 3)", &sample, &second, true);
}

test "the macro reads each entry once, and the entries after a key whose result ends the macro" {
    const three: Message = .{ .counts = .of(&.{ .{ .key = "a", .value = 1 }, .{ .key = "b", .value = 1 }, .{ .key = "c", .value = 1 } }) };
    // Three keys and the end.
    const keys = 4;
    try testing.expect(try run("this.counts.all(k, this.counts[k] > 0)", &three, &second, keys));
    try testing.expectError(error.TooManyItems, run("this.counts.all(k, this.counts[k] > 0)", &three, &second, keys - 1));
    // The first key's false is read, then the two entries after it, which do not hold its key.
    const ended = 1 + 2;
    try testing.expect(!try run("this.counts.all(k, this.counts[k] > 1)", &three, &second, ended));
    try testing.expectError(error.TooManyItems, run("this.counts.all(k, this.counts[k] > 1)", &three, &second, ended - 1));
    // An expression that reads no index of the map reads its keys and the end alone.
    try testing.expect(try run("this.counts.all(k, k != '')", &three, &second, keys));
    // An index at another name searches from the last entry back: three, two and one reads,
    // after the keys, and the element and the end of each list.
    const searched = keys + 3 * 2 + 3 + 2 + 1;
    try testing.expect(try run("this.counts.all(k, [k].all(j, this.counts[j] > 0))", &three, &second, searched));
}
