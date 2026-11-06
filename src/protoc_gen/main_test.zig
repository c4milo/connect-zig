//! The plugin's tests: a CodeGeneratorRequest built with the runtime itself, as protoc sends it,
//! and the code the plugin writes for it. CI also runs `buf generate` over `examples/` and
//! compiles what it writes (design §8 step 6).
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const pb = @import("descriptor_pb.zig");
const main = @import("main.zig");

/// The file-length rule's limit on hand-written code (CLAUDE.md); generated code has none.
const hand_written_lines_max = 500;

fn field(name: []const u8, number: i32, kind: pb.Type, label: pb.Label) pb.FieldDescriptorProto {
    return .{ .name = name, .number = number, .type = kind, .label = label, .json_name = name };
}

fn generated(arena: std.mem.Allocator, request: *const pb.CodeGeneratorRequest) ![]const u8 {
    const files = try generated_files(arena, request);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("demo/v1/demo.pb.zig", files[0].name.?);
    return files[0].content.?;
}

fn generated_files(arena: std.mem.Allocator, request: *const pb.CodeGeneratorRequest) ![]const pb.GeneratedFile {
    const bytes = try proto.encode(pb.CodeGeneratorRequest, request, try arena.alloc(u8, try proto.encoded_len(pb.CodeGeneratorRequest, request)));
    const response = try main.respond(arena, bytes);
    if (response.@"error") |message| {
        std.debug.print("{s}\n", .{message});
        return error.GenerationFailed;
    }
    try testing.expectEqual(@as(?u64, pb.feature_proto3_optional | pb.feature_supports_editions), response.supported_features);
    try testing.expectEqual(@as(?i32, pb.edition_2024), response.maximum_edition);
    var files = response.file.iterator();
    var list: std.ArrayList(pb.GeneratedFile) = .empty;
    while (try files.next()) |output| try list.append(arena, output);
    return list.items;
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
    try expect_contains(text, ".{ .name = \"text\", .number = @intFromEnum(@This().FieldNumber.text), .kind = .string, .json_name = \"text\", .proto_name = \"text\", .oneof = \"choice\" },");
    try expect_contains(text, "    pub const FieldNumber = enum(u29) {\n        id = 1,\n        tags = 2,\n");
    try expect_contains(text, "            .map_entry = true,\n");
    try expect_contains(text, ".proto_name = \"loose\", .@\"packed\" = false },");
    try expect_contains(text, ".proto_name = \"tags\" },");
    try expect_contains(text, "    color_red = 1,\n    _,\n");
    try expect_contains(text, ".{ .name = \"COLOR_ROJO\", .number = @intFromEnum(@This().color_red) },");
    try expect_contains(text, "    pub const get_node: connect.Method = .{\n        .service = service_name,\n        .name = \"GetNode\",\n");
    try expect_contains(text, "        .stream_type = .server_stream,\n        .idempotency = .no_side_effects,\n");
    // Routes lists each method for a transport. GetNode has no side effects but is a stream,
    // and only a unary call may be a GET, so it has no GET route.
    try expect_contains(text, "    pub fn Routes(comptime transport: type, comptime App: type, comptime Handlers: type, comptime options: transport.RouteOptions) type {\n");
    try expect_contains(text, "                transport.post(App, get_node, Handlers.get_node, options),\n            };\n");
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

/// A message of `count` int64 fields, which takes about three lines a field once generated.
fn wide_message(arena: std.mem.Allocator, name: []const u8, count: usize) !pb.DescriptorProto {
    const fields = try arena.alloc(pb.FieldDescriptorProto, count);
    for (fields, 1..) |*each, number| {
        each.* = field(try std.fmt.allocPrint(arena, "f{d}", .{number}), @intCast(number), .int64, .optional);
    }
    return .{ .name = name, .field = .of(fields) };
}

test "a file past the hand-written line limit stays one file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var inner = try wide_message(arena, "Inner", 2);
    inner.enum_type = .of(&.{.{ .name = "Kind", .value = .of(&.{.{ .name = "KIND_A", .number = 0 }}) }});
    var outer = try wide_message(arena, "Outer", 100);
    outer.nested_type = .of(&.{inner});
    var link = field("link", 101, .message, .optional);
    link.type_name = ".demo.v1.Second";
    var kind = field("kind", 102, .@"enum", .optional);
    kind.type_name = ".demo.v1.Outer.Inner.Kind";
    var second = try wide_message(arena, "Second", 100);
    second.field = .of(try std.mem.concat(arena, pb.FieldDescriptorProto, &.{ second.field.items, &.{ link, kind } }));
    const file: pb.FileDescriptorProto = .{
        .name = "demo/v1/demo.proto",
        .package = "demo.v1",
        .message_type = .of(&.{ outer, second }),
        .service = .of(&.{.{ .name = "Demo", .method = .of(&.{.{ .name = "Get", .input_type = ".demo.v1.Outer", .output_type = ".demo.v1.Second" }}) }}),
        .syntax = "proto3",
    };
    const request: pb.CodeGeneratorRequest = .{ .file_to_generate = .of(&.{"demo/v1/demo.proto"}), .proto_file = .of(&.{file}) };
    const files = try generated_files(arena, &request);
    try testing.expectEqual(1, files.len);
    try testing.expectEqualStrings("demo/v1/demo.pb.zig", files[0].name.?);
    const content = files[0].content.?;
    // Longer than the hand-written code's limit, and still one file (decision 17).
    try testing.expect(std.mem.count(u8, content, "\n") > hand_written_lines_max);
    try expect_contains(content, "//! The build gives this file the modules protobuf, connect.\n");
    try expect_contains(content, "    pub const Inner = struct {\n");
    try expect_contains(content, "        pub const Kind = enum(i32) {\n");
    try expect_contains(content, "    link: proto.Lazy(Second) = .{},\n    kind: Outer.Inner.Kind = @enumFromInt(0),\n");
    try testing.expect(std.mem.indexOf(u8, content, "@import(\"demo/") == null);
}

test "a type of another file is named through that file's module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tag = field("tag", 1, .message, .optional);
    tag.type_name = ".shared.v1.Tag";
    const shared: pb.FileDescriptorProto = .{ .name = "shared/v1/shared.proto", .package = "shared.v1", .message_type = .of(&.{.{ .name = "Tag" }}), .syntax = "proto3" };
    const file: pb.FileDescriptorProto = .{
        .name = "demo/v1/demo.proto",
        .package = "demo.v1",
        .dependency = .of(&.{"shared/v1/shared.proto"}),
        .message_type = .of(&.{.{ .name = "Holder", .field = .of(&.{tag}) }}),
        .syntax = "proto3",
    };
    const request: pb.CodeGeneratorRequest = .{ .file_to_generate = .of(&.{"demo/v1/demo.proto"}), .proto_file = .of(&.{ shared, file }) };
    const text = try generated(arena, &request);
    try expect_contains(text, "//! The build gives this file the modules protobuf, shared_v1_shared.\n");
    try expect_contains(text, "const shared_v1_shared = @import(\"shared_v1_shared\");\n");
    try expect_contains(text, "    tag: ?shared_v1_shared.Tag = null,\n");
}

test "a file whose messages are delimited writes groups, but a map keeps its entries' lengths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entry_key = field("key", 1, .string, .optional);
    entry_key.label = .optional;
    var entry_value = field("value", 2, .message, .optional);
    entry_value.type_name = ".demo.v1.Note";
    const entry: pb.DescriptorProto = .{ .name = "NotesEntry", .field = .of(&.{ entry_key, entry_value }), .options = .{ .map_entry = true } };
    var note = field("note", 1, .message, .optional);
    note.type_name = ".demo.v1.Note";
    var notes = field("notes", 2, .message, .repeated);
    notes.type_name = ".demo.v1.Book.NotesEntry";
    const book: pb.DescriptorProto = .{ .name = "Book", .field = .of(&.{ note, notes }), .nested_type = .of(&.{entry}) };
    const file: pb.FileDescriptorProto = .{
        .name = "demo/v1/demo.proto",
        .package = "demo.v1",
        .message_type = .of(&.{ book, .{ .name = "Note" } }),
        .syntax = "editions",
        .edition = pb.edition_proto2 + 2,
        .options = .{ .features = .{ .message_encoding = pb.message_delimited } },
    };
    const request: pb.CodeGeneratorRequest = .{ .file_to_generate = .of(&.{"demo/v1/demo.proto"}), .proto_file = .of(&.{file}) };
    const content = try generated(arena, &request);
    try expect_contains(content, ".name = \"note\", .number = @intFromEnum(@This().FieldNumber.note), .kind = .group");
    try expect_contains(content, ".name = \"notes\", .number = @intFromEnum(@This().FieldNumber.notes), .kind = .message");
    // The entry's value keeps its length too, and its key has no presence.
    try expect_contains(content, ".name = \"value\", .number = @intFromEnum(@This().FieldNumber.value), .kind = .message");
    try expect_contains(content, "key: []const u8 = \"\",\n");
}
