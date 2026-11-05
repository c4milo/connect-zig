//! Writes the code of one .proto file (design §8 step 6). The output is a pure function of the
//! request, so `buf generate` writes the same octets on every host, which CI compares with the
//! committed code.
//!
//! A file of at most `file_lines_max` lines is written whole, as `<file>.pb.zig`. A longer one is
//! split, so every file stays under the file-length rule: `<file>.pb.zig` then re-exports each
//! top-level declaration from `<file>/<Name>.pb.zig`, and a nested declaration has a piece of its
//! own, `<file>/<Outer>.<Name>.pb.zig`. A piece reaches its siblings by name, beside it, and the
//! other generated files through their modules, so no import climbs with `../`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const pb = @import("descriptor_pb.zig");
const names = @import("names.zig");
const index_file = @import("index.zig");
const generate_out = @import("generate_out.zig");
const generate_message = @import("generate_message.zig");
const generate_enum = @import("generate_enum.zig");
const Index = index_file.Index;
const Out = generate_out.Out;
const Pending = generate_message.Pending;

pub const Error = generate_out.Error;

/// The longest file the generator writes whole: the file-length rule's limit (CLAUDE.md).
pub const file_lines_max = 500;

pub const Output = struct { name: []const u8, content: []const u8 };

pub fn file(arena: Allocator, index: *const Index, descriptor: pb.FileDescriptorProto) Error![]const Output {
    const path = try names.output_path(arena, descriptor.name orelse "");
    const single = try render_single(arena, index, descriptor);
    if (std.mem.count(u8, single, "\n") <= file_lines_max) {
        const outputs = try arena.alloc(Output, 1);
        outputs[0] = .{ .name = path, .content = single };
        return outputs;
    }
    return render_pieces(arena, index, descriptor, path);
}

fn new_out(arena: Allocator, index: *const Index, descriptor: pb.FileDescriptorProto, mode: generate_out.Mode) Out {
    const syntax = descriptor.syntax orelse "proto2";
    return .{ .arena = arena, .index = index, .file = descriptor.name orelse "", .proto2 = std.mem.eql(u8, syntax, "proto2"), .mode = mode };
}

fn render_single(arena: Allocator, index: *const Index, descriptor: pb.FileDescriptorProto) Error![]const u8 {
    var out = new_out(arena, index, descriptor, .single);
    const package = descriptor.package orelse "";
    var messages = descriptor.message_type.iterator();
    while (try messages.next()) |message| try generate_message.write(&out, package, message, 0, .{});
    var enums = descriptor.enum_type.iterator();
    while (try enums.next()) |enumeration| try generate_enum.write(&out, package, enumeration, 0);
    var services = descriptor.service.iterator();
    while (try services.next()) |service| try generate_enum.write_service(&out, package, service);
    return out.assemble(null);
}

fn render_pieces(arena: Allocator, index: *const Index, descriptor: pb.FileDescriptorProto, path: []const u8) Error![]const Output {
    const stem = path[0 .. path.len - ".pb.zig".len];
    const directory = std.fs.path.basenamePosix(stem);
    const package = descriptor.package orelse "";
    var outputs: std.ArrayList(Output) = .empty;
    var pending: std.ArrayList(Pending) = .empty;
    var root = new_out(arena, index, descriptor, .piece);
    try root.print("\n", .{});
    var messages = descriptor.message_type.iterator();
    while (try messages.next()) |message| {
        try pending.append(arena, .{ .scope = package, .path = message.name orelse "", .declaration = .{ .message = message } });
        try write_reexport(&root, directory, message.name orelse "");
    }
    var enums = descriptor.enum_type.iterator();
    while (try enums.next()) |enumeration| {
        try pending.append(arena, .{ .scope = package, .path = enumeration.name orelse "", .declaration = .{ .enumeration = enumeration } });
        try write_reexport(&root, directory, enumeration.name orelse "");
    }
    var services = descriptor.service.iterator();
    while (try services.next()) |service| {
        var piece = new_out(arena, index, descriptor, .piece);
        try generate_enum.write_service(&piece, package, service);
        try outputs.append(arena, .{ .name = try piece_name(arena, stem, service.name orelse ""), .content = try piece.assemble(null) });
        try write_reexport(&root, directory, service.name orelse "");
        try merge_modules(&root, &piece);
    }
    // Each piece may add the pieces of its nested declarations, so the list grows as it is read.
    var at: usize = 0;
    while (at < pending.items.len) : (at += 1) {
        const item = pending.items[at];
        const content = try render_piece(arena, index, descriptor, item, &pending, &root);
        try outputs.append(arena, .{ .name = try piece_name(arena, stem, item.path), .content = content });
    }
    // The pieces are files of the root's module, so its header names every module they import.
    try outputs.append(arena, .{ .name = path, .content = try root.assemble(null) });
    return outputs.items;
}

fn merge_modules(root: *Out, piece: *const Out) Error!void {
    root.uses_connect = root.uses_connect or piece.uses_connect;
    for (piece.used_modules.keys()) |module| try root.used_modules.put(root.arena, module, {});
}

fn render_piece(arena: Allocator, index: *const Index, descriptor: pb.FileDescriptorProto, item: Pending, pending: *std.ArrayList(Pending), root: *Out) Error![]const u8 {
    var piece = new_out(arena, index, descriptor, .piece);
    const parent_end = std.mem.lastIndexOfScalar(u8, item.path, '.');
    const parent = if (parent_end) |end| item.path[0..end] else "";
    switch (item.declaration) {
        .message => |message| try generate_message.write(&piece, item.scope, message, 0, .{ .pending = pending, .path = parent }),
        .enumeration => |enumeration| try generate_enum.write(&piece, item.scope, enumeration, 0),
    }
    // A top-level piece declares its own name, which it does not import; a nested one reaches
    // its outer declarations through the top-level one's sibling.
    const own_root = if (parent_end == null) try names.identifier(arena, item.path) else null;
    try merge_modules(root, &piece);
    return piece.assemble(own_root);
}

fn write_reexport(root: *Out, directory: []const u8, name: []const u8) Error!void {
    const identifier = try names.identifier(root.arena, name);
    try root.print("pub const {s} = @import(\"{s}/{s}.pb.zig\").{s};\n", .{ identifier, directory, name, identifier });
}

fn piece_name(arena: Allocator, stem: []const u8, path: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}.pb.zig", .{ stem, path });
}
