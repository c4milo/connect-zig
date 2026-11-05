//! How the plugin names what it writes: Zig identifiers from .proto names, and the paths of
//! generated files (design §8 step 6).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// "connectrpc/eliza/v1/eliza.proto" becomes "connectrpc/eliza/v1/eliza.pb.zig".
pub fn output_path(arena: Allocator, proto_path: []const u8) Allocator.Error![]const u8 {
    const stem = if (std.mem.endsWith(u8, proto_path, ".proto")) proto_path[0 .. proto_path.len - ".proto".len] else proto_path;
    return std.fmt.allocPrint(arena, "{s}.pb.zig", .{stem});
}

/// A method or an enum value's Zig name: "GetUser" becomes "get_user", and "COLOR_RED"
/// becomes "color_red".
pub fn snake_case(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |octet, index| {
        if (std.ascii.isUpper(octet)) {
            const after_lower = index > 0 and (std.ascii.isLower(name[index - 1]) or std.ascii.isDigit(name[index - 1]));
            const before_lower = index > 0 and index + 1 < name.len and std.ascii.isUpper(name[index - 1]) and std.ascii.isLower(name[index + 1]);
            if (after_lower or before_lower) try out.append(arena, '_');
            try out.append(arena, std.ascii.toLower(octet));
        } else try out.append(arena, octet);
    }
    return out.items;
}

/// An identifier as Zig reads it: a keyword or a primitive type name, such as `type` or `bool`,
/// is written `@"type"`.
pub fn identifier(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{std.zig.fmtIdFlags(name, .{ .allow_primitive = false, .allow_underscore = true })});
}

/// A struct field's or an enum tag's name as zig fmt writes it: a keyword is quoted, and a
/// primitive type name such as `type` or `bool` is not, since it names no type there.
pub fn field_identifier(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{std.zig.fmtIdFlags(name, .{ .allow_primitive = true, .allow_underscore = true })});
}

/// A string literal's contents, escaped.
pub fn string_literal(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "\"{f}\"", .{std.zig.fmtString(text)});
}

/// The module name a generated file imports another generated file by: "google/type/date.proto"
/// becomes "google_type_date". The build gives each generated file's module this name.
pub fn import_name(arena: Allocator, proto_path: []const u8) Allocator.Error![]const u8 {
    const stem = if (std.mem.endsWith(u8, proto_path, ".proto")) proto_path[0 .. proto_path.len - ".proto".len] else proto_path;
    const out = try arena.dupe(u8, stem);
    for (out) |*octet| {
        if (!std.ascii.isAlphanumeric(octet.*)) octet.* = '_';
    }
    return out;
}

const testing = std.testing;

test "names follow Zig's conventions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("get_user", try snake_case(arena, "GetUser"));
    try testing.expectEqualStrings("get_http_response", try snake_case(arena, "GetHTTPResponse"));
    try testing.expectEqualStrings("color_red", try snake_case(arena, "COLOR_RED"));
    try testing.expectEqualStrings("@\"type\"", try identifier(arena, "type"));
    try testing.expectEqualStrings("@\"bool\"", try identifier(arena, "bool"));
    try testing.expectEqualStrings("type", try field_identifier(arena, "type"));
    try testing.expectEqualStrings("@\"error\"", try field_identifier(arena, "error"));
    try testing.expectEqualStrings("name", try identifier(arena, "name"));
    try testing.expectEqualStrings("a/b.pb.zig", try output_path(arena, "a/b.proto"));
    try testing.expectEqualStrings("google_type_date", try import_name(arena, "google/type/date.proto"));
}
