//! Every message and enum of a CodeGeneratorRequest, by full name, with where it is declared and
//! how a generated file refers to it. The plugin is a program, so it allocates from the arena
//! `std.process.Init` gives it (decision 4).
const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("protobuf");
const pb = @import("descriptor_pb.zig");
const names = @import("names.zig");

pub const Error = Allocator.Error || proto.Error || error{UnknownType};

pub const Kind = enum { message, @"enum" };

pub const Entry = struct {
    /// The .proto file that declares it.
    file: []const u8,
    /// Its Zig path within that file: "Outer.Inner".
    zig_path: []const u8,
    kind: Kind,
    message: ?pb.DescriptorProto = null,
    map_entry: bool = false,
};

/// The well-known types the runtime's `proto.wkt` holds, which no file generates.
const wkt_names = [_][]const u8{
    "Timestamp",  "Duration",    "Empty",      "FieldMask",   "Any",       "DoubleValue", "FloatValue",
    "Int64Value", "UInt64Value", "Int32Value", "UInt32Value", "BoolValue", "StringValue", "BytesValue",
};

pub const Index = struct {
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn build(arena: Allocator, files: []const pb.FileDescriptorProto) Error!Index {
        var index: Index = .{};
        for (files) |file| {
            const prefix = try package_prefix(arena, file.package);
            var messages = file.message_type.iterator();
            while (try messages.next()) |message| try index.add_message(arena, file.name orelse "", prefix, "", message);
            var enums = file.enum_type.iterator();
            while (try enums.next()) |enumeration| try index.add_enum(arena, file.name orelse "", prefix, "", enumeration);
        }
        return index;
    }

    fn add_message(index: *Index, arena: Allocator, file: []const u8, prefix: []const u8, parent: []const u8, message: pb.DescriptorProto) Error!void {
        const name = message.name orelse "";
        const full = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, name });
        const zig_name = try names.identifier(arena, name);
        const zig_path = if (parent.len == 0) zig_name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ parent, zig_name });
        const map_entry = if (message.options) |options| options.map_entry orelse false else false;
        try index.entries.put(arena, full, .{ .file = file, .zig_path = zig_path, .kind = .message, .message = message, .map_entry = map_entry });
        const nested_prefix = try std.fmt.allocPrint(arena, "{s}.", .{full});
        var nested = message.nested_type.iterator();
        while (try nested.next()) |child| try index.add_message(arena, file, nested_prefix, zig_path, child);
        var enums = message.enum_type.iterator();
        while (try enums.next()) |enumeration| try index.add_enum(arena, file, nested_prefix, zig_path, enumeration);
    }

    fn add_enum(index: *Index, arena: Allocator, file: []const u8, prefix: []const u8, parent: []const u8, enumeration: pb.EnumDescriptorProto) Error!void {
        const name = enumeration.name orelse "";
        const full = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, name });
        const zig_name = try names.identifier(arena, name);
        const zig_path = if (parent.len == 0) zig_name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ parent, zig_name });
        try index.entries.put(arena, full, .{ .file = file, .zig_path = zig_path, .kind = .@"enum" });
    }

    pub fn get(index: *const Index, full_name: []const u8) Error!Entry {
        return index.entries.get(full_name) orelse error.UnknownType;
    }

    /// The Zig expression `from_file` names the type `full_name` with: its path in the same file,
    /// `proto.wkt.Name` for a well-known type, or the path behind the import of its file.
    pub fn reference(index: *const Index, arena: Allocator, from_file: []const u8, full_name: []const u8) Error![]const u8 {
        if (wkt_reference(full_name)) |short| return std.fmt.allocPrint(arena, "proto.wkt.{s}", .{short});
        const entry = try index.get(full_name);
        if (std.mem.eql(u8, entry.file, from_file)) return entry.zig_path;
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ try names.import_name(arena, entry.file), entry.zig_path });
    }

    /// Whether a singular field of message type `field_type` inside `container` closes a cycle of
    /// singular message fields, so the field must be a `proto.Lazy` to keep the struct finite.
    pub fn is_recursive(index: *const Index, arena: Allocator, container: []const u8, field_type: []const u8) Error!bool {
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        return index.reaches(arena, &visited, field_type, container);
    }

    fn reaches(index: *const Index, arena: Allocator, visited: *std.StringHashMapUnmanaged(void), from: []const u8, target: []const u8) Error!bool {
        if (std.mem.eql(u8, from, target)) return true;
        if (wkt_reference(from) != null) return false;
        if (visited.contains(from)) return false;
        try visited.put(arena, from, {});
        const entry = index.get(from) catch return false;
        const message = entry.message orelse return false;
        var fields = message.field.iterator();
        while (try fields.next()) |field| {
            if (field.label == .repeated or field.type != .message) continue;
            const type_name = strip_dot(field.type_name orelse continue);
            if (try index.reaches(arena, visited, type_name, target)) return true;
        }
        return false;
    }
};

pub fn strip_dot(type_name: []const u8) []const u8 {
    return if (type_name.len > 0 and type_name[0] == '.') type_name[1..] else type_name;
}

fn package_prefix(arena: Allocator, package: ?[]const u8) Allocator.Error![]const u8 {
    const name = package orelse return "";
    if (name.len == 0) return "";
    return std.fmt.allocPrint(arena, "{s}.", .{name});
}

fn wkt_reference(full_name: []const u8) ?[]const u8 {
    const prefix = "google.protobuf.";
    if (!std.mem.startsWith(u8, full_name, prefix)) return null;
    const short = full_name[prefix.len..];
    for (wkt_names) |name| {
        if (std.mem.eql(u8, name, short)) return name;
    }
    return null;
}
