//! What an expression does with lists and maps: a list literal, an index, `in`, `size`, and the
//! macros `all`, `exists`, `exists_one`, `filter` and `map` (CEL language definition, "Macros",
//! "List Operators" and "Map Operators"). Each has its type, which the compiler finds, and the
//! code it unfolds into.
const std = @import("std");
const proto = @import("protobuf");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const list_file = @import("cel_list.zig");
const value_file = @import("cel_value.zig");
const equal_file = @import("cel_equal.zig");
const check = @import("cel_check.zig");
const evaluation = @import("cel_eval.zig");
const lazy = @import("cel_lazy_list.zig");
const entry_file = @import("cel_entry.zig");
const mixed = @import("cel_mixed.zig");
const text_file = @import("cel_text.zig");
const Node = node_file.Node;
const Scope = type_file.Scope;
const Typed = type_file.Typed;
const Env = type_file.Env;
const Error = type_file.Error;
const Failing = type_file.Failing;

/// The type a macro's variable takes over a `T`: a list's element, or a map's key. Null when
/// `T` is neither.
pub fn Variable(comptime T: type) ?type {
    if (list_file.is_map(T)) return T.Key;
    if (list_file.is_list(T)) return list_file.ElementOf(T);
    return null;
}

/// A list literal: an array of its elements' one type, or a tuple of elements of two types or
/// more (`cel_mixed.zig`).
pub fn of_list(comptime elements: []const Node, comptime scope: Scope) Typed {
    if (elements.len == 0) return .of([0]type_file.NoElement);
    var dynamic = false;
    var types = [_]type{void} ** elements.len;
    for (elements, 0..) |*element, place| {
        const typed = switch (check.type_of(element, scope)) {
            .ok => |ok| ok,
            .problem => |problem| return .{ .problem = problem },
        };
        if (typed.type == Failing) return .{ .ok = typed };
        dynamic = dynamic or typed.dynamic;
        types[place] = typed.type;
    }
    const fixed = types;
    const T = if (mixed.one_type(&fixed)) |Element| [elements.len]Element else mixed.MixedList(&fixed);
    return .{ .ok = .{ .type = T, .dynamic = dynamic } };
}

pub fn eval_list(comptime elements: []const Node, comptime R: type, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    if (comptime mixed.is_mixed_list(R)) return mixed.eval_list(elements, R, scope, values, env);
    var taken: std.meta.Tuple(&([_]type{@typeInfo(R).array.child} ** elements.len)) = undefined;
    inline for (elements, 0..) |*element, index| taken[index] = try evaluation.eval(element, scope, values, env);
    return taken;
}

/// `list[index]` with an int, and `map[key]` with a value of the key's type.
pub fn of_index(comptime index: Node.Index, comptime scope: Scope) Typed {
    const target = switch (check.type_of(index.of, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const at = switch (check.type_of(index.at, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const dynamic = target.dynamic or at.dynamic;
    if (target.type == Failing or at.type == Failing) return .{ .ok = .{ .type = Failing, .dynamic = dynamic } };
    // An index of `[]` is of no type the checker knows, as behind `dyn`.
    if (Indexed(target.type, at.type)) |R| return .{ .ok = .{ .type = R, .dynamic = dynamic or R == type_file.NoElement } };
    if (mixed.is_mixed(target.type)) return mixed.of_index(index, target, at);
    if (at.dynamic and list_file.is_list(target.type) and (at.type == u64 or at.type == f64)) {
        return .{ .ok = .{ .type = list_file.Taken(list_file.ElementOf(target.type)), .dynamic = true } };
    }
    return check.mistake(dynamic, "found no matching overload for `[]` applied to (" ++ type_file.name_of(target.type) ++ ", " ++ type_file.name_of(at.type) ++ ")");
}

fn Indexed(comptime T: type, comptime At: type) ?type {
    if (list_file.is_map(T)) return if (value_file.equatable(T.Key, At)) list_file.Taken(T.Value) else null;
    if (list_file.is_list(T)) return if (At == i64) list_file.Taken(list_file.ElementOf(T)) else null;
    return null;
}

pub fn eval_index(comptime index: Node.Index, comptime R: type, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    // A macro over the map bound the value of the entry its variable names.
    if (comptime entry_file.place_of(index, scope)) |place| {
        if (comptime @TypeOf(values[place]) == R) return values[place];
    }
    const target = try evaluation.eval(index.of, scope, values, env);
    const at = try evaluation.eval(index.at, scope, values, env);
    if (comptime mixed.is_mixed(@TypeOf(target))) return mixed.eval_index(index, R, target, at, env);
    if (comptime !list_file.is_map(@TypeOf(target))) return list_file.at(target, try list_index(at), env);
    // "map[key]": a key the map does not hold fails the run.
    return try target.get(at, env) orelse error.Unevaluable;
}

/// A list's index: an int, or behind `dyn` a uint or a double with no fraction, as cel-go reads
/// one. A uint past the greatest int, or a double with a fraction, fails the run
/// (docs/specs/README.md).
fn list_index(at: anytype) Error!i64 {
    const At = @TypeOf(at);
    if (comptime At == i64) return at;
    if (comptime At == u64) return std.math.cast(i64, at) orelse error.Unevaluable;
    // A double not a number has no whole part equal to it, and one past the ints none in range.
    const past_ints: f64 = @floatFromInt(@as(u64, 1) << (@bitSizeOf(i64) - 1));
    if (@trunc(at) != at or !(at >= -past_ints and at < past_ints)) return error.Unevaluable;
    return @intFromFloat(at);
}

/// The type of `map.f`, a map of string keys read at the key `f`, or null when `T` is no such
/// map. CEL language definition, "Field Selection": "If `e` evaluates to a map, then `e.f` is
/// equivalent to `e['f']`".
pub fn KeySelected(comptime T: type) ?type {
    // `{}` holds no key, so a selection of it is no field and `has` of it is false.
    if (!list_file.is_map(T) or (T.Key != []const u8 and T.Key != type_file.NoElement)) return null;
    return list_file.Taken(T.Value);
}

/// `map.f`: the value at the key `f`. A key the map does not hold fails the run, as `map['f']`
/// does.
pub fn select_key(map: anytype, comptime key: []const u8, env: *Env) Error!KeySelected(@TypeOf(map)).? {
    return try map.get(@as([]const u8, key), env) orelse error.Unevaluable;
}

/// `has(map.f)`: "indicates whether the string `f` is a key in the map" (CEL language
/// definition, "Field Selection").
pub fn has_key(map: anytype, comptime key: []const u8, env: *Env) Error!bool {
    return try map.get(@as([]const u8, key), env) != null;
}

/// `value in list` and `key in map`.
pub fn In(comptime L: type, comptime R: type) ?type {
    // An element of a mixed list or a key of a mixed map is read as behind `dyn`.
    const V = Variable(R) orelse return if (mixed.is_mixed(R)) bool else null;
    // `[]` holds no element, so `in` takes any value with it.
    return if (V == type_file.NoElement or equal_file.equatable(L, V)) bool else null;
}

/// Whether `T` is a list or a map.
pub fn is_collection(comptime T: type) bool {
    return Variable(T) != null or mixed.is_mixed(T);
}

pub fn holds(collection: anytype, value: anytype, env: *Env) Error!bool {
    if (comptime mixed.is_mixed(@TypeOf(collection))) return mixed.holds(collection, value, env);
    // Behind `dyn` a value may be of a type no element has: it is no element then.
    if (comptime !equal_file.equal_as_they_run(Variable(@TypeOf(collection)).?, @TypeOf(value))) return false;
    if (comptime !list_file.is_map(@TypeOf(collection))) return list_file.list_holds(collection, value, env);
    var keys = collection.iterator();
    for (0..proto.constants.limits.elements_max) |_| {
        const key = try keys.next(env) orelse return false;
        if (value_file.equal(key, value)) return true;
    }
    unreachable;
}

/// Whether `call` is `size` of a list or of a map, whose type the caller found.
pub fn is_size(comptime call: Node.Call, comptime operand: type) bool {
    return call.function == .size and is_collection(operand);
}

/// A macro's arguments: its variable's name, and its expression.
const macro_arguments = 2;

/// Whether `call` is `all`, `exists` or `exists_one` on a target.
pub fn is_macro(comptime call: Node.Call) bool {
    if (call.target == null) return false;
    return switch (call.function) {
        .all, .exists, .exists_one => true,
        else => false,
    };
}

/// The type of a macro, or null when `call` is no macro: `target.all(x, p)`, `exists` and
/// `exists_one`, where `x` names each element of a list or each key of a map in `p`, and
/// `filter` and `map`, which give a list.
pub fn of_macro(comptime call: Node.Call, comptime scope: Scope) ?Typed {
    if (call.function == .map or call.function == .filter) return of_derived(call, scope);
    if (!is_macro(call)) return null;
    if (call.arguments.len != macro_arguments or call.arguments[0] != .name) return .{ .problem = "the macro `" ++ call.name ++ "` takes a name and an expression" };
    const target = switch (check.type_of(call.target.?, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    if (target.type == Failing) return .{ .ok = target };
    const V = Variable(target.type) orelse {
        if (mixed.is_mixed(target.type)) return mixed.of_macro(call, target, scope);
        return check.mistake(target.dynamic, "the macro `" ++ call.name ++ "` reads a list or a map, not a " ++ type_file.name_of(target.type));
    };
    const body = switch (check.type_of(&call.arguments[1], scope.with(call.arguments[0].name, V))) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    if (body.type != bool and body.type != Failing) {
        return check.mistake(body.dynamic, "the macro `" ++ call.name ++ "` takes a bool for each element, not a " ++ type_file.name_of(body.type));
    }
    return .{ .ok = .{ .type = bool, .dynamic = target.dynamic or body.dynamic } };
}

/// Whether `call` has a macro's arguments: a name and an expression, or for `map` also a name
/// and two expressions, `map(x, p, t)`.
fn takes_macro_arguments(comptime call: Node.Call) bool {
    const three = call.function == .map and call.arguments.len == macro_arguments + 1;
    if (call.arguments.len != macro_arguments and !three) return false;
    return call.target != null and call.arguments[0] == .name;
}

/// `filter(x, p)`, `map(x, t)` and `map(x, p, t)` on a list or a map. `map(x, t)` of a list
/// whose length the compiler knows, a list literal or a predefined rule's list, is a list of
/// that length. Any other gives a lazy list, which computes each element as it is read.
fn of_derived(comptime call: Node.Call, comptime scope: Scope) Typed {
    if (!takes_macro_arguments(call)) return .{ .problem = "the macro `" ++ call.name ++ "` takes a name and an expression" };
    const target = switch (check.type_of(call.target.?, scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    if (target.type == Failing) return .{ .ok = target };
    if (Variable(target.type) == null) {
        if (mixed.is_mixed(target.type)) return .{ .problem = "the macro `" ++ call.name ++ "` reads no `" ++ target.type.cel_name ++ "`, whose elements are of two types" };
        return check.mistake(target.dynamic, "the macro `" ++ call.name ++ "` reads a list or a map, not a " ++ type_file.name_of(target.type));
    }
    return of_steps(call, target, scope);
}

/// The list that `call`'s predicate and transform make of `target`.
fn of_steps(comptime call: Node.Call, comptime target: Typed.Ok, comptime scope: Scope) Typed {
    const V = Variable(target.type).?;
    const inner = scope.with(call.arguments[0].name, V);
    const predicate: ?*const Node = if (call.function == .filter or call.arguments.len > macro_arguments) &call.arguments[1] else null;
    const kept = switch (if (predicate) |node| of_predicate(call, node, inner) else Typed.of(bool)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const transform: ?*const Node = if (call.function == .map) &call.arguments[call.arguments.len - 1] else null;
    const element = switch (if (transform) |node| check.type_of(node, inner) else Typed.of(V)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    // `filter` and `map` of `[]` read no element, and give `[]`.
    if (V == type_file.NoElement) return .of([0]type_file.NoElement);
    if (kept.type == Failing) return .{ .ok = kept };
    if (element.type == Failing) return .{ .ok = element };
    const steps: lazy.Steps = .{ .variable = call.arguments[0].name, .predicate = predicate, .transform = transform };
    return .{ .ok = .{ .type = Derived(target.type, steps, element.type, scope), .dynamic = target.dynamic or kept.dynamic or element.dynamic } };
}

/// The list `steps` make of a `Source`: an array of the source's length for `map(x, t)` of an
/// array, and a lazy list for any other.
fn Derived(comptime Source: type, comptime steps: lazy.Steps, comptime Element: type, comptime scope: Scope) type {
    if (@typeInfo(Source) == .array and steps.predicate == null) return [@typeInfo(Source).array.len]Element;
    return lazy.LazyList(Source, steps, scope);
}

/// The type of a predicate of `filter` or `map`: a bool, a part that fails as it runs, or the
/// problem of another type.
fn of_predicate(comptime call: Node.Call, comptime predicate: *const Node, comptime inner: Scope) Typed {
    const typed = switch (check.type_of(predicate, inner)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    if (typed.type == bool or typed.type == Failing) return .{ .ok = typed };
    return check.mistake(typed.dynamic, "the macro `" ++ call.name ++ "` takes a bool for each element, not a " ++ type_file.name_of(typed.type));
}

/// `filter` and `map`: a list of the length the compiler knows, or a lazy list of the target's
/// value and the values of the expression's names.
pub fn eval_derived(comptime call: Node.Call, comptime R: type, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    if (comptime @typeInfo(R) == .array) return eval_map(call, R, scope, values, env);
    return .{ .source = try evaluation.eval(call.target.?, scope, values, env), .values = values };
}

fn eval_map(comptime call: Node.Call, comptime R: type, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    const source = try evaluation.eval(call.target.?, scope, values, env);
    const array = @typeInfo(R).array;
    const inner = comptime scope.with(call.arguments[0].name, @typeInfo(@TypeOf(source)).array.child);
    var mapped: std.meta.Tuple(&([_]type{array.child} ** array.len)) = undefined;
    inline for (0..array.len) |index| {
        try env.spend();
        mapped[index] = try evaluation.eval(&call.arguments[1], inner, values ++ .{source[index]}, env);
    }
    return mapped;
}

pub fn eval_macro(comptime call: Node.Call, comptime scope: Scope, values: anytype, env: *Env) Error!bool {
    const collection = try evaluation.eval(call.target.?, scope, values, env);
    const C = @TypeOf(collection);
    if (comptime mixed.is_mixed(C)) return mixed.eval_macro(call, collection, scope, values, env);
    const bound = comptime entry_file.bound_name(call, C);
    const variable = comptime scope.with(call.arguments[0].name, Variable(C).?);
    const inner = comptime if (bound) |name| variable.with(name, list_file.Taken(C.Value)) else variable;
    const body = &call.arguments[1];
    if (comptime call.function == .exists_one) return exists_one(collection, bound != null, body, inner, values, env);
    return every(collection, comptime call.function == .exists, bound != null, body, inner, values, env);
}

/// What a macro's expression reads beside the expression's names: the element, and in a macro
/// that binds each entry's value (`cel_entry.zig`) the value of the key's entry.
inline fn read_of(comptime binds: bool, element: anytype, elements: anytype) if (binds) struct { @TypeOf(element), @TypeOf(elements.value()) } else struct { @TypeOf(element) } {
    if (comptime binds) return .{ element, elements.value() };
    return .{element};
}

/// `all`, whose absorbing value is false, and `exists`, whose is true. As `&&` and `||` do,
/// a macro gives its absorbing value when an element has it, even if another element's
/// expression fails; with none, a failure fails the macro (CEL language definition, "Macros").
fn every(collection: anytype, comptime absorbing: bool, comptime binds: bool, comptime body: *const Node, comptime inner: Scope, values: anytype, env: *Env) Error!bool {
    var failure: ?Error = null;
    var elements = list_file.iterate(collection);
    for (0..proto.constants.limits.elements_max) |_| {
        // The element and its expression are read here alone: their text goes once both are.
        const written = text_file.mark_element(@TypeOf(collection), env);
        defer text_file.free_element(@TypeOf(collection), env, written);
        const element = try elements.next(env) orelse return failure orelse !absorbing;
        // A key that a later entry holds is read at that entry, with its value.
        if (binds and try list_file.key_again(@TypeOf(collection), elements, element, env)) continue;
        const result = evaluation.eval_as(bool, body, inner, values ++ read_of(binds, element, &elements), env) catch |failed| {
            failure = failure orelse failed;
            continue;
        };
        if (result == absorbing) return absorbing;
    }
    unreachable;
}

/// `exists_one`: the expression is true for one element, and a failure fails the macro. A
/// map's key that a later entry repeats is read once.
fn exists_one(collection: anytype, comptime binds: bool, comptime body: *const Node, comptime inner: Scope, values: anytype, env: *Env) Error!bool {
    const C = @TypeOf(collection);
    var matches: usize = 0;
    var elements = list_file.iterate(collection);
    for (0..proto.constants.limits.elements_max) |_| {
        const written = text_file.mark_element(C, env);
        defer text_file.free_element(C, env, written);
        const element = try elements.next(env) orelse return matches == 1;
        if (comptime list_file.is_map(C)) {
            if (try list_file.key_again(C, elements, element, env)) continue;
        }
        if (try evaluation.eval_as(bool, body, inner, values ++ read_of(binds, element, &elements), env)) matches += 1;
    }
    unreachable;
}
