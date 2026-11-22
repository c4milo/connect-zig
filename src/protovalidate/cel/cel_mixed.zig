//! A list literal or a map literal whose elements are of two types or more, as `[1, 'a']` and
//! `{'k': 1, 2: 'v'}`. "The type `dyn` is used for heterogeneous values" (CEL language
//! definition, "Aggregate Values"), and cel-go types such a literal `list(dyn)` or
//! `map(dyn, dyn)`. The compiler knows each element's type, so the literal is a tuple, and each
//! read of it unfolds element by element: its size, `in`, `==`, `type()`, an index the build
//! knows, and the macros `all`, `exists` and `exists_one`, whose variable is read as behind `dyn`.
//! An index the build does not know, of a list or of a map whose values are of two types, has no
//! one type, and stops the build.
const std = @import("std");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const list_file = @import("cel_list.zig");
const value_file = @import("cel_value.zig");
const check = @import("cel_check.zig");
const evaluation = @import("cel_eval.zig");
const constant_file = @import("cel_constant.zig");
const equal_file = @import("cel_equal.zig");
const Node = node_file.Node;
const Scope = type_file.Scope;
const Typed = type_file.Typed;
const Env = type_file.Env;
const Error = type_file.Error;
const Failing = type_file.Failing;
const Constant = constant_file.Constant;

/// A list literal whose elements are of `Types`, two types or more.
pub fn MixedList(comptime Types: []const type) type {
    return struct {
        items: std.meta.Tuple(Types),

        pub const mixed = true;
        pub const mixed_list = true;
        pub const cel_name = "list(dyn)";
        pub const len = Types.len;
        pub const element_types = Types;
    };
}

/// A map literal whose keys are of `Keys` and whose values are of `Values`, where either holds
/// two types or more. `known` holds each key's constant, when no key's expression reads a name.
/// The keys are distinct: the code that computes the map checks them.
pub fn MixedMap(comptime Keys: []const type, comptime Values: []const type, comptime known: ?[]const Constant) type {
    return struct {
        keys: std.meta.Tuple(Keys),
        values: std.meta.Tuple(Values),

        pub const mixed = true;
        pub const mixed_map = true;
        pub const cel_name = "map(dyn, dyn)";
        pub const len = Keys.len;
        /// The types a macro's variable takes: the keys'.
        pub const element_types = Keys;
        pub const value_types = Values;
        pub const constant_keys = known;
        /// The one type of the values, or null when they are of two types.
        pub const one_value: ?type = one_type(Values);
    };
}

pub fn is_mixed_list(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "mixed_list");
}

pub fn is_mixed_map(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "mixed_map");
}

pub fn is_mixed(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "mixed");
}

/// The type all of `types` are, or null when two differ.
pub fn one_type(comptime types: []const type) ?type {
    for (types[1..]) |T| {
        if (T != types[0]) return null;
    }
    return types[0];
}

/// The elements a macro reads: a list's items, or a map's keys.
fn elements_of(collection: anytype) ElementsOf(@TypeOf(collection)) {
    if (comptime is_mixed_list(@TypeOf(collection))) return collection.items;
    return collection.keys;
}

fn ElementsOf(comptime C: type) type {
    return if (is_mixed_list(C)) @FieldType(C, "items") else @FieldType(C, "keys");
}

pub fn eval_list(comptime elements: []const Node, comptime R: type, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    var list: R = undefined;
    inline for (elements, 0..) |*element, place| list.items[place] = try evaluation.eval(element, scope, values, env);
    return list;
}

/// The map: each key and then its value, in the order of the text. Two keys that are equal, a
/// number of one type with a number of another too, fail the run ("Aggregate Values": "It is an
/// error to have duplicate keys").
pub fn eval_map(comptime parts: []const Node, comptime R: type, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    var map: R = undefined;
    inline for (0..R.len) |place| {
        map.keys[place] = try evaluation.eval(&parts[node_file.entry_parts * place], scope, values, env);
        map.values[place] = try evaluation.eval(&parts[node_file.entry_parts * place + 1], scope, values, env);
    }
    inline for (0..R.len) |place| {
        inline for (place + 1..R.len) |later| {
            if (equal_keys(map.keys[later], map.keys[place])) return error.Unevaluable;
        }
    }
    return map;
}

/// Whether two keys are equal: of types that may be equal, and equal.
fn equal_keys(key: anytype, other: anytype) bool {
    if (comptime !value_file.equal_as_they_run(@TypeOf(key), @TypeOf(other))) return false;
    return value_file.equal(key, other);
}

/// `value in collection`: an element of the list, or a key of the map, equals it.
pub fn holds(collection: anytype, value: anytype, env: *Env) Error!bool {
    inline for (elements_of(collection)) |element| {
        try env.spend();
        if (try equal_file.equal(element, value, env)) return true;
    }
    return false;
}

/// Whether `==` takes a `L` and a `R`, one of them mixed: two lists, or two maps.
pub fn compares(comptime L: type, comptime R: type) bool {
    const lists = (list_file.is_list(L) or is_mixed_list(L)) and (list_file.is_list(R) or is_mixed_list(R));
    const maps = (list_file.is_map(L) or is_mixed_map(L)) and (list_file.is_map(R) or is_mixed_map(R));
    return lists or maps;
}

/// `left == right`, one of them mixed. Two lists are equal when each element equals the element
/// at its place in the other, and two maps when each key of one is a key of the other with an
/// equal value and they hold as many keys (CEL language definition, "Lists and Maps").
pub fn equal(left: anytype, right: anytype, env: *Env) Error!bool {
    const L = @TypeOf(left);
    const R = @TypeOf(right);
    if (comptime !is_mixed(L)) return equal(right, left, env);
    if (comptime is_mixed_list(L) and (is_mixed_list(R) or list_file.is_list(R))) return equal_list(left, right, env);
    if (comptime is_mixed_map(L) and (is_mixed_map(R) or list_file.is_map(R))) return equal_map(left, right, env);
    return false;
}

fn equal_list(left: anytype, right: anytype, env: *Env) Error!bool {
    const L = @TypeOf(left);
    const R = @TypeOf(right);
    if (comptime is_mixed_list(R)) {
        if (comptime R.len != L.len) return false;
        inline for (0..L.len) |place| {
            if (!try equal_file.equal(left.items[place], right.items[place], env)) return false;
        }
        return true;
    }
    var others = list_file.iterate(right);
    inline for (0..L.len) |place| {
        const other = try others.next(env) orelse return false;
        if (!try equal_file.equal(left.items[place], other, env)) return false;
    }
    return try others.next(env) == null;
}

fn equal_map(left: anytype, right: anytype, env: *Env) Error!bool {
    const L = @TypeOf(left);
    if (L.len != try list_file.count(right, env)) return false;
    inline for (0..L.len) |place| {
        if (!try holds_entry(right, left.keys[place], left.values[place], env)) return false;
    }
    return true;
}

/// Whether `map` holds `key` with a value equal to `value`.
fn holds_entry(map: anytype, key: anytype, value: anytype, env: *Env) Error!bool {
    const M = @TypeOf(map);
    if (comptime is_mixed_map(M)) {
        inline for (0..M.len) |place| {
            if (equal_keys(map.keys[place], key)) return try equal_file.equal(map.values[place], value, env);
        }
        return false;
    }
    if (comptime !value_file.equal_as_they_run(M.Key, @TypeOf(key))) return false;
    const other = try map.get(key, env) orelse return false;
    return try equal_file.equal(other, value, env);
}

/// The type of `of[at]` of a mixed list or map: an element at a place the build knows, a value
/// when the values are of one type, or a value at a key the build knows.
pub fn of_index(comptime index: Node.Index, comptime target: Typed.Ok, comptime at: Typed.Ok) Typed {
    const T = target.type;
    const dynamic = target.dynamic or at.dynamic;
    if (is_mixed_map(T)) {
        if (T.one_value) |V| return .{ .ok = .{ .type = list_file.Taken(V), .dynamic = dynamic } };
    }
    const place = known_place(index, T) orelse {
        const parts = if (is_mixed_list(T)) "elements" else "values";
        return .{ .problem = "an index of a `" ++ T.cel_name ++ "` whose " ++ parts ++ " are of two types, at a place the build does not know" };
    };
    const Types = if (is_mixed_list(T)) T.element_types else T.value_types;
    // A place past the end, or a key the map does not hold, fails the run.
    const R = if (place) |found| Types[found] else Failing;
    return .{ .ok = .{ .type = R, .dynamic = dynamic } };
}

/// The place `index` reads, known to the build: an int constant of a list, or the entry whose
/// key equals a constant of a map whose keys are constants. The inner null is a place that
/// holds no element; the outer null, a place the build does not know.
fn known_place(comptime index: Node.Index, comptime T: type) ??usize {
    const at = constant_file.value_of(index.at) orelse return null;
    if (is_mixed_list(T)) {
        if (at != .int) return null;
        if (at.int < 0 or at.int >= T.len) return @as(?usize, null);
        return @as(usize, @intCast(at.int));
    }
    const keys = T.constant_keys orelse return null;
    for (keys, 0..) |key, place| {
        if (same_constant(key, at)) return place;
    }
    return @as(?usize, null);
}

fn same_constant(comptime key: Constant, comptime at: Constant) bool {
    return switch (key) {
        inline else => |held| switch (at) {
            inline else => |other| equal_keys(held, other),
        },
    };
}

pub fn eval_index(comptime index: Node.Index, comptime R: type, target: anytype, at: anytype, env: *Env) Error!R {
    const T = @TypeOf(target);
    if (comptime is_mixed_map(T) and T.one_value != null) {
        inline for (0..T.len) |place| {
            try env.spend();
            if (equal_keys(target.keys[place], at)) return take(R, target.values[place]);
        }
        // "map[key]": a key the map does not hold fails the run.
        return error.Unevaluable;
    }
    const place = comptime (known_place(index, T).?).?;
    if (comptime is_mixed_list(T)) return target.items[place];
    return target.values[place];
}

fn take(comptime R: type, value: anytype) R {
    if (comptime R != @TypeOf(value)) return value.*;
    return value;
}

/// The type of a macro over a mixed list or map: its expression is typed once for each
/// element's type, with the variable read as behind `dyn`.
pub fn of_macro(comptime call: Node.Call, comptime target: Typed.Ok, comptime scope: Scope) Typed {
    var dynamic = target.dynamic;
    for (target.type.element_types) |T| {
        const inner = scope.with_dynamic(call.arguments[0].name, T);
        const body = switch (check.type_of(&call.arguments[1], inner)) {
            .ok => |ok| ok,
            .problem => |problem| return .{ .problem = problem },
        };
        dynamic = dynamic or body.dynamic;
    }
    return .{ .ok = .{ .type = bool, .dynamic = dynamic } };
}

/// `all`, `exists` and `exists_one` over a mixed list's elements or a mixed map's keys, each read
/// in turn, as `cel_collection.zig` reads a list's.
pub fn eval_macro(comptime call: Node.Call, collection: anytype, comptime scope: Scope, values: anytype, env: *Env) Error!bool {
    const name = call.arguments[0].name;
    const body = &call.arguments[1];
    if (comptime call.function == .exists_one) return exists_one(elements_of(collection), name, body, scope, values, env);
    return every(elements_of(collection), comptime call.function == .exists, name, body, scope, values, env);
}

fn every(elements: anytype, comptime absorbing: bool, comptime name: []const u8, comptime body: *const Node, comptime scope: Scope, values: anytype, env: *Env) Error!bool {
    var failure: ?Error = null;
    inline for (elements) |element| {
        try env.spend();
        if (read(body, name, element, scope, values, env)) |result| {
            if (result == absorbing) return absorbing;
        } else |failed| failure = failure orelse failed;
    }
    return failure orelse !absorbing;
}

fn exists_one(elements: anytype, comptime name: []const u8, comptime body: *const Node, comptime scope: Scope, values: anytype, env: *Env) Error!bool {
    var matches: usize = 0;
    inline for (elements) |element| {
        try env.spend();
        if (try read(body, name, element, scope, values, env)) matches += 1;
    }
    return matches == 1;
}

/// The macro's expression for one element. An expression that gives no bool for it fails the
/// run, as behind `dyn`.
fn read(comptime body: *const Node, comptime name: []const u8, element: anytype, comptime scope: Scope, values: anytype, env: *Env) Error!bool {
    const inner = comptime scope.with_dynamic(name, @TypeOf(element));
    if (comptime evaluation.Result(body, inner) != bool) return error.Unevaluable;
    return evaluation.eval(body, inner, values ++ .{element}, env);
}
