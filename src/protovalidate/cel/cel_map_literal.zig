//! A map literal, `{k1: v1, ..., kN: vN}`, its type and the code it unfolds into (CEL language
//! definition, "Aggregate Values"). Its keys are of one type and its values of one type, as a
//! list literal's elements are. "Key values must be an allowed key type: `int`, `uint`, `bool`,
//! or `string`", and "it is an error to have duplicate keys". `{}` holds no key and no value,
//! so both are `NoElement`, which the checker reads as `dyn`.
const std = @import("std");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const list_file = @import("cel_list.zig");
const value_file = @import("cel_value.zig");
const check = @import("cel_check.zig");
const evaluation = @import("cel_eval.zig");
const Node = node_file.Node;
const Scope = type_file.Scope;
const Typed = type_file.Typed;
const Env = type_file.Env;
const Error = type_file.Error;
const Failing = type_file.Failing;
const NoElement = type_file.NoElement;
const entry_parts = node_file.entry_parts;

/// A map literal of `len` entries, each key of `K` with its value of `V`. Its keys are
/// distinct: the code that computes one checks them.
pub fn MapLiteral(comptime K: type, comptime V: type, comptime entries_len: usize) type {
    return struct {
        keys: [entries_len]K,
        values: [entries_len]V,

        const Self = @This();
        pub const Key = K;
        pub const Value = V;
        pub const len = entries_len;
        pub const cel_name = "map(" ++ type_file.name_of(K) ++ ", " ++ type_file.name_of(V) ++ ")";
        /// The iterator of the map's keys.
        pub const Iterator = struct {
            map: Self,
            place: usize = 0,

            pub fn next(it: *Iterator, env: *Env) Error!?K {
                try env.spend();
                if (comptime entries_len == 0) return null;
                if (it.place == entries_len) return null;
                it.place += 1;
                return it.map.keys[it.place - 1];
            }

            /// The value of the key `next` read last.
            pub fn value(it: *const Iterator) list_file.Taken(V) {
                if (comptime entries_len == 0) unreachable;
                return take(it.map.values[it.place - 1]);
            }

            /// Whether a key after the one `next` read last equals `key`: never, as the keys
            /// are distinct.
            pub fn holds_later(_: *const Iterator, _: K, _: *Env) Error!bool {
                return false;
            }
        };

        pub fn iterator(map: Self) Iterator {
            return .{ .map = map };
        }

        /// The value of `key`, or null.
        pub fn get(map: Self, key: anytype, env: *Env) Error!?list_file.Taken(V) {
            if (comptime !value_file.equal_as_they_run(K, @TypeOf(key))) return null;
            for (map.keys, map.values) |held, value| {
                try env.spend();
                if (value_file.equal(held, key)) return take(value);
            }
            return null;
        }

        fn take(value: V) list_file.Taken(V) {
            if (comptime list_file.Taken(V) != V) return value.*;
            return value;
        }
    };
}

/// The type of a map literal whose keys and values are `parts` in turns: one type for the keys,
/// each an int, a uint, a bool or a string, and one type for the values.
pub fn of_map(comptime parts: []const Node, comptime scope: Scope) Typed {
    if (parts.len == 0) return .of(MapLiteral(NoElement, NoElement, 0));
    const key = switch (one_type(parts, 0, "key", scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const value = switch (one_type(parts, 1, "value", scope)) {
        .ok => |ok| ok,
        .problem => |problem| return .{ .problem = problem },
    };
    const dynamic = key.dynamic or value.dynamic;
    if (key.type == Failing or value.type == Failing) return .{ .ok = .{ .type = Failing, .dynamic = dynamic } };
    // CEL language definition, "Aggregate Values": "Key values must be an allowed key type".
    if (!is_key_type(key.type)) return .{ .problem = "a map's key is an int, a uint, a bool or a string, not a " ++ type_file.name_of(key.type) };
    return .{ .ok = .{ .type = MapLiteral(key.type, value.type, parts.len / entry_parts), .dynamic = dynamic } };
}

fn is_key_type(comptime K: type) bool {
    return K == i64 or K == u64 or K == bool or K == []const u8;
}

/// The one type of the part at `first` of each entry: a map literal's keys, or its values.
fn one_type(comptime parts: []const Node, comptime first: usize, comptime role: []const u8, comptime scope: Scope) Typed {
    var dynamic = false;
    var Common: ?type = null;
    for (0..parts.len / entry_parts) |entry| {
        const typed = switch (check.type_of(&parts[entry * entry_parts + first], scope)) {
            .ok => |ok| ok,
            .problem => |problem| return .{ .problem = problem },
        };
        if (typed.type == Failing) return .{ .ok = typed };
        dynamic = dynamic or typed.dynamic;
        const T = Common orelse typed.type;
        if (typed.type != T) return .{ .problem = "a map literal holds a " ++ type_file.name_of(T) ++ " " ++ role ++ " and a " ++ type_file.name_of(typed.type) ++ " " ++ role };
        Common = T;
    }
    return .{ .ok = .{ .type = Common.?, .dynamic = dynamic } };
}

/// The map literal: each key and then its value, in the order of the text. Two keys that are
/// equal fail the run (CEL language definition, "Aggregate Values").
pub fn eval_map(comptime parts: []const Node, comptime R: type, comptime scope: Scope, values: anytype, env: *Env) Error!R {
    var map: R = undefined;
    inline for (0..R.len) |place| {
        map.keys[place] = try evaluation.eval(&parts[entry_parts * place], scope, values, env);
        map.values[place] = try evaluation.eval(&parts[entry_parts * place + 1], scope, values, env);
    }
    if (comptime R.len < entry_parts) return map;
    for (map.keys, 0..) |key, place| {
        for (map.keys[place + 1 ..]) |other| {
            if (value_file.equal(key, other)) return error.Unevaluable;
        }
    }
    return map;
}
