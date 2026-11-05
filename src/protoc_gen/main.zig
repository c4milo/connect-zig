//! protoc-gen-connect-zig: the protoc plugin `buf generate` runs. It reads a CodeGeneratorRequest
//! from stdin and writes a CodeGeneratorResponse to stdout, with one `<file>.pb.zig` for each file
//! to generate (design §8 step 6). It is a program, not the library, so it reads stdio and
//! allocates from the arena `std.process.Init` gives it (decision 4).
const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("protobuf");
const pb = @import("descriptor_pb.zig");
const names = @import("names.zig");
const index_file = @import("index.zig");
const generate = @import("generate.zig");

/// The most bytes of request the plugin reads: protoc's requests for large trees stay far below.
const request_len_max = 256 * 1024 * 1024;
const io_buffer_len = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var input_buffer: [io_buffer_len]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &input_buffer);
    const request_bytes = try stdin.interface.allocRemaining(arena, .limited(request_len_max));
    const response = try respond(arena, request_bytes);
    const len = try proto.encoded_len(pb.CodeGeneratorResponse, &response);
    const encoded = try proto.encode(pb.CodeGeneratorResponse, &response, try arena.alloc(u8, len));
    var output_buffer: [io_buffer_len]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
    try stdout.interface.writeAll(encoded);
    try stdout.interface.flush();
}

/// The response to a request: the generated files, or the error that stopped the generation,
/// which protoc prints.
pub fn respond(arena: Allocator, request_bytes: []const u8) Allocator.Error!pb.CodeGeneratorResponse {
    const files = generate_all(arena, request_bytes) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .@"error" = try std.fmt.allocPrint(arena, "protoc-gen-connect-zig: {s}", .{@errorName(failure)}),
            .supported_features = pb.feature_proto3_optional,
        },
    };
    return .{ .supported_features = pb.feature_proto3_optional, .file = .of(files) };
}

fn generate_all(arena: Allocator, request_bytes: []const u8) (index_file.Error || error{MissingFile})![]const pb.GeneratedFile {
    const request = try proto.decode(pb.CodeGeneratorRequest, request_bytes);
    var descriptors: std.ArrayList(pb.FileDescriptorProto) = .empty;
    var proto_files = request.proto_file.iterator();
    while (try proto_files.next()) |descriptor| try descriptors.append(arena, descriptor);
    const index = try index_file.Index.build(arena, descriptors.items);
    var outputs: std.ArrayList(pb.GeneratedFile) = .empty;
    var wanted = request.file_to_generate.iterator();
    while (try wanted.next()) |path| {
        const descriptor = find(descriptors.items, path) orelse return error.MissingFile;
        const content = try generate.file(arena, &index, descriptor);
        try outputs.append(arena, .{ .name = try names.output_path(arena, path), .content = content });
    }
    return outputs.items;
}

fn find(descriptors: []const pb.FileDescriptorProto, path: []const u8) ?pb.FileDescriptorProto {
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.name orelse "", path)) return descriptor;
    }
    return null;
}

test {
    _ = names;
    _ = @import("main_test.zig");
}
