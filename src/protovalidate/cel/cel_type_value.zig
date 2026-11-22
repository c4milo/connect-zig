//! CEL's types as values (CEL language definition, "Type Values"): `type(x)` gives the type of
//! a value, and a type's name, such as `int` or `google.protobuf.Timestamp`, names that type in
//! an expression. The compiler knows each value's type but a wrapper's, which is null when it
//! is not set, so a type value is the type's name.
const std = @import("std");
const proto = @import("protobuf");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const mixed = @import("cel_mixed.zig");
const list_file = @import("cel_list.zig");
const select_file = @import("cel_select.zig");
const constants = @import("../constants.zig");
const Node = node_file.Node;
const Scope = type_file.Scope;
const Bytes = type_file.Bytes;
const Null = type_file.Null;

/// A type, as a value.
pub const TypeValue = struct {
    /// The type's name as CEL writes it: `int`, `list`, `google.protobuf.Timestamp`.
    name: []const u8,

    pub const cel_name = "type";
};

/// The names of CEL's own types, which an expression writes as identifiers (CEL language
/// definition, "Values").
const builtin_names = [_][]const u8{ "int", "uint", "double", "bool", "string", "bytes", "list", "map", "null_type", "type" };

/// The CEL name of the type of a `T` (CEL language definition, "Values"). A wrapper that is
/// set has the type it wraps, and one that is not set is null, which `of` reads as it runs.
pub fn name_of(comptime T: type) []const u8 {
    if (comptime type_file.MessageOf(T)) |M| return M.protobuf.full_name;
    if (comptime list_file.is_map(T) or mixed.is_mixed_map(T)) return "map";
    if (comptime list_file.is_list(T) or mixed.is_mixed_list(T)) return "list";
    return switch (T) {
        i64 => "int",
        u64 => "uint",
        f64 => "double",
        bool => "bool",
        []const u8 => "string",
        Bytes => "bytes",
        Null => "null_type",
        proto.wkt.Timestamp => "google.protobuf.Timestamp",
        proto.wkt.Duration => "google.protobuf.Duration",
        TypeValue => "type",
        else => @compileError("no CEL type holds a " ++ @typeName(T)),
    };
}

/// `type(value)`.
pub fn of(value: anytype) TypeValue {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .optional) {
        if (value == null) return .{ .name = "null_type" };
        return .{ .name = comptime name_of(@typeInfo(T).optional.child) };
    }
    return .{ .name = comptime name_of(T) };
}

/// The type an identifier names, or null: one of CEL's own types, which a name in `scope`
/// hides.
pub fn named(comptime name: []const u8) ?TypeValue {
    for (builtin_names) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return .{ .name = builtin };
    }
    return null;
}

/// The type a selection names, such as `google.protobuf.Timestamp`, or null: a timestamp, a
/// duration, or a message type the expression's values hold, at any depth. A selection whose
/// first name is in `scope` names a field, and no type.
pub fn dotted(comptime select: Node.Select, comptime scope: Scope) ?TypeValue {
    const path = path_of(select.of, scope) orelse return null;
    const name = path ++ "." ++ select.field;
    if (std.mem.eql(u8, name, name_of(proto.wkt.Timestamp)) or std.mem.eql(u8, name, name_of(proto.wkt.Duration))) return .{ .name = name };
    for (scope.types) |T| {
        if (holds_message(T, name, constants.cel_depth_max)) return .{ .name = name };
    }
    return null;
}

/// The names of a selection's target, joined by dots, when they name no value of `scope`.
fn path_of(comptime node: *const Node, comptime scope: Scope) ?[]const u8 {
    return switch (node.*) {
        .name => |name| if (scope.index_of(name) != null or std.mem.eql(u8, name, "now")) null else name,
        .select => |select| (path_of(select.of, scope) orelse return null) ++ "." ++ select.field,
        else => null,
    };
}

/// Whether a value of type `T` is a message named `name`, or holds one in a field, a list or a
/// map, within `depth` steps.
fn holds_message(comptime T: type, comptime name: []const u8, comptime depth: usize) bool {
    if (depth == 0) return false;
    if (list_file.is_map(T)) return holds_message(T.Value, name, depth - 1);
    if (list_file.is_list(T)) return holds_message(list_file.ElementOf(T), name, depth - 1);
    const M = type_file.MessageOf(T) orelse return false;
    if (std.mem.eql(u8, M.protobuf.full_name, name)) return true;
    for (M.protobuf.fields) |field| {
        const F = select_file.Type(M, field) orelse continue;
        if (holds_message(F, name, depth - 1)) return true;
    }
    return false;
}

const testing = std.testing;

test "a value's type has CEL's name, and a wrapper's depends on whether it is set" {
    try testing.expectEqualStrings("int", of(@as(i64, 1)).name);
    try testing.expectEqualStrings("string", of(@as([]const u8, "a")).name);
    try testing.expectEqualStrings("null_type", of(Null{}).name);
    try testing.expectEqualStrings("list", of([_]i64{1}).name);
    try testing.expectEqualStrings("google.protobuf.Duration", of(proto.wkt.Duration{}).name);
    try testing.expectEqualStrings("type", of(of(@as(u64, 1))).name);
    try testing.expectEqualStrings("null_type", of(@as(?i64, null)).name);
    try testing.expectEqualStrings("int", of(@as(?i64, 1)).name);
    try testing.expectEqualStrings("bool", (comptime named("bool")).?.name);
    try testing.expect(comptime named("integer") == null);
}
