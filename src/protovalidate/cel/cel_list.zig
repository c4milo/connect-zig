//! CEL's lists and maps (CEL language definition, "Values"). A list is a view of a repeated
//! field, or a list literal's elements. A map is a view of a map field, whose entries are a
//! repeated field of key and value pairs. Neither is copied: each is read where it lies, one
//! element at a time, and each element read is counted against the expression's limit.
const std = @import("std");
const proto = @import("protobuf");
const table = @import("../table.zig");
const shape = @import("../shape.zig");
const type_file = @import("cel_type.zig");
const value_file = @import("cel_value.zig");
const text_file = @import("cel_text.zig");
const Env = type_file.Env;
const Error = type_file.Error;

/// A repeated field `F` as a list.
pub fn List(comptime F: type) type {
    return struct {
        field: *const F,

        const Self = @This();
        pub const Element = type_file.Of(F.kind, F.Element);
        pub const cel_name = "list(" ++ type_file.name_of(Element) ++ ")";

        pub const Iterator = struct {
            inner: F.Iterator,
            /// The stored elements, which the iterator reads in place, or null.
            stored: ?[]const F.Element,
            place: usize = 0,

            /// The next element. A message is a pointer that lasts until the next call.
            pub fn next(it: *Iterator, env: *Env) Error!?Element {
                try env.spend();
                if (it.stored) |items| {
                    if (it.place == items.len) return null;
                    defer it.place += 1;
                    return type_file.from(F.kind, F.Element, &items[it.place]);
                }
                const item = (it.inner.next() catch return error.Malformed) orelse return null;
                const element: *const F.Element = if (comptime @TypeOf(item) == *const F.Element) item else &item;
                return type_file.from(F.kind, F.Element, element);
            }
        };

        pub fn iterator(list: Self) Iterator {
            // A stored field's iterator reads the slice alone, and builds no view's iterator.
            if (list.stored()) |items| return .{ .inner = undefined, .stored = items };
            return .{ .inner = list.field.iterator(), .stored = null };
        }

        /// The elements a decode with storage read the field into, or null when they lie in
        /// the field's view of the octets (decision 37). A list `of` elements is stored too.
        pub fn stored(list: Self) ?[]const F.Element {
            return stored_of(F, list.field);
        }

        /// The stored element at `place`, as an iterator gives it.
        pub fn element_at(list: Self, place: usize) Element {
            return type_file.from(F.kind, F.Element, &list.field.items[place]);
        }
    };
}

/// The iterator of a list literal's elements, which a `[N]T` holds.
fn ArrayIterator(comptime A: type) type {
    return struct {
        items: A,
        index: usize = 0,

        pub fn next(it: *@This(), env: *Env) Error!?@typeInfo(A).array.child {
            try env.spend();
            if (it.index == it.items.len) return null;
            defer it.index += 1;
            return it.items[it.index];
        }
    };
}

/// Whether `T` is a list: a repeated field's view, or a list literal's array.
pub fn is_list(comptime T: type) bool {
    if (@typeInfo(T) == .array) return true;
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Iterator") and @hasDecl(T, "Element") and !@hasDecl(T, "Key");
}

pub fn ElementOf(comptime T: type) type {
    if (@typeInfo(T) == .array) return @typeInfo(T).array.child;
    return T.Element;
}

pub fn IteratorOf(comptime T: type) type {
    if (@typeInfo(T) == .array) return ArrayIterator(T);
    return T.Iterator;
}

/// The iterator of a list's elements, of a list literal's, or of a map's keys.
pub fn iterate(list: anytype) IteratorOf(@TypeOf(list)) {
    if (comptime @typeInfo(@TypeOf(list)) == .array) return .{ .items = list };
    return list.iterator();
}

/// The type an index takes out of a list or a map: a message by value, since a pointer into
/// the iterator would not last, and any other element as it is.
pub fn Taken(comptime Element: type) type {
    if (@typeInfo(Element) == .pointer and type_file.is_message(Element)) return @typeInfo(Element).pointer.child;
    return Element;
}

fn take(comptime Element: type, element: Element) Taken(Element) {
    if (comptime Taken(Element) != Element) return element.*;
    return element;
}

/// A map field `F`, a repeated field of entries, as a map. An entry that repeats a key takes
/// the place of the one before it ("Maps", language guide).
pub fn Map(comptime F: type) type {
    return struct {
        field: *const F,

        const Self = @This();
        pub const Key = KeyOf(F);
        pub const Value = ValueOf(F);
        pub const cel_name = "map(" ++ type_file.name_of(Key) ++ ", " ++ type_file.name_of(Value) ++ ")";
        /// The iterator of the map's keys, one for each entry.
        pub const Iterator = KeyIterator(F);

        pub fn iterator(map: Self) Iterator {
            if (stored_of(F, map.field)) |entries| return .{ .inner = undefined, .stored = entries };
            return .{ .inner = map.field.iterator(), .stored = null };
        }

        /// The value of `key`, from the last entry that holds it, or null.
        pub fn get(map: Self, key: anytype, env: *Env) Error!?Taken(Value) {
            return value_at(F, map.field, key, env);
        }
    };
}

fn KeyOf(comptime F: type) type {
    return type_file.Of(table.field_named(F.Element, "key").kind, @FieldType(F.Element, "key"));
}

/// The type an entry holds its value as, without the optional of a message's.
fn HeldOf(comptime F: type) type {
    const Holder = @FieldType(F.Element, "value");
    return if (@typeInfo(Holder) == .optional) @typeInfo(Holder).optional.child else Holder;
}

fn ValueOf(comptime F: type) type {
    return type_file.Of(table.field_named(F.Element, "value").kind, HeldOf(F));
}

fn key_of(comptime F: type, entry: *const F.Element) KeyOf(F) {
    return type_file.from(comptime table.field_named(F.Element, "key").kind, @FieldType(F.Element, "key"), &entry.key);
}

/// An entry's value. A message value that is not set is the message's default.
fn value_of(comptime F: type, entry: *const F.Element) ValueOf(F) {
    const kind = comptime table.field_named(F.Element, "value").kind;
    if (comptime @typeInfo(@FieldType(F.Element, "value")) != .optional) return type_file.from(kind, HeldOf(F), &entry.value);
    const set = if (entry.value) |*set| set else return type_file.default_of(ValueOf(F));
    return type_file.from(kind, HeldOf(F), set);
}

/// The elements of a repeated field that a decode with storage read into a slice, or null when
/// they lie in the field's view of the octets (decision 37).
fn stored_of(comptime F: type, field: *const F) ?[]const F.Element {
    if (field.items.len != 0 or field.view.bytes.len == 0) return field.items;
    return null;
}

fn KeyIterator(comptime F: type) type {
    return struct {
        inner: F.Iterator,
        /// The stored entries, which the iterator reads in place, or null.
        stored: ?[]const F.Element,
        place: usize = 0,

        pub fn next(it: *@This(), env: *Env) Error!?KeyOf(F) {
            try env.spend();
            if (it.stored) |entries| {
                if (it.place == entries.len) return null;
                defer it.place += 1;
                return key_of(F, &entries[it.place]);
            }
            const entry = (it.inner.next() catch return error.Malformed) orelse return null;
            return key_of(F, entry);
        }
    };
}

/// The value of `key` in the map field `field`: the last entry's that holds it.
fn value_at(comptime F: type, field: *const F, key: anytype, env: *Env) Error!?Taken(ValueOf(F)) {
    if (stored_of(F, field)) |entries| return stored_value_at(F, entries, key, env);
    var found: ?Taken(ValueOf(F)) = null;
    var entries = field.iterator();
    for (0..proto.constants.limits.elements_max) |_| {
        try env.spend();
        const entry = (entries.next() catch return error.Malformed) orelse return found;
        if (value_file.equal(key_of(F, entry), key)) found = take(ValueOf(F), value_of(F, entry));
    }
    unreachable;
}

/// `value_at` over stored entries: from the last one back, so the first entry that holds `key`
/// is the one that counts, and the search stops there.
fn stored_value_at(comptime F: type, entries: []const F.Element, key: anytype, env: *Env) Error!?Taken(ValueOf(F)) {
    for (0..entries.len) |back| {
        try env.spend();
        const entry = &entries[entries.len - 1 - back];
        if (value_file.equal(key_of(F, entry), key)) return take(ValueOf(F), value_of(F, entry));
    }
    return null;
}

pub fn is_map(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Iterator") and @hasDecl(T, "Key") and @hasDecl(T, "Value");
}

/// Whether a map of `F` reads as a `Map`: its values are not of a message that holds its own
/// type.
pub fn map_is_read(comptime F: type) bool {
    return !shape.is_lazy(@FieldType(F.Element, "value"));
}

/// `value in list`: an element of the list equals it.
pub fn list_holds(list: anytype, value: anytype, env: *Env) Error!bool {
    var elements = iterate(list);
    for (0..proto.constants.limits.elements_max) |_| {
        const written = text_file.mark_element(@TypeOf(list), env);
        defer text_file.free_element(@TypeOf(list), env, written);
        const element = try elements.next(env) orelse return false;
        if (value_file.equal(element, value)) return true;
    }
    unreachable;
}

/// `size(list)` and `size(map)`'s count of entries. A map's entry whose key a later entry
/// holds is not counted. A list literal's length and a stored list's are known, so neither
/// reads an element.
pub fn count(collection: anytype, env: *Env) Error!i64 {
    const C = @TypeOf(collection);
    if (comptime @typeInfo(C) == .array) return @typeInfo(C).array.len;
    if (comptime may_be_stored(C)) {
        if (collection.stored()) |items| return @intCast(items.len);
    }
    var total: i64 = 0;
    var elements = if (comptime is_map(@TypeOf(collection))) collection.iterator() else iterate(collection);
    for (0..proto.constants.limits.elements_max) |_| {
        const written = text_file.mark_element(C, env);
        defer text_file.free_element(C, env, written);
        const element = try elements.next(env) orelse return total;
        if (comptime is_map(@TypeOf(collection))) {
            if (try key_again(@TypeOf(collection), elements, element, env)) continue;
        }
        total += 1;
    }
    unreachable;
}

/// Whether `T` is a list of a repeated field, whose elements may lie in a slice. A literal's
/// array and a lazy list hold no slice.
fn may_be_stored(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "stored");
}

/// Whether an entry after the iterator's place holds `key`.
pub fn key_again(comptime M: type, after: M.Iterator, key: M.Key, env: *Env) Error!bool {
    var later = after;
    for (0..proto.constants.limits.elements_max) |_| {
        const other = try later.next(env) orelse return false;
        if (value_file.equal(other, key)) return true;
    }
    unreachable;
}

/// `list[index]`: the element at `index`, counted from 0. An index outside the list fails: no
/// element stands at it, nor at an index under 0.
pub fn at(list: anytype, index: i64, env: *Env) Error!Taken(ElementOf(@TypeOf(list))) {
    const L = @TypeOf(list);
    // A stored list is indexed in place: one element read.
    if (comptime may_be_stored(L)) {
        if (list.stored()) |items| {
            if (index < 0 or index >= items.len) return error.Unevaluable;
            try env.spend();
            return take(ElementOf(L), list.element_at(@intCast(index)));
        }
    }
    var elements = iterate(list);
    var place: i64 = 0;
    for (0..proto.constants.limits.elements_max) |_| {
        const written = text_file.mark_element(L, env);
        const element = try elements.next(env) orelse return error.Unevaluable;
        if (place == index) return take(ElementOf(@TypeOf(list)), element);
        // An element before the index is read no more, and its text goes.
        text_file.free_element(L, env, written);
        place += 1;
    }
    unreachable;
}

const testing = std.testing;

const Pair = struct {
    key: i32 = 0,
    value: i32 = 0,
    pub const FieldNumber = enum(u29) { key = 1, value = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Pair", .map_entry = true, .fields = &.{
        proto.field_of(FieldNumber.key, .int32, .{}), proto.field_of(FieldNumber.value, .int32, .{}),
    } };
};

test "each element read counts against the expression's limit" {
    const Numbers = proto.Repeated(i32, .int32);
    const numbers: Numbers = .of(&.{ 1, 1 });
    const list: List(Numbers) = .{ .field = &numbers };
    const Pairs = proto.Repeated(Pair, .message);
    const pairs: Pairs = .of(&.{.{ .key = 1, .value = 1 }});
    const map: Map(Pairs) = .{ .field = &pairs };
    const literal = [_]i64{ 1, 1 };
    // Two elements and the end are three reads, of a list and of a literal alike.
    const reads = 3;
    var env: Env = .{ .steps = reads };
    var elements = iterate(list);
    for (0..reads) |_| _ = try elements.next(&env);
    try testing.expectEqual(@as(usize, 0), env.steps);
    try testing.expectError(error.TooManyItems, elements.next(&env));
    var literal_elements = iterate(literal);
    try testing.expectError(error.TooManyItems, literal_elements.next(&env));
    try testing.expectError(error.TooManyItems, map.get(@as(i64, 1), &env));
    try testing.expectError(error.TooManyItems, count(map, &env));
    // A stored list's length and a literal's are known: their size reads no element, and an
    // index of a stored list reads one.
    try testing.expectEqual(@as(i64, reads - 1), try count(list, &env));
    try testing.expectEqual(@as(i64, reads - 1), try count(literal, &env));
    try testing.expectError(error.TooManyItems, at(list, 1, &env));
    env.steps = 1;
    try testing.expectEqual(@as(i64, 1), try at(list, 1, &env));
    try testing.expectEqual(@as(usize, 0), env.steps);
    // A map's one key, the search for it among the later entries and the end are three reads.
    env.steps = reads;
    try testing.expectEqual(@as(i64, 1), try count(map, &env));
    try testing.expectEqual(@as(usize, 0), env.steps);
    // A stored map's lookup reads from the last entry back and stops at the key: one read.
    env.steps = reads;
    try testing.expectEqual(@as(?i64, 1), try map.get(@as(i64, 1), &env));
    try testing.expectEqual(@as(usize, reads - 1), env.steps);
}

test "a stored map's key that two entries hold gives the last entry's value, and a missing one none" {
    const Pairs = proto.Repeated(Pair, .message);
    const pairs: Pairs = .of(&.{ .{ .key = 1, .value = 10 }, .{ .key = 2, .value = 20 }, .{ .key = 1, .value = 30 } });
    const map: Map(Pairs) = .{ .field = &pairs };
    var env: Env = .{};
    try testing.expectEqual(@as(?i64, 30), try map.get(@as(i64, 1), &env));
    try testing.expectEqual(@as(?i64, 20), try map.get(@as(i64, 2), &env));
    try testing.expectEqual(@as(?i64, null), try map.get(@as(i64, 3), &env));
    // The last entry holds the key, so the lookup reads it alone and stops.
    var one: Env = .{ .steps = 1 };
    try testing.expectEqual(@as(?i64, 30), try map.get(@as(i64, 1), &one));
    var keys = iterate(map);
    for ([_]i64{ 1, 2, 1 }) |expected| try testing.expectEqual(@as(?i64, expected), try keys.next(&env));
    try testing.expectEqual(@as(?i64, null), try keys.next(&env));
}

test "a list and a map are told apart, and a message that an index takes is a copy" {
    const Numbers = proto.Repeated(i32, .int32);
    const Pairs = proto.Repeated(Pair, .message);
    try testing.expect(is_list(List(Numbers)) and is_list([2]i64) and !is_list(Map(Pairs)) and !is_list(i64));
    try testing.expect(is_map(Map(Pairs)) and !is_map(List(Numbers)) and !is_map([2]i64));
    try testing.expect(ElementOf(List(Numbers)) == i64 and ElementOf([2]bool) == bool);
    try testing.expect(Taken(*const Pair) == Pair and Taken(i64) == i64 and Taken([]const u8) == []const u8);
    try testing.expect(map_is_read(Pairs));
    // A map whose values are of a message that holds its own type is not read.
    const Again = struct {
        key: i32 = 0,
        value: proto.Lazy(Pair) = .{},
    };
    try testing.expect(!map_is_read(proto.Repeated(Again, .message)));
}
