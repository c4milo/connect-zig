//! The plugin's tests of protovalidate's rules (decision 47): a CodeGeneratorRequest whose
//! options hold `buf.validate` extensions, and the table the plugin writes for each message.
const std = @import("std");
const testing = std.testing;
const proto = @import("protobuf");
const pb = @import("descriptor_pb.zig");
const main = @import("main.zig");

fn field(name: []const u8, number: i32, kind: pb.Type, label: pb.Label) pb.FieldDescriptorProto {
    return .{ .name = name, .number = number, .type = kind, .label = label, .json_name = name };
}

/// The response to a request of one file, demo/v1/demo.proto, that holds `messages`.
fn respond(arena: std.mem.Allocator, messages: []const pb.DescriptorProto) !pb.CodeGeneratorResponse {
    return respond_extended(arena, messages, &.{});
}

/// The response to a request of one file that holds `messages` and declares `extensions`.
fn respond_extended(arena: std.mem.Allocator, messages: []const pb.DescriptorProto, extensions: []const pb.FieldDescriptorProto) !pb.CodeGeneratorResponse {
    const file: pb.FileDescriptorProto = .{ .name = "demo/v1/demo.proto", .package = "demo.v1", .message_type = .of(messages), .extension = .of(extensions), .syntax = "proto3" };
    const request: pb.CodeGeneratorRequest = .{ .file_to_generate = .of(&.{"demo/v1/demo.proto"}), .proto_file = .of(&.{file}) };
    const bytes = try proto.encode(pb.CodeGeneratorRequest, &request, try arena.alloc(u8, try proto.encoded_len(pb.CodeGeneratorRequest, &request)));
    return main.respond(arena, bytes);
}

fn generated(arena: std.mem.Allocator, messages: []const pb.DescriptorProto) ![]const u8 {
    const response = try respond(arena, messages);
    if (response.@"error") |message| {
        std.debug.print("{s}\n", .{message});
        return error.GenerationFailed;
    }
    var files = response.file.iterator();
    return (try files.next()).?.content.?;
}

fn expect_contains(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ part, text });
        return error.TestExpectedContains;
    }
}

fn expect_absent(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) != null) {
        std.debug.print("unexpected:\n{s}\nin:\n{s}\n", .{ part, text });
        return error.TestExpectedAbsent;
    }
}

test "a message's rules are written as its table, and their numbers as RuleNumber" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var name = field("name", 1, .string, .optional);
    name.options = .{ .rules = .{ .type = .{ .string = .{ .min_len = 1, .max_len = 64 } } } };
    var age = field("age", 2, .int32, .optional);
    age.options = .{ .rules = .{ .required = true, .type = .{ .int32 = .{ .greater_than = .{ .gte = 18 } } } } };
    var text = field("text", 3, .string, .optional);
    text.oneof_index = 0;
    const user: pb.DescriptorProto = .{
        .name = "User",
        .field = .of(&.{ name, age, text, field("plain", 4, .bool, .optional) }),
        .oneof_decl = .of(&.{.{ .name = "choice", .options = .{ .rules = .{ .required = true } } }}),
        .options = .{ .rules = .{ .oneof = .of(&.{.{ .fields = .of(&.{ "name", "plain" }), .required = true }}) } },
    };
    const code = try generated(arena, &.{user});
    try expect_contains(code, "//! The build gives this file the modules protobuf, protovalidate.\nconst proto = @import(\"protobuf\");\nconst validate = @import(\"protovalidate\");\n");
    try expect_contains(code,
        \\    pub const protovalidate: validate.Rules = .{
        \\        .message = .{ .oneof = .of(&.{.{ .fields = .of(&.{ "name", "plain" }), .required = true }}) },
        \\        .fields = &.{
        \\            .{ .number = @intFromEnum(@This().FieldNumber.name), .rules = .{ .type = .{ .string = .{ .min_len = 1, .max_len = @This().RuleNumber.@"name.string.max_len" } } } },
        \\            .{ .number = @intFromEnum(@This().FieldNumber.age), .rules = .{ .type = .{ .int32 = .{ .greater_than = .{ .gte = @This().RuleNumber.@"age.int32.gte" } } }, .required = true } },
        \\        },
        \\        .oneofs = &.{
        \\            .{ .field = "choice", .name = "choice", .rules = .{ .required = true } },
        \\        },
        \\    };
        \\
        \\    pub const RuleNumber = struct {
        \\        pub const @"name.string.max_len" = 64;
        \\        pub const @"age.int32.gte" = 18;
        \\    };
        \\
    );
}

test "a message with no rule keeps its code, and one that holds a message with rules gets an empty table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var checked_value = field("value", 1, .string, .optional);
    checked_value.options = .{ .rules = .{ .type = .{ .string = .{ .min_len = 1 } } } };
    const checked: pb.DescriptorProto = .{ .name = "Checked", .field = .of(&.{checked_value}) };
    var held = field("held", 1, .message, .optional);
    held.type_name = ".demo.v1.Checked";
    const holder: pb.DescriptorProto = .{ .name = "Holder", .field = .of(&.{held}) };
    // A message that holds itself and no rule reaches none: the walk ends at the cycle.
    var next = field("next", 1, .message, .optional);
    next.type_name = ".demo.v1.Loop";
    const loop: pb.DescriptorProto = .{ .name = "Loop", .field = .of(&.{next}) };
    const plain: pb.DescriptorProto = .{ .name = "Plain", .field = .of(&.{field("value", 1, .string, .optional)}) };

    const code = try generated(arena, &.{ checked, holder, loop, plain });
    try expect_contains(code, "pub const Holder = struct {");
    try expect_contains(code, "    pub const protovalidate: validate.Rules = .{};\n");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, code, "pub const protovalidate"));

    const without = try generated(arena, &.{ loop, plain });
    try expect_absent(without, "protovalidate");
    try expect_absent(without, "RuleNumber");
    try expect_contains(without, "//! The build gives this file the modules protobuf.\nconst proto = @import(\"protobuf\");\n\npub const Loop");
}

test "a rule of the message alone, of a field alone or of a oneof alone gives a table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const of_message: pb.DescriptorProto = .{ .name = "OfMessage", .options = .{ .rules = .{ .oneof = .of(&.{.{ .required = true }}) } } };
    try expect_contains(try generated(arena, &.{of_message}), "        .message = .{ .oneof = .of(&.{.{ .required = true }}) },\n");
    var value = field("value", 1, .bool, .optional);
    value.options = .{ .rules = .{ .required = true } };
    const of_field: pb.DescriptorProto = .{ .name = "OfField", .field = .of(&.{value}) };
    try expect_contains(try generated(arena, &.{of_field}), "        .fields = &.{\n");
    var member = field("member", 1, .bool, .optional);
    member.oneof_index = 0;
    const of_oneof: pb.DescriptorProto = .{ .name = "OfOneof", .field = .of(&.{member}), .oneof_decl = .of(&.{.{ .name = "protobuf", .options = .{ .rules = .{ .required = true } } }}) };
    // The union field of a oneof named `protobuf` is `protobuf_`, and its path states `protobuf`.
    try expect_contains(try generated(arena, &.{of_oneof}), "        .oneofs = &.{\n            .{ .field = \"protobuf_\", .name = \"protobuf\", .rules = .{ .required = true } },\n        },\n");
}

test "a group's message counts for the message that holds it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var value = field("value", 1, .bool, .optional);
    value.options = .{ .rules = .{ .required = true } };
    const group: pb.DescriptorProto = .{ .name = "Part", .field = .of(&.{value}) };
    var part = field("part", 1, .group, .optional);
    part.type_name = ".demo.v1.Whole.Part";
    const whole: pb.DescriptorProto = .{ .name = "Whole", .field = .of(&.{part}), .nested_type = .of(&.{group}) };
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, try generated(arena, &.{whole}), "pub const protovalidate"));
}

test "a map entry gets no table, and its field's message counts for the message that holds it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var checked_value = field("value", 1, .string, .optional);
    checked_value.options = .{ .rules = .{ .type = .{ .string = .{ .min_len = 1 } } } };
    const checked: pb.DescriptorProto = .{ .name = "Checked", .field = .of(&.{checked_value}) };
    var entry_value = field("value", 2, .message, .optional);
    entry_value.type_name = ".demo.v1.Checked";
    const entry: pb.DescriptorProto = .{ .name = "ByNameEntry", .field = .of(&.{ field("key", 1, .string, .optional), entry_value }), .options = .{ .map_entry = true } };
    var by_name = field("by_name", 1, .message, .repeated);
    by_name.type_name = ".demo.v1.Index.ByNameEntry";
    const index: pb.DescriptorProto = .{ .name = "Index", .field = .of(&.{by_name}), .nested_type = .of(&.{entry}) };
    const code = try generated(arena, &.{ checked, index });
    // Checked's table and Index's, and none in the entry.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, code, "pub const protovalidate"));
    const entry_code = code[std.mem.indexOf(u8, code, "pub const ByNameEntry").?..];
    try expect_absent(entry_code, "protovalidate");
}

test "a rule the plugin's types do not know marks the table unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Field 1161 of StringRules: an extension's predefined rule.
    const string_rules = [_]u8{ 0xc8, 0x48, 0x01 };
    const field_rules = [_]u8{ 0x72, string_rules.len } ++ string_rules;
    var value = field("value", 1, .string, .optional);
    value.options = .{ .rules = try proto.decode(@import("buf_validate_validate").FieldRules, &field_rules) };
    const code = try generated(arena, &.{.{ .name = "Extended", .field = .of(&.{value}) }});
    try expect_contains(code, "        .unsupported = \"buf.validate.StringRules holds field 1161, which neither the plugin's validate.proto nor an extension of the request states\",\n");
}

test "a predefined rule of an extension is written with the entry of the field that holds it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const validate = @import("buf_validate_validate");
    // extend buf.validate.Int32Rules { optional bool even = 1161 [(buf.validate.predefined).cel = { ... }]; }
    const even_number = 1161;
    const even: pb.FieldDescriptorProto = .{
        .name = "even",
        .extendee = ".buf.validate.Int32Rules",
        .number = even_number,
        .type = .bool,
        .label = .optional,
        .options = .{ .predefined = .{ .cel = .of(&.{.{ .id = "int32.even", .message = "must be even", .expression = "!rule || this % 2 == 0" }}) } },
    };
    // `(even) = true` in an Int32Rules: field 1161, a varint of 1.
    const even_record = [_]u8{ 0xc8, 0x48, 0x01 };
    const int32_rules: validate.Int32Rules = .{ .greater_than = .{ .gt = 0 }, ._unknown = .{ .bytes = &even_record } };
    var count = field("count", 1, .int32, .optional);
    count.options = .{ .rules = .{ .type = .{ .int32 = int32_rules } } };
    const item_rules: validate.FieldRules = .{ .type = .{ .int32 = .{ ._unknown = .{ .bytes = &even_record } } } };
    const list_rules: validate.RepeatedRules = .{ .items = .of(&item_rules) };
    var parts = field("parts", 2, .int32, .repeated);
    parts.options = .{ .rules = .{ .type = .{ .repeated = .of(&list_rules) } } };
    var plain = field("plain", 3, .int32, .optional);
    plain.options = .{ .rules = .{ .type = .{ .int32 = .{ .@"const" = 1 } } } };
    const counted: pb.DescriptorProto = .{ .name = "Counted", .field = .of(&.{ count, parts, plain }) };

    const response = try respond_extended(arena, &.{counted}, &.{even});
    try testing.expect(response.@"error" == null);
    var files = response.file.iterator();
    const code = (try files.next()).?.content.?;
    const cel = ".cel = &.{.{ .id = \"int32.even\", .message = \"must be even\", .expression = \"!rule || this % 2 == 0\" }}";
    try expect_contains(code, "            .{ .number = @intFromEnum(@This().FieldNumber.count), .rules = .{ .type = .{ .int32 = .{ .greater_than = .{ .gt = 0 } } } }, " ++
        ".predefined = &.{.{ .number = @This().RuleNumber.@\"count.int32.(demo.v1.even).number\", .name = \"demo.v1.even\", .type = .type_bool, .value = .{ .boolean = true }, " ++ cel ++ " }} },\n");
    try expect_contains(code, "            .{ .number = @intFromEnum(@This().FieldNumber.parts), .rules = .{ .type = .{ .repeated = .of(&.{ .items = .of(&.{ .type = .{ .int32 = .{} } }) }) } }, " ++
        ".predefined = &.{.{ .site = .items, .number = @This().RuleNumber.@\"parts.repeated.items.int32.(demo.v1.even).number\", .name = \"demo.v1.even\", .type = .type_bool, .value = .{ .boolean = true }, " ++ cel ++ " }} },\n");
    // A field with no extension keeps the line it had.
    try expect_contains(code, "            .{ .number = @intFromEnum(@This().FieldNumber.plain), .rules = .{ .type = .{ .int32 = .{ .@\"const\" = 1 } } } },\n");
    try expect_contains(code, "        pub const @\"count.int32.(demo.v1.even).number\" = 1161;\n        pub const @\"parts.repeated.items.int32.(demo.v1.even).number\" = 1161;\n");
    try expect_absent(code, ".unsupported");

    // The same rules with no file that declares the extension: the table is unsupported.
    const undeclared = try generated(arena, &.{counted});
    try expect_contains(undeclared, "        .unsupported = \"buf.validate.Int32Rules holds field 1161, which neither the plugin's validate.proto nor an extension of the request states\",\n");
    try expect_absent(undeclared, ".predefined");
}

test "a field or a nested type named as a declaration of the table is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var value = field("value", 1, .string, .optional);
    value.options = .{ .rules = .{ .required = true } };
    const field_named: pb.DescriptorProto = .{ .name = "A", .field = .of(&.{ value, field("protovalidate", 2, .bool, .optional) }) };
    try testing.expectEqualStrings("protoc-gen-connect-zig: NameCollision", (try respond(arena, &.{field_named})).@"error".?);
    const nested_named: pb.DescriptorProto = .{ .name = "B", .field = .of(&.{value}), .nested_type = .of(&.{.{ .name = "RuleNumber" }}) };
    try testing.expectEqualStrings("protoc-gen-connect-zig: NameCollision", (try respond(arena, &.{nested_named})).@"error".?);
    const enum_named: pb.DescriptorProto = .{ .name = "D", .field = .of(&.{value}), .enum_type = .of(&.{.{ .name = "protovalidate" }}) };
    try testing.expectEqualStrings("protoc-gen-connect-zig: NameCollision", (try respond(arena, &.{enum_named})).@"error".?);
    var member = field("member", 2, .bool, .optional);
    member.oneof_index = 0;
    const oneof_named: pb.DescriptorProto = .{ .name = "E", .field = .of(&.{ value, member }), .oneof_decl = .of(&.{.{ .name = "RuleNumber" }}) };
    try testing.expectEqualStrings("protoc-gen-connect-zig: NameCollision", (try respond(arena, &.{oneof_named})).@"error".?);
    // The same names in a message with no table collide with nothing.
    const free: pb.DescriptorProto = .{ .name = "C", .field = .of(&.{field("protovalidate", 1, .bool, .optional)}), .nested_type = .of(&.{.{ .name = "RuleNumber" }}) };
    try testing.expect((try respond(arena, &.{free})).@"error" == null);
}
