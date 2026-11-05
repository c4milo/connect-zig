//! The plugin's tests: a CodeGeneratorRequest built with the runtime itself, as protoc sends it,
//! and the code the plugin writes for it. CI also runs `buf generate` over `examples/` and
//! compiles what it writes (design §8 step 6).
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const pb = @import("descriptor_pb.zig");
const main = @import("main.zig");

fn field(name: []const u8, number: i32, kind: pb.Type, label: pb.Label) pb.FieldDescriptorProto {
    return .{ .name = name, .number = number, .type = kind, .label = label, .json_name = name };
}

fn generated(arena: std.mem.Allocator, request: *const pb.CodeGeneratorRequest) ![]const u8 {
    const bytes = try proto.encode(pb.CodeGeneratorRequest, request, try arena.alloc(u8, try proto.encoded_len(pb.CodeGeneratorRequest, request)));
    const response = try main.respond(arena, bytes);
    if (response.@"error") |message| {
        std.debug.print("{s}\n", .{message});
        return error.GenerationFailed;
    }
    try testing.expectEqual(@as(?u64, 1), response.supported_features);
    var files = response.file.iterator();
    const first = (try files.next()).?;
    try testing.expectEqualStrings("demo/v1/demo.pb.zig", first.name.?);
    return first.content.?;
}

fn expect_contains(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ part, text });
        return error.TestExpectedContains;
    }
}

test "messages, enums, oneofs, maps, recursion and services are generated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry: pb.DescriptorProto = .{
        .name = "LabelsEntry",
        .field = .of(&.{ field("key", 1, .string, .optional), field("value", 2, .string, .optional) }),
        .options = .{ .map_entry = true },
    };
    var choice_text = field("text", 6, .string, .optional);
    choice_text.oneof_index = 0;
    var choice_number = field("number", 7, .int32, .optional);
    choice_number.oneof_index = 0;
    var maybe = field("maybe", 8, .int64, .optional);
    maybe.oneof_index = 1;
    maybe.proto3_optional = true;
    var next = field("next", 3, .message, .optional);
    next.type_name = ".demo.v1.Node";
    var labels = field("labels", 4, .message, .repeated);
    labels.type_name = ".demo.v1.Node.LabelsEntry";
    var color = field("color", 5, .@"enum", .optional);
    color.type_name = ".demo.v1.Color";
    var loose = field("loose", 10, .int32, .repeated);
    loose.options = .{ .@"packed" = false };
    var stamp = field("type", 9, .message, .optional);
    stamp.type_name = ".google.protobuf.Timestamp";
    const node: pb.DescriptorProto = .{
        .name = "Node",
        .field = .of(&.{ field("id", 1, .uint64, .optional), field("tags", 2, .string, .repeated), next, labels, color, choice_text, choice_number, maybe, stamp, loose }),
        .nested_type = .of(&.{entry}),
        .oneof_decl = .of(&.{ .{ .name = "choice" }, .{ .name = "_maybe" } }),
    };
    const enumeration: pb.EnumDescriptorProto = .{ .name = "Color", .value = .of(&.{
        .{ .name = "COLOR_UNSPECIFIED", .number = 0 }, .{ .name = "COLOR_RED", .number = 1 }, .{ .name = "COLOR_ROJO", .number = 1 },
    }) };
    const method: pb.MethodDescriptorProto = .{
        .name = "GetNode",
        .input_type = ".demo.v1.Node",
        .output_type = ".demo.v1.Node",
        .server_streaming = true,
        .options = .{ .idempotency_level = .no_side_effects },
    };
    const file: pb.FileDescriptorProto = .{
        .name = "demo/v1/demo.proto",
        .package = "demo.v1",
        .dependency = .of(&.{"google/protobuf/timestamp.proto"}),
        .message_type = .of(&.{node}),
        .enum_type = .of(&.{enumeration}),
        .service = .of(&.{.{ .name = "NodeService", .method = .of(&.{method}) }}),
        .syntax = "proto3",
    };
    const request: pb.CodeGeneratorRequest = .{ .file_to_generate = .of(&.{"demo/v1/demo.proto"}), .proto_file = .of(&.{file}) };
    const text = try generated(arena, &request);
    try expect_contains(text, "pub const Node = struct {\n    id: u64 = 0,\n    tags: proto.Repeated([]const u8, .string) = .{},\n");
    try expect_contains(text, "    next: proto.Lazy(Node) = .{},\n");
    try expect_contains(text, "    labels: proto.Repeated(Node.LabelsEntry, .message) = .{},\n");
    try expect_contains(text, "    color: Color = @enumFromInt(0),\n");
    try expect_contains(text, "    choice: ?union(enum) {\n        text: []const u8,\n        number: i32,\n    } = null,\n");
    try expect_contains(text, "    maybe: ?i64 = null,\n");
    try expect_contains(text, "    type: ?proto.wkt.Timestamp = null,\n");
    try expect_contains(text, ".{ .name = \"text\", .number = 6, .kind = .string, .json_name = \"text\", .proto_name = \"text\", .oneof = \"choice\" },");
    try expect_contains(text, "            .map_entry = true,\n");
    try expect_contains(text, ".proto_name = \"loose\", .@\"packed\" = false },");
    try expect_contains(text, ".proto_name = \"tags\" },");
    try expect_contains(text, "    color_red = 1,\n    _,\n");
    try expect_contains(text, ".{ .name = \"COLOR_ROJO\", .number = 1 },");
    try expect_contains(text, "    pub const get_node: connect.Method = .{\n        .service = service_name,\n        .name = \"GetNode\",\n");
    try expect_contains(text, "        .stream_type = .server_stream,\n        .idempotency = .no_side_effects,\n");
}

test "a request that names a missing file gets an error response" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request: pb.CodeGeneratorRequest = .{ .file_to_generate = .of(&.{"none.proto"}) };
    const bytes = try proto.encode(pb.CodeGeneratorRequest, &request, try arena.alloc(u8, 64));
    const response = try main.respond(arena, bytes);
    try testing.expectEqualStrings("protoc-gen-connect-zig: MissingFile", response.@"error".?);
}
