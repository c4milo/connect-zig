//! Writes a message: its struct fields, its `FieldNumber` enum, its `protobuf` descriptor, and its
//! nested messages and enums. Each field number is a member of `FieldNumber`, so the generated
//! code names every number, as the magic-numbers rule asks of all code here.
const std = @import("std");
const Features = @import("features.zig").Features;
const Allocator = std.mem.Allocator;
const pb = @import("descriptor_pb.zig");
const names = @import("names.zig");
const index_file = @import("index.zig");
const generate_out = @import("generate_out.zig");
const generate_enum = @import("generate_enum.zig");
const Out = generate_out.Out;
const Error = generate_out.Error;

/// A message or enum a piece declares through an import, which gets a piece of its own.
pub const Pending = struct {
    /// Its full name's scope in the .proto file, "kitchen.v1.Tree".
    scope: []const u8,
    /// Its piece's name, the Zig path joined by dots: "Tree.Leaf".
    path: []const u8,
    declaration: union(enum) { message: pb.DescriptorProto, enumeration: pb.EnumDescriptorProto },
    /// The features in effect where it is declared.
    features: Features,
};

/// Where nested declarations go: inline, or into pieces of their own.
pub const Nesting = struct {
    pending: ?*std.ArrayList(Pending) = null,
    /// The piece name of the enclosing message, under which a nested one is named.
    path: []const u8 = "",
};

/// The name of the enum that numbers a message's fields.
const field_number_enum = "FieldNumber";

/// A field with the name the oneof's union holds it under, or none.
const Member = struct { field: pb.FieldDescriptorProto, oneof: ?[]const u8 };

pub fn write(out: *Out, scope: []const u8, message: pb.DescriptorProto, depth: usize, nesting: Nesting) Error!void {
    const name = message.name orelse "";
    const full = try generate_out.full_name(out.arena, scope, name);
    const fields = try collect_fields(out, message);
    try check_names(message);
    // The message's fields, and the messages nested in it, resolve features from its own.
    const enclosing = out.features;
    out.features = enclosing.of_message(message);
    defer out.features = enclosing;
    try out.print("\n", .{});
    try out.indent(depth);
    try out.print("pub const {s} = struct {{\n", .{try names.identifier(out.arena, name)});
    try write_struct_fields(out, full, fields, depth + 1);
    try write_unknown_field(out, message, depth + 1);
    try write_field_numbers(out, fields, depth + 1);
    try write_descriptor(out, full, message, fields, depth + 1);
    const path = if (nesting.path.len == 0) name else try std.fmt.allocPrint(out.arena, "{s}.{s}", .{ nesting.path, name });
    try write_nested(out, full, message, depth + 1, .{ .pending = nesting.pending, .path = path });
    try out.indent(depth);
    try out.print("}};\n", .{});
}

fn write_nested(out: *Out, full: []const u8, message: pb.DescriptorProto, depth: usize, nesting: Nesting) Error!void {
    var nested = message.nested_type.iterator();
    while (try nested.next()) |child| {
        const pending = nesting.pending orelse {
            try write(out, full, child, depth, nesting);
            continue;
        };
        const child_path = try std.fmt.allocPrint(out.arena, "{s}.{s}", .{ nesting.path, child.name orelse "" });
        try write_import(out, child.name orelse "", child_path, depth);
        try pending.append(out.arena, .{ .scope = full, .path = child_path, .declaration = .{ .message = child }, .features = out.features });
    }
    var enums = message.enum_type.iterator();
    while (try enums.next()) |enumeration| {
        const pending = nesting.pending orelse {
            try generate_enum.write(out, full, enumeration, depth);
            continue;
        };
        const child_path = try std.fmt.allocPrint(out.arena, "{s}.{s}", .{ nesting.path, enumeration.name orelse "" });
        try write_import(out, enumeration.name orelse "", child_path, depth);
        try pending.append(out.arena, .{ .scope = full, .path = child_path, .declaration = .{ .enumeration = enumeration }, .features = out.features });
    }
}

/// Declares a nested type that lives in a piece of its own: `pub const Leaf = @import(...).Leaf;`.
pub fn write_import(out: *Out, name: []const u8, path: []const u8, depth: usize) Error!void {
    const identifier = try names.identifier(out.arena, name);
    try out.print("\n", .{});
    try out.indent(depth);
    try out.print("pub const {s} = @import(\"{s}.pb.zig\").{s};\n", .{ identifier, path, identifier });
}

/// A nested declaration named `FieldNumber` would collide with the enum the generator adds.
fn check_names(message: pb.DescriptorProto) Error!void {
    var nested = message.nested_type.iterator();
    while (try nested.next()) |child| {
        if (std.mem.eql(u8, child.name orelse "", field_number_enum)) return error.NameCollision;
    }
    var enums = message.enum_type.iterator();
    while (try enums.next()) |enumeration| {
        if (std.mem.eql(u8, enumeration.name orelse "", field_number_enum)) return error.NameCollision;
    }
}

/// The message's fields, each with its real oneof's Zig name. A proto3 `optional` field sits in a
/// synthetic oneof, which the generator writes as a `?T` field instead.
fn collect_fields(out: *Out, message: pb.DescriptorProto) Error![]Member {
    var oneofs: std.ArrayList([]const u8) = .empty;
    var decls = message.oneof_decl.iterator();
    while (try decls.next()) |decl| try oneofs.append(out.arena, try names.field_identifier(out.arena, decl.name orelse ""));
    var members: std.ArrayList(Member) = .empty;
    var fields = message.field.iterator();
    while (try fields.next()) |field| {
        const synthetic = field.proto3_optional orelse false;
        const oneof: ?[]const u8 = if (field.oneof_index) |at| (if (synthetic) null else oneofs.items[@intCast(at)]) else null;
        try members.append(out.arena, .{ .field = field, .oneof = oneof });
    }
    return members.items;
}

fn write_struct_fields(out: *Out, full: []const u8, fields: []const Member, depth: usize) Error!void {
    for (fields, 0..) |member, at| {
        if (member.oneof) |oneof| {
            if (first_of_oneof(fields, at)) try write_oneof(out, full, fields, oneof, depth);
            continue;
        }
        const field = member.field;
        try out.indent(depth);
        const typed = try zig_type(out, full, field);
        try out.print("{s}: {s} = {s},\n", .{ try names.field_identifier(out.arena, field.name orelse ""), typed.text, typed.default });
    }
}

/// The struct field a generated message keeps the fields it does not know in, which the runtime
/// writes back (decision 24). A map entry keeps none: Go and C++ drop an entry's unknown fields.
const unknown_field = "_unknown";

fn write_unknown_field(out: *Out, message: pb.DescriptorProto, depth: usize) Error!void {
    const map_entry = if (message.options) |options| options.map_entry orelse false else false;
    if (map_entry) return;
    var fields = message.field.iterator();
    while (try fields.next()) |field| {
        if (std.mem.eql(u8, field.name orelse "", unknown_field)) return error.NameCollision;
    }
    try out.indent(depth);
    try out.print("{s}: proto.Unknown = .{{}},\n", .{unknown_field});
}

fn first_of_oneof(fields: []const Member, at: usize) bool {
    for (fields[0..at]) |earlier| {
        if (earlier.oneof != null and std.mem.eql(u8, earlier.oneof.?, fields[at].oneof.?)) return false;
    }
    return true;
}

fn write_oneof(out: *Out, full: []const u8, fields: []const Member, oneof: []const u8, depth: usize) Error!void {
    try out.indent(depth);
    try out.print("{s}: ?union(enum) {{\n", .{oneof});
    for (fields) |member| {
        const name = member.oneof orelse continue;
        if (!std.mem.eql(u8, name, oneof)) continue;
        try out.indent(depth + 1);
        try out.print("{s}: {s},\n", .{ try names.field_identifier(out.arena, member.field.name orelse ""), try value_type(out, full, member.field) });
    }
    try out.indent(depth);
    try out.print("}} = null,\n", .{});
}

/// The type of one value of a field, without repetition or presence.
fn value_type(out: *Out, container: []const u8, field: pb.FieldDescriptorProto) Error![]const u8 {
    const kind = field.type orelse return error.UnknownType;
    return switch (kind) {
        .int32, .sint32, .sfixed32 => "i32",
        .int64, .sint64, .sfixed64 => "i64",
        .uint32, .fixed32 => "u32",
        .uint64, .fixed64 => "u64",
        .float => "f32",
        .double => "f64",
        .bool => "bool",
        .string, .bytes => "[]const u8",
        .@"enum" => out.reference(index_file.strip_dot(field.type_name orelse "")),
        .message, .group => message_type(out, container, field),
        else => error.UnknownType,
    };
}

fn message_type(out: *Out, container: []const u8, field: pb.FieldDescriptorProto) Error![]const u8 {
    const target = index_file.strip_dot(field.type_name orelse "");
    const reference = try out.reference(target);
    if (field.label == .repeated) return reference;
    if (try out.index.is_recursive(out.arena, container, target)) return std.fmt.allocPrint(out.arena, "proto.Lazy({s})", .{reference});
    return reference;
}

/// A field's Zig type and the default value its struct field takes.
const Typed = struct { text: []const u8, default: []const u8 };

fn zig_type(out: *Out, container: []const u8, field: pb.FieldDescriptorProto) Error!Typed {
    if (field.label == .repeated) {
        const value = try value_type(out, container, field);
        return .{ .text = try std.fmt.allocPrint(out.arena, "proto.Repeated({s}, .{s})", .{ value, try field_kind(out, field) }), .default = ".{}" };
    }
    if (field.type == .message or field.type == .group) {
        const target = index_file.strip_dot(field.type_name orelse "");
        const reference = try out.reference(target);
        // A message that contains itself, at any depth, is held as `proto.Lazy`: a struct
        // cannot contain itself by value.
        if (try out.index.is_recursive(out.arena, container, target)) return .{ .text = try std.fmt.allocPrint(out.arena, "proto.Lazy({s})", .{reference}), .default = ".{}" };
        return .{ .text = try std.fmt.allocPrint(out.arena, "?{s}", .{reference}), .default = "null" };
    }
    const value = try value_type(out, container, field);
    if (has_presence(out, field)) return .{ .text = try std.fmt.allocPrint(out.arena, "?{s}", .{value}), .default = "null" };
    return .{ .text = value, .default = switch (field.type.?) {
        .string, .bytes => "\"\"",
        .bool => "false",
        .@"enum" => "@enumFromInt(0)",
        else => "0",
    } };
}

/// Whether a scalar field has explicit presence: proto3 `optional`, or a proto2 singular field
/// outside a oneof (language guide, "Field Presence").
fn has_presence(out: *const Out, field: pb.FieldDescriptorProto) bool {
    if (field.proto3_optional orelse false) return true;
    if (field.label == .repeated or field.oneof_index != null) return false;
    // proto2 and editions give a singular field presence; proto3 and IMPLICIT do not.
    return out.features.of_field(field).explicit_presence;
}

/// Whether a repeated packable field is written unpacked: proto3 packs unless the field says
/// `packed = false`, and proto2 packs only when it says `packed = true` ("Packed Repeated Fields").
fn unpacked(out: *const Out, field: pb.FieldDescriptorProto) bool {
    if (field.label != .repeated) return false;
    switch (field.type orelse return false) {
        .string, .bytes, .message, .group => return false,
        else => {},
    }
    const stated: ?bool = if (field.options) |options| options.@"packed" else null;
    if (stated) |packed_flag| return !packed_flag;
    return !out.features.of_field(field).@"packed";
}

/// The runtime's kind of a field: its type's name, but `group` for a proto2 group and for a
/// message field whose `message_encoding` is DELIMITED. A map's entries are always written with
/// a length (editions, "message_encoding").
fn field_kind(out: *const Out, field: pb.FieldDescriptorProto) Error![]const u8 {
    const kind = field.type orelse return error.UnknownType;
    if (kind == .message and out.features.of_field(field).delimited and !try is_map(out, field)) return "group";
    // Editions, "utf8_validation": NONE, as every proto2 string has, leaves the octets unchecked.
    if (kind == .string and !out.features.of_field(field).verify_utf8) return "unvalidated_string";
    return kind_name(kind);
}

fn is_map(out: *const Out, field: pb.FieldDescriptorProto) Error!bool {
    if (field.label != .repeated) return false;
    const entry = try out.index.get(index_file.strip_dot(field.type_name orelse ""));
    const message = entry.message orelse return false;
    const options = message.options orelse return false;
    return options.map_entry orelse false;
}

pub fn kind_name(kind: pb.Type) []const u8 {
    return switch (kind) {
        .@"enum" => "@\"enum\"",
        else => @tagName(kind),
    };
}

/// `pub const FieldNumber = enum(u29) { name = number, ... };`: a field number takes 29 bits
/// ("Field Numbers"), and each is named once here.
fn write_field_numbers(out: *Out, fields: []const Member, depth: usize) Error!void {
    if (fields.len == 0) return;
    try out.print("\n", .{});
    try out.indent(depth);
    try out.print("pub const {s} = enum(u29) {{\n", .{field_number_enum});
    for (fields) |member| {
        try out.indent(depth + 1);
        try out.print("{s} = {d},\n", .{ try names.field_identifier(out.arena, member.field.name orelse ""), member.field.number orelse 0 });
    }
    try out.indent(depth);
    try out.print("}};\n", .{});
}

fn write_descriptor(out: *Out, full: []const u8, message: pb.DescriptorProto, fields: []const Member, depth: usize) Error!void {
    const sorted = try out.arena.dupe(Member, fields);
    std.mem.sort(Member, sorted, {}, by_number);
    const map_entry = if (message.options) |options| options.map_entry orelse false else false;
    // zig fmt keeps no blank line at the top of a struct, so a message with no fields has none.
    if (fields.len != 0) try out.print("\n", .{});
    try out.indent(depth);
    try out.print("pub const protobuf: proto.Descriptor = .{{\n", .{});
    try out.indent(depth + 1);
    try out.print(".full_name = {s},\n", .{try names.string_literal(out.arena, full)});
    if (map_entry) {
        try out.indent(depth + 1);
        try out.print(".map_entry = true,\n", .{});
    }
    try out.indent(depth + 1);
    if (sorted.len == 0) {
        try out.print(".fields = &.{{}},\n", .{});
    } else {
        try out.print(".fields = &.{{\n", .{});
        for (sorted) |member| try write_field_entry(out, member, depth + 1 + 1);
        try out.indent(depth + 1);
        try out.print("}},\n", .{});
    }
    try out.indent(depth);
    try out.print("}};\n", .{});
}

fn by_number(_: void, a: Member, b: Member) bool {
    return (a.field.number orelse 0) < (b.field.number orelse 0);
}

fn write_field_entry(out: *Out, member: Member, depth: usize) Error!void {
    const field = member.field;
    const name = field.name orelse "";
    try out.indent(depth);
    try out.print(".{{ .name = {s}, .number = @intFromEnum(@This().{s}.{s}), .kind = .{s}, .json_name = {s}, .proto_name = {s}", .{
        try names.string_literal(out.arena, name),
        field_number_enum,
        try names.field_identifier(out.arena, name),
        try field_kind(out, field),
        try names.string_literal(out.arena, field.json_name orelse name),
        try names.string_literal(out.arena, name),
    });
    if (member.oneof) |oneof| try out.print(", .oneof = {s}", .{try names.string_literal(out.arena, generate_out.unescaped(oneof))});
    if (unpacked(out, field)) try out.print(", .@\"packed\" = false", .{});
    try out.print(" }},\n", .{});
}
