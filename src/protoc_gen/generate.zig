//! Writes the code of one .proto file (design §8 step 6). The output is a pure function of the
//! request, so `buf generate` writes the same octets on every host, which CI compares with the
//! committed code.
//!
//! Each .proto file becomes one `<file>.pb.zig`, whatever its length, as protoc-gen-go and
//! prost-build write one file per input (decision 17).
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

pub const Error = generate_out.Error;

pub const Output = struct { name: []const u8, content: []const u8 };

pub fn file(arena: Allocator, index: *const Index, descriptor: pb.FileDescriptorProto) Error![]const Output {
    var out: Out = .{ .arena = arena, .index = index, .file = descriptor.name orelse "", .features = .of_file(descriptor) };
    const package = descriptor.package orelse "";
    var messages = descriptor.message_type.iterator();
    while (try messages.next()) |message| try generate_message.write(&out, package, message, 0);
    var enums = descriptor.enum_type.iterator();
    while (try enums.next()) |enumeration| try generate_enum.write(&out, package, enumeration, 0);
    var services = descriptor.service.iterator();
    while (try services.next()) |service| try generate_enum.write_service(&out, package, service);
    const outputs = try arena.alloc(Output, 1);
    outputs[0] = .{ .name = try names.output_path(arena, descriptor.name orelse ""), .content = try out.assemble() };
    return outputs;
}
