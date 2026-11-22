//! A macro over a map whose expression reads the map at its variable: `m.all(k, m[k] > 0)`.
//! Such a macro binds the value of each entry beside its key, and `m[k]` reads that binding, so
//! the index searches no entry. The macro reads each key once, at the last entry that holds
//! it, whose value is the one `m[k]` gives ("Maps", language guide). `all` and `exists` give
//! the same result for a key read twice, and `exists_one` reads each key once in any case.
const std = @import("std");
const node_file = @import("cel_node.zig");
const type_file = @import("cel_type.zig");
const list_file = @import("cel_list.zig");
const Node = node_file.Node;
const Scope = type_file.Scope;

/// The name that a macro over `target` binds each entry's value under, beside its variable,
/// or null when `target` is neither a name nor a field of one. An identifier holds no `[`, so
/// no expression reads the binding by its name.
fn binding_name(comptime target: *const Node) ?[]const u8 {
    return "[" ++ (path_of(target) orelse return null) ++ "]";
}

/// The text of `name` and of `name.field`, which read one value wherever they are read.
fn path_of(comptime node: *const Node) ?[]const u8 {
    return switch (node.*) {
        .name => |name| name,
        .select => |select| (path_of(select.of) orelse return null) ++ "." ++ select.field,
        else => null,
    };
}

/// The first name of a path.
fn root_of(comptime node: *const Node) []const u8 {
    return switch (node.*) {
        .name => |name| name,
        .select => |select| root_of(select.of),
        else => unreachable,
    };
}

/// The name a macro `call` over a `Collection` binds each entry's value under, or null when
/// the macro binds none: `Collection` is no map, or the expression reads no index of the map at
/// the variable.
pub fn bound_name(comptime call: Node.Call, comptime Collection: type) ?[]const u8 {
    if (!list_file.is_map(Collection)) return null;
    const name = binding_name(call.target.?) orelse return null;
    return if (reads(&call.arguments[1], name, call.arguments[0].name)) name else null;
}

/// Whether `node` holds an index whose target has the binding `name` and whose key is the
/// name `variable`. A macro inside `node` may bind either name again; `place_of` then finds no
/// binding, and the index searches the map.
fn reads(comptime node: *const Node, comptime name: []const u8, comptime variable: []const u8) bool {
    return switch (node.*) {
        .index => |index| reads_index(index, name, variable),
        .select => |select| reads(select.of, name, variable),
        .unary => |unary| reads(unary.of, name, variable),
        .binary => |binary| reads(binary.left, name, variable) or reads(binary.right, name, variable),
        .conditional => |conditional| reads(conditional.condition, name, variable) or
            reads(conditional.then, name, variable) or reads(conditional.otherwise, name, variable),
        .call => |call| (call.target != null and reads(call.target.?, name, variable)) or reads_any(call.arguments, name, variable),
        .list => |elements| reads_any(elements, name, variable),
        else => false,
    };
}

fn reads_index(comptime index: Node.Index, comptime name: []const u8, comptime variable: []const u8) bool {
    const at_variable = index.at.* == .name and std.mem.eql(u8, index.at.name, variable);
    const same_target = if (binding_name(index.of)) |target| std.mem.eql(u8, target, name) else false;
    return (at_variable and same_target) or reads(index.of, name, variable) or reads(index.at, name, variable);
}

fn reads_any(comptime nodes: []const Node, comptime name: []const u8, comptime variable: []const u8) bool {
    for (nodes) |*node| {
        if (reads(node, name, variable)) return true;
    }
    return false;
}

/// The place in `scope` of the entry's value that `index` reads, or null. `index` is `m[k]`
/// where a macro over `m` bound the variable `k` and the value of its entry, and no name bound
/// after the macro's variable hides `k` or the first name of `m`.
pub fn place_of(comptime index: Node.Index, comptime scope: Scope) ?usize {
    if (index.at.* != .name) return null;
    const name = binding_name(index.of) orelse return null;
    const key = scope.index_of(index.at.name) orelse return null;
    const place = key + 1;
    if (place == scope.names.len or !std.mem.eql(u8, scope.names[place], name)) return null;
    const root = scope.index_of(root_of(index.of)) orelse return null;
    return if (root < key) place else null;
}
