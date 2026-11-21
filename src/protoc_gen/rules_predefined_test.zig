//! Tests of `rules_predefined.zig`: extensions of validate.proto's rule messages that a
//! request's files declare, the records that hold their values, and the entries the plugin
//! writes for them (design §8 step 34). A record is the encoding of a message with one field of
//! the extension's number, so the protobuf module writes each one.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const proto = @import("protobuf");
const validate = @import("buf_validate_validate");
const pb = @import("descriptor_pb.zig");
const index_file = @import("index.zig");
const rules_literal = @import("rules_literal.zig");
const rules_predefined = @import("rules_predefined.zig");
const Writer = rules_literal.Writer;
const Value = rules_predefined.Value;

/// The numbers of the tests' extensions, in the range validate.proto leaves to extensions, and
/// the number of Int32Rules.lt, a field the rule message knows.
const first_number = 1161;
const second_number = 1162;
const undeclared_number = 1999;
const lt_number = 2;
/// The values the tests' records hold.
const two = 2;
const three = 3;
const seven = 7;
const large = 0xffff_ffff_ffff_fff0;
const half = 0.5;

const int32_rules = ".buf.validate.Int32Rules";
const rule: validate.Rule = .{ .id = "t.rule", .message = "must hold", .expression = "this == rule" };

/// An extension of the rule message `extendee` with one CEL rule.
fn extension(name: []const u8, extendee: []const u8, number: i32, kind: pb.Type, label: pb.Label) pb.FieldDescriptorProto {
    return .{ .name = name, .extendee = extendee, .number = number, .type = kind, .label = label, .options = .{ .predefined = .{ .cel = .of(&.{rule}) } } };
}

/// A message whose one field has an extension's number, kind and type.
fn Holder(comptime F: type, comptime kind: proto.Kind, comptime number: u32, comptime is_packed: bool) type {
    return struct {
        value: F,
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.Holder", .fields = &.{
            .{ .name = "value", .number = number, .kind = kind, .json_name = "value", .proto_name = "value", .@"packed" = is_packed },
        } };
    };
}

/// A wrapper as wrappers.proto declares it: a value with no presence, so a zero is not written.
fn Wrapped(comptime T: type, comptime kind: proto.Kind) type {
    return struct {
        value: T,
        pub const FieldNumber = enum(u29) { value = 1 };
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.Wrapped", .fields = &.{proto.field_of(FieldNumber.value, kind, .{})} };
    };
}

/// The record of field `number` that holds `value`.
fn record(arena: Allocator, comptime F: type, comptime kind: proto.Kind, comptime number: u32, comptime is_packed: bool, value: F) ![]const u8 {
    const H = Holder(F, kind, number, is_packed);
    const holder: H = .{ .value = value };
    return proto.encode(H, &holder, try arena.alloc(u8, try proto.encoded_len(H, &holder)));
}

/// A writer inside the rules of a field named "val", at the rule message that `between` and
/// "int32" lead to, with the extensions that the file demo/v1/rules.proto declares.
fn writer_at(arena: Allocator, declared: []const pb.FieldDescriptorProto, between: []const []const u8) !Writer {
    const file: pb.FileDescriptorProto = .{ .name = "demo/v1/rules.proto", .package = "demo.v1", .extension = .of(declared) };
    const index = try arena.create(index_file.Index);
    index.* = try index_file.Index.build(arena, &.{file});
    var writer: Writer = .{ .arena = arena, .index = index, .in_field = true };
    try writer.path.append(arena, "val");
    try writer.path.appendSlice(arena, between);
    try writer.path.append(arena, "int32");
    return writer;
}

/// Reads `bytes` as the unknown span of an Int32Rules and gives the values of its one entry.
fn values_of(arena: Allocator, declared: pb.FieldDescriptorProto, bytes: []const u8) ![]const Value {
    var writer = try writer_at(arena, &.{declared}, &.{});
    try rules_predefined.read(&writer, validate.Int32Rules, bytes);
    try testing.expect(writer.unsupported == null);
    try testing.expectEqual(@as(usize, 1), writer.predefined.items.len);
    return writer.predefined.items[0].values.items;
}

test "each scalar type is read as the value its record holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = .{
        .{ pb.Type.double, ?f64, proto.Kind.double, @as(f64, -half), Value{ .double = -half } },
        .{ pb.Type.float, ?f32, proto.Kind.float, @as(f32, half), Value{ .double = half } },
        .{ pb.Type.int64, ?i64, proto.Kind.int64, @as(i64, -two), Value{ .int = -two } },
        .{ pb.Type.uint64, ?u64, proto.Kind.uint64, @as(u64, large), Value{ .uint = large } },
        .{ pb.Type.int32, ?i32, proto.Kind.int32, @as(i32, -two), Value{ .int = -two } },
        .{ pb.Type.fixed64, ?u64, proto.Kind.fixed64, @as(u64, large), Value{ .uint = large } },
        .{ pb.Type.fixed32, ?u32, proto.Kind.fixed32, @as(u32, seven), Value{ .uint = seven } },
        .{ pb.Type.bool, ?bool, proto.Kind.bool, true, Value{ .boolean = true } },
        .{ pb.Type.string, ?[]const u8, proto.Kind.string, @as([]const u8, "a/b"), Value{ .string = "a/b" } },
        .{ pb.Type.bytes, ?[]const u8, proto.Kind.bytes, @as([]const u8, "\xff\x00"), Value{ .bytes = "\xff\x00" } },
        .{ pb.Type.uint32, ?u32, proto.Kind.uint32, @as(u32, seven), Value{ .uint = seven } },
        // An enum's number is an int32 on the wire, and an int in CEL.
        .{ pb.Type.@"enum", ?i32, proto.Kind.int32, @as(i32, -three), Value{ .int = -three } },
        .{ pb.Type.sfixed32, ?i32, proto.Kind.sfixed32, @as(i32, -three), Value{ .int = -three } },
        .{ pb.Type.sfixed64, ?i64, proto.Kind.sfixed64, @as(i64, -three), Value{ .int = -three } },
        .{ pb.Type.sint32, ?i32, proto.Kind.sint32, @as(i32, -three), Value{ .int = -three } },
        .{ pb.Type.sint64, ?i64, proto.Kind.sint64, @as(i64, -three), Value{ .int = -three } },
    };
    inline for (cases) |case| {
        const bytes = try record(arena, case[1], case[2], first_number, true, case[3]);
        const values = try values_of(arena, extension("limit", int32_rules, first_number, case[0], .optional), bytes);
        try testing.expectEqualDeep(@as([]const Value, &.{case[4]}), values);
    }
}

test "a list holds each value of its records, packed or not, and any other field its last one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const List = proto.Repeated(i32, .sint32);
    const apart = try record(arena, List, .sint32, first_number, false, .of(&.{ -two, seven }));
    const together = try record(arena, List, .sint32, first_number, true, .of(&.{ three, -three }));
    const bytes = try std.mem.concat(arena, u8, &.{ apart, together });
    try testing.expectEqualDeep(
        @as([]const Value, &.{ .{ .int = -two }, .{ .int = seven }, .{ .int = three }, .{ .int = -three } }),
        try values_of(arena, extension("allowed", int32_rules, first_number, .sint32, .repeated), bytes),
    );
    // "Last One Wins" (encoding guide): a field that is no list keeps its last record's value.
    const first = try record(arena, ?i32, .sint32, first_number, true, -two);
    const last = try record(arena, ?i32, .sint32, first_number, true, seven);
    try testing.expectEqualDeep(
        @as([]const Value, &.{.{ .int = seven }}),
        try values_of(arena, extension("limit", int32_rules, first_number, .sint32, .optional), try std.mem.concat(arena, u8, &.{ first, last })),
    );
}

test "a wrapper is read as the scalar it holds, and merges its records where it is no list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Int64Value = Wrapped(i64, .int64);
    var limit = extension("limit", int32_rules, first_number, .message, .optional);
    limit.type_name = ".google.protobuf.Int64Value";
    const stated = try record(arena, ?Int64Value, .message, first_number, true, .{ .value = -two });
    // A wrapper of 0 writes no value.
    const empty = try record(arena, ?Int64Value, .message, first_number, true, .{ .value = 0 });
    try testing.expectEqualDeep(@as([]const Value, &.{.{ .int = -two }}), try values_of(arena, limit, stated));
    try testing.expectEqualDeep(@as([]const Value, &.{.{ .int = 0 }}), try values_of(arena, limit, empty));
    // The second record states no value, so the first one's stays.
    try testing.expectEqualDeep(@as([]const Value, &.{.{ .int = -two }}), try values_of(arena, limit, try std.mem.concat(arena, u8, &.{ stated, empty })));

    // A list keeps each wrapper apart, so one that states no value holds 0.
    var allowed = limit;
    allowed.label = .repeated;
    try testing.expectEqualDeep(
        @as([]const Value, &.{ .{ .int = -two }, .{ .int = 0 }, .{ .int = -two } }),
        try values_of(arena, allowed, try std.mem.concat(arena, u8, &.{ stated, empty, stated })),
    );
    // Each wrapper of wrappers.proto names the scalar it holds.
    var text = limit;
    text.type_name = ".google.protobuf.StringValue";
    const path = try record(arena, ?Wrapped([]const u8, .string), .message, first_number, true, .{ .value = "a/b" });
    try testing.expectEqualDeep(@as([]const Value, &.{.{ .string = "a/b" }}), try values_of(arena, text, path));
    // A wrapper that states no value holds its type's default.
    const defaults = [_]struct { type_name: []const u8, value: Value }{
        .{ .type_name = ".google.protobuf.BoolValue", .value = .{ .boolean = false } },
        .{ .type_name = ".google.protobuf.StringValue", .value = .{ .string = "" } },
        .{ .type_name = ".google.protobuf.BytesValue", .value = .{ .bytes = "" } },
        .{ .type_name = ".google.protobuf.DoubleValue", .value = .{ .double = 0 } },
        .{ .type_name = ".google.protobuf.UInt32Value", .value = .{ .uint = 0 } },
    };
    for (defaults) |case| {
        var wrapper = limit;
        wrapper.type_name = case.type_name;
        try testing.expectEqualDeep(@as([]const Value, &.{case.value}), try values_of(arena, wrapper, empty));
    }
}

/// What the plugin writes of an entry between its name and its CEL rules: its type and value.
fn written_of(arena: Allocator, declared: pb.FieldDescriptorProto, bytes: []const u8) ![]const u8 {
    var writer = try writer_at(arena, &.{declared}, &.{});
    try rules_predefined.read(&writer, validate.Int32Rules, bytes);
    try rules_predefined.write(&writer);
    const text = writer.text.items;
    return text[std.mem.indexOf(u8, text, ".type = ").?..std.mem.indexOf(u8, text, ", .cel = ").?];
}

test "a value is written under the member of its type, alone or as a list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const limit = "@This().RuleNumber.@\"val.int32.(demo.v1.limit).value\"";
    try testing.expectEqualStrings(
        ".type = .type_bool, .value = .{ .booleans = &.{ true, false } }",
        try written_of(arena, extension("limit", int32_rules, first_number, .bool, .repeated), try record(arena, proto.Repeated(bool, .bool), .bool, first_number, true, .of(&.{ true, false }))),
    );
    try testing.expectEqualStrings(
        ".type = .type_uint64, .value = .{ .uint = " ++ limit ++ " }",
        try written_of(arena, extension("limit", int32_rules, first_number, .uint64, .optional), try record(arena, ?u64, .uint64, first_number, true, seven)),
    );
    try testing.expectEqualStrings(
        ".type = .type_sint32, .value = .{ .int = -1 }",
        try written_of(arena, extension("limit", int32_rules, first_number, .sint32, .optional), try record(arena, ?i32, .sint32, first_number, true, -1)),
    );
    try testing.expectEqualStrings(
        ".type = .type_double, .value = .{ .double = 0.5 }",
        try written_of(arena, extension("limit", int32_rules, first_number, .double, .optional), try record(arena, ?f64, .double, first_number, true, half)),
    );
    try testing.expectEqualStrings(
        ".type = .type_float, .value = .{ .doubles = &.{ 0.5, 2.0 } }",
        try written_of(arena, extension("limit", int32_rules, first_number, .float, .repeated), try record(arena, proto.Repeated(f32, .float), .float, first_number, true, .of(&.{ half, two }))),
    );
    try testing.expectEqualStrings(
        ".type = .type_string, .value = .{ .string = \"a\\\"b\" }",
        try written_of(arena, extension("limit", int32_rules, first_number, .string, .optional), try record(arena, ?[]const u8, .string, first_number, true, "a\"b")),
    );
    try testing.expectEqualStrings(
        ".type = .type_string, .value = .{ .strings = &.{ \"a\", \"b\" } }",
        try written_of(arena, extension("limit", int32_rules, first_number, .string, .repeated), try record(arena, proto.Repeated([]const u8, .string), .string, first_number, true, .of(&.{ "a", "b" }))),
    );
    try testing.expectEqualStrings(
        ".type = .type_bytes, .value = .{ .bytes = \"\\xff\" }",
        try written_of(arena, extension("limit", int32_rules, first_number, .bytes, .optional), try record(arena, ?[]const u8, .bytes, first_number, true, "\xff")),
    );
    // A packed record of no value: field 1161, length-delimited, of length 0.
    const no_value = [_]u8{ 0xca, 0x48, 0x00 };
    try testing.expectEqualStrings(
        ".type = .type_int32, .value = .{ .ints = &.{} }",
        try written_of(arena, extension("limit", int32_rules, first_number, .int32, .repeated), &no_value),
    );
    // A wrapper's type is the message's, and its value the scalar's.
    var wrapper = extension("limit", int32_rules, first_number, .message, .optional);
    wrapper.type_name = ".google.protobuf.Int64Value";
    try testing.expectEqualStrings(
        ".type = .type_message, .value = .{ .int = 1 }",
        try written_of(arena, wrapper, try record(arena, ?Wrapped(i64, .int64), .message, first_number, true, .{ .value = 1 })),
    );

    // Two CEL rules of one extension are a list of two.
    var twice = extension("limit", int32_rules, first_number, .bool, .optional);
    twice.options = .{ .predefined = .{ .cel = .of(&.{ rule, rule }) } };
    var writer = try writer_at(arena, &.{twice}, &.{});
    try rules_predefined.read(&writer, validate.Int32Rules, try record(arena, ?bool, .bool, first_number, true, true));
    try rules_predefined.write(&writer);
    const one = ".{ .id = \"t.rule\", .message = \"must hold\", .expression = \"this == rule\" }";
    try testing.expect(std.mem.endsWith(u8, writer.text.items, ".value = .{ .boolean = true }, .cel = &.{ " ++ one ++ ", " ++ one ++ " } }}"));
}

test "the span's known records are passed over, and each extension gets one entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const declared = [_]pb.FieldDescriptorProto{
        extension("allowed", int32_rules, first_number, .int32, .repeated),
        extension("even", int32_rules, second_number, .bool, .optional),
    };
    // Int32Rules.lt lies between two records of one extension, as a span from the first
    // unknown record to the last holds it (decision 24).
    const bytes = try std.mem.concat(arena, u8, &.{
        try record(arena, ?i32, .int32, first_number, true, two),
        try record(arena, ?i32, .int32, lt_number, true, seven),
        try record(arena, ?bool, .bool, second_number, true, true),
        try record(arena, ?i32, .int32, first_number, true, three),
    });
    var writer = try writer_at(arena, &declared, &.{});
    try rules_predefined.read(&writer, validate.Int32Rules, bytes);
    try testing.expect(writer.unsupported == null);
    const entries = writer.predefined.items;
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("val.int32.(demo.v1.allowed)", entries[0].name);
    try testing.expectEqual(@as(u32, first_number), entries[0].number);
    try testing.expectEqualDeep(@as([]const Value, &.{ .{ .int = two }, .{ .int = three } }), entries[0].values.items);
    try testing.expectEqualStrings("val.int32.(demo.v1.even)", entries[1].name);
    try testing.expectEqualDeep(@as([]const Value, &.{.{ .boolean = true }}), entries[1].values.items);

    try rules_predefined.write(&writer);
    try testing.expectEqualStrings(
        ", .predefined = &.{ .{ .number = @This().RuleNumber.@\"val.int32.(demo.v1.allowed).number\", .name = \"demo.v1.allowed\", .type = .type_int32, " ++
            ".value = .{ .ints = &.{ @This().RuleNumber.@\"val.int32.(demo.v1.allowed).value.0\", @This().RuleNumber.@\"val.int32.(demo.v1.allowed).value.1\" } }, " ++
            ".cel = &.{.{ .id = \"t.rule\", .message = \"must hold\", .expression = \"this == rule\" }} }, " ++
            ".{ .number = @This().RuleNumber.@\"val.int32.(demo.v1.even).number\", .name = \"demo.v1.even\", .type = .type_bool, .value = .{ .boolean = true }, " ++
            ".cel = &.{.{ .id = \"t.rule\", .message = \"must hold\", .expression = \"this == rule\" }} } }",
        writer.text.items,
    );
    // The entries are a field's own, so the next field starts with none.
    try testing.expectEqual(@as(usize, 0), writer.predefined.items.len);
    try testing.expectEqual(@as(usize, 0), writer.path.items.len - two);
    const numbers = writer.numbers.items;
    try testing.expectEqualStrings("val.int32.(demo.v1.allowed).value.1", numbers[two].name);
    try testing.expectEqualStrings("3", numbers[two].text);
    try testing.expectEqualStrings("1162", numbers[three].text);
}

test "an entry states where its rule message lies in the field's rules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const even = extension("even", int32_rules, first_number, .bool, .optional);
    const bytes = try record(arena, ?bool, .bool, first_number, true, true);
    const Site = rules_predefined.Site;
    const sites = [_]struct { between: []const []const u8, site: ?Site }{
        .{ .between = &.{}, .site = .field },
        .{ .between = &.{ "repeated", "items" }, .site = .items },
        .{ .between = &.{ "map", "keys" }, .site = .keys },
        .{ .between = &.{ "map", "values" }, .site = .values },
        .{ .between = &.{ "map", "items" }, .site = null },
        .{ .between = &.{"repeated"}, .site = null },
    };
    for (sites) |case| {
        var writer = try writer_at(arena, &.{even}, case.between);
        try rules_predefined.read(&writer, validate.Int32Rules, bytes);
        const site = case.site orelse {
            try testing.expectEqualStrings("(demo.v1.even) lies outside a field's rules, where the plugin reads no predefined rule", writer.unsupported.?);
            try testing.expectEqual(@as(usize, 0), writer.predefined.items.len);
            continue;
        };
        try testing.expect(writer.unsupported == null);
        try testing.expectEqual(site, writer.predefined.items[0].site);
    }
    // The rules of a message or of a oneof hold no predefined rule.
    var outside = try writer_at(arena, &.{even}, &.{});
    outside.in_field = false;
    try rules_predefined.read(&outside, validate.Int32Rules, bytes);
    try testing.expectEqualStrings("(demo.v1.even) lies outside a field's rules, where the plugin reads no predefined rule", outside.unsupported.?);
    // Nor does FieldRules itself, which the field's name alone leads to.
    var own = try writer_at(arena, &.{extension("even", ".buf.validate.FieldRules", first_number, .bool, .optional)}, &.{});
    own.path.items.len = 1;
    try rules_predefined.read(&own, validate.FieldRules, bytes);
    try testing.expectEqualStrings("(demo.v1.even) lies outside a field's rules, where the plugin reads no predefined rule", own.unsupported.?);

    // An entry outside the field's own rules names its site, and a list of one value is
    // written as zig fmt writes it.
    var items = try writer_at(arena, &.{extension("allowed", int32_rules, first_number, .uint32, .repeated)}, &.{ "repeated", "items" });
    try rules_predefined.read(&items, validate.Int32Rules, try record(arena, ?u32, .uint32, first_number, true, 1));
    try rules_predefined.write(&items);
    try testing.expectEqualStrings(
        ", .predefined = &.{.{ .site = .items, .number = @This().RuleNumber.@\"val.repeated.items.int32.(demo.v1.allowed).number\", .name = \"demo.v1.allowed\", " ++
            ".type = .type_uint32, .value = .{ .uints = &.{1} }, .cel = &.{.{ .id = \"t.rule\", .message = \"must hold\", .expression = \"this == rule\" }} }}",
        items.text.items,
    );
}

test "a record the plugin cannot write as a rule marks the table unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const flag = try record(arena, ?bool, .bool, first_number, true, true);
    const even = extension("even", int32_rules, first_number, .bool, .optional);

    // No extension of the request has the number, or the one that has it extends another message.
    var undeclared = try writer_at(arena, &.{even}, &.{});
    try rules_predefined.read(&undeclared, validate.Int32Rules, try record(arena, ?bool, .bool, undeclared_number, true, true));
    try testing.expectEqualStrings("buf.validate.Int32Rules holds field 1999, which neither the plugin's validate.proto nor an extension of the request states", undeclared.unsupported.?);
    var other = try writer_at(arena, &.{extension("even", ".buf.validate.Int64Rules", first_number, .bool, .optional)}, &.{});
    try rules_predefined.read(&other, validate.Int32Rules, flag);
    try testing.expect(other.unsupported != null);
    // A writer with no index reads no extension.
    var bare: Writer = .{ .arena = arena, .in_field = true };
    try rules_predefined.read(&bare, validate.Int32Rules, flag);
    try testing.expect(bare.unsupported != null);

    // A value that the table's `Predefined.Value` cannot hold.
    var message = extension("window", int32_rules, first_number, .message, .optional);
    message.type_name = ".google.protobuf.Duration";
    const refused = [_]pb.FieldDescriptorProto{
        message,
        extension("part", int32_rules, first_number, .group, .optional),
        extension("prefixes", int32_rules, first_number, .bytes, .repeated),
    };
    for (refused) |declared| {
        var writer = try writer_at(arena, &.{declared}, &.{});
        try rules_predefined.read(&writer, validate.Int32Rules, try record(arena, ?[]const u8, .bytes, first_number, true, "a"));
        try testing.expect(std.mem.endsWith(u8, writer.unsupported.?, "is no scalar, wrapper or list of them, so the plugin writes no value for its rule (docs/design.md §8 step 34)"));
        try testing.expectEqual(@as(usize, 0), writer.predefined.items.len);
    }

    // A group's record, which the walk does not pass over. The first reason stays.
    const Part = struct {
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.Part", .fields = &.{} };
    };
    var grouped = try writer_at(arena, &.{even}, &.{});
    try rules_predefined.read(&grouped, validate.Int32Rules, try record(arena, ?Part, .group, second_number, true, .{}));
    try testing.expectEqualStrings("buf.validate.Int32Rules holds a group in field 1162, which the plugin does not read", grouped.unsupported.?);
    try rules_predefined.read(&grouped, validate.Int32Rules, try record(arena, ?bool, .bool, undeclared_number, true, true));
    try testing.expect(std.mem.indexOf(u8, grouped.unsupported.?, "a group") != null);
}

test "an extension that states no rule is passed over, and a broken record is an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An extension of a rule message with no `(buf.validate.predefined).cel` is not a rule.
    var plain = extension("note", int32_rules, first_number, .string, .optional);
    plain.options = null;
    var empty = plain;
    empty.options = .{ .predefined = .{} };
    for ([_]pb.FieldDescriptorProto{ plain, empty }) |declared| {
        var writer = try writer_at(arena, &.{declared}, &.{});
        try rules_predefined.read(&writer, validate.Int32Rules, try record(arena, ?[]const u8, .string, first_number, true, "a"));
        try testing.expect(writer.unsupported == null);
        try testing.expectEqual(@as(usize, 0), writer.predefined.items.len);
        try rules_predefined.write(&writer);
        try testing.expectEqual(@as(usize, 0), writer.text.items.len);
    }

    const even = extension("even", int32_rules, first_number, .bool, .optional);
    const whole = try record(arena, ?[]const u8, .bytes, lt_number, true, "abc");
    const continued = [_]u8{0xff} ** (proto.constants.protocol.varint_len_max + 1);
    const broken = [_]struct { bytes: []const u8, failure: anyerror }{
        // A length that names more bytes than the span holds, and a tag that ends early.
        .{ .bytes = whole[0 .. whole.len - 1], .failure = error.Truncated },
        .{ .bytes = continued[0..1], .failure = error.Truncated },
        // "Base 128 Varints" (encoding guide): a varint holds at most 10 bytes.
        .{ .bytes = &continued, .failure = error.VarintTooLong },
    };
    for (broken) |case| {
        var writer = try writer_at(arena, &.{even}, &.{});
        try testing.expectError(case.failure, rules_predefined.read(&writer, validate.Int32Rules, case.bytes));
    }
    // "Message Structure" (encoding guide): a record of the extension's number and another
    // wire type is not the extension's.
    var mistyped = try writer_at(arena, &.{extension("note", int32_rules, first_number, .string, .optional)}, &.{});
    try testing.expectError(error.WireTypeMismatch, rules_predefined.read(&mistyped, validate.Int32Rules, try record(arena, ?bool, .bool, first_number, true, true)));
}

test "the index finds an extension by the message it extends and its number" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An extension that a message declares takes the message's name as its scope.
    const scope: pb.DescriptorProto = .{ .name = "Scope", .extension = .of(&.{extension("inner", int32_rules, second_number, .bool, .optional)}) };
    var nameless = extension("nameless", int32_rules, undeclared_number, .bool, .optional);
    nameless.extendee = null;
    const file: pb.FileDescriptorProto = .{
        .name = "demo/v1/rules.proto",
        .package = "demo.v1",
        .message_type = .of(&.{scope}),
        .extension = .of(&.{ extension("outer", int32_rules, first_number, .bool, .optional), nameless }),
    };
    const index = try index_file.Index.build(arena, &.{file});
    try testing.expectEqualStrings("demo.v1.outer", (try index.extension_of(arena, "buf.validate.Int32Rules", first_number)).?.full_name);
    try testing.expectEqualStrings("demo.v1.Scope.inner", (try index.extension_of(arena, "buf.validate.Int32Rules", second_number)).?.full_name);
    try testing.expect(try index.extension_of(arena, "buf.validate.Int64Rules", first_number) == null);
    try testing.expect(try index.extension_of(arena, "buf.validate.Int32Rules", undeclared_number) == null);
}

test "an extension's declaration is read at the numbers descriptor.proto and validate.proto state" {
    // descriptor.proto: FieldDescriptorProto.name = 1 and FieldDescriptorProto.extendee = 2.
    const declared = [_]u8{ 0x0a, 0x01, 'x', 0x12, 0x02, '.', 'm' };
    // descriptor.proto: DescriptorProto.extension = 6 and FileDescriptorProto.extension = 7.
    const in_message = [_]u8{ 0x32, declared.len } ++ declared;
    const in_file = [_]u8{ 0x3a, declared.len } ++ declared;
    const message = try proto.decode(pb.DescriptorProto, &in_message);
    var of_message = message.extension.iterator();
    try testing.expectEqualStrings(".m", (try of_message.next()).?.extendee.?);
    const file = try proto.decode(pb.FileDescriptorProto, &in_file);
    var of_file = file.extension.iterator();
    try testing.expectEqualStrings("x", (try of_file.next()).?.name.?);
    // validate.proto: `predefined` extends FieldOptions at 1160, PredefinedRules.cel = 1 and
    // Rule.id = 1.
    const rule_bytes = [_]u8{ 0x0a, 0x01, 'i' };
    const predefined = [_]u8{ 0x0a, rule_bytes.len } ++ rule_bytes;
    const options_bytes = [_]u8{ 0xc2, 0x48, predefined.len } ++ predefined;
    const options = try proto.decode(pb.FieldOptions, &options_bytes);
    var cel = options.predefined.?.cel.iterator();
    try testing.expectEqualStrings("i", (try cel.next()).?.id.?);
}
