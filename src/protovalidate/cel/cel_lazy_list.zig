//! The lists that `filter` and `map` give (CEL language definition, "Macros"). Such a list is
//! computed as the caller reads it: each element of the source list, or each key of the source
//! map, goes through the predicate and the transform one at a time. Nothing is copied, so the
//! list needs no storage, and `size`, `in`, an index and the macros read it as any other list.
const std = @import("std");
const proto = @import("protobuf");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const list_file = @import("cel_list.zig");
const collection = @import("cel_collection.zig");
const evaluation = @import("cel_eval.zig");
const Node = node_file.Node;
const Scope = type_file.Scope;
const Env = type_file.Env;
const Error = type_file.Error;

/// What a lazy list does with each element of its source.
pub const Steps = struct {
    /// The name the predicate and the transform give the element.
    variable: []const u8,
    /// `filter`'s expression, or the middle one of `map(x, p, t)`: an element it is false for
    /// is left out.
    predicate: ?*const Node = null,
    /// `map`'s last expression: the value the list holds for each element it keeps.
    transform: ?*const Node = null,
};

/// The list `steps` make of `Source`, a list or a map, inside an expression whose names are
/// `scope`'s. The list keeps the values of those names, which its expressions read.
pub fn LazyList(comptime Source: type, comptime steps: Steps, comptime scope: Scope) type {
    return struct {
        source: Source,
        values: Values,

        const Self = @This();
        const Values = std.meta.Tuple(scope.types);
        const Variable = collection.Variable(Source).?;
        const inner = scope.with(steps.variable, Variable);
        pub const Element = if (steps.transform) |transform| evaluation.Result(transform, inner) else Variable;
        pub const cel_name = "list(" ++ type_file.name_of(Element) ++ ")";

        pub const Iterator = struct {
            source: list_file.IteratorOf(Source),
            values: Values,

            /// The next element the list holds. A predicate or a transform that fails fails
            /// the read, as it fails the macro in CEL.
            pub fn next(it: *Iterator, env: *Env) Error!?Element {
                for (0..proto.constants.limits.elements_max) |_| {
                    const element = try it.source.next(env) orelse return null;
                    if (try kept(Source, steps, inner, Element, it.source, it.values ++ .{element}, env)) |value| return value;
                }
                unreachable;
            }
        };

        pub fn iterator(list: Self) Iterator {
            return .{ .source = list_file.iterate(list.source), .values = list.values };
        }
    };
}

/// The value a lazy list holds for the element that ends `values`, or null when the list leaves
/// the element out. `after` is the source's iterator past the element.
fn kept(
    comptime Source: type,
    comptime steps: Steps,
    comptime inner: Scope,
    comptime Element: type,
    after: list_file.IteratorOf(Source),
    values: anytype,
    env: *Env,
) Error!?Element {
    const element = values[values.len - 1];
    // A map's key that a later entry holds again is read once, at its last entry.
    if (comptime list_file.is_map(Source)) {
        if (try list_file.key_again(Source, after, element, env)) return null;
    }
    if (comptime steps.predicate != null) {
        if (!try evaluation.eval_as(bool, steps.predicate.?, inner, values, env)) return null;
    }
    if (comptime steps.transform == null) return element;
    return try evaluation.eval_as(Element, steps.transform.?, inner, values, env);
}
