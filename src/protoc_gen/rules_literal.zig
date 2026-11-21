//! Writes a rule message of validate.proto as the Zig literal of its generated type, which a
//! message's table holds (decision 47). The writer reads the generated type's own descriptor, so
//! it names no rule: a rule that validate.proto gains is written once its code is generated.
//!
//! Each number above 1 becomes a constant of the message's `RuleNumber`, named for the rule that
//! holds it, as the magic-numbers rule asks of generated code (decision 17).
const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("protobuf");
const names = @import("names.zig");
const index_file = @import("index.zig");
const rules_predefined = @import("rules_predefined.zig");
const constants = @import("constants.zig");

pub const Error = Allocator.Error || proto.Error;

/// One constant of `RuleNumber`: its name, and the number as Zig reads it.
pub const Number = struct { name: []const u8, text: []const u8 };

pub const Writer = struct {
    arena: Allocator,
    text: std.ArrayList(u8) = .empty,
    numbers: std.ArrayList(Number) = .empty,
    /// The names from the field to the value being written: "name", "string", "max_len".
    path: std.ArrayList([]const u8) = .empty,
    /// The request's messages and extensions, or none where a test reads no extension.
    index: ?*const index_file.Index = null,
    /// Whether the rules being written are a field's, where a predefined rule applies.
    in_field: bool = false,
    /// The predefined rules that the field's rule messages hold, in the order read.
    predefined: std.ArrayList(rules_predefined.Entry) = .empty,
    /// Why the table cannot state one of the message's rules: the first reason found.
    unsupported: ?[]const u8 = null,

    /// Marks the table unsupported, with the first reason alone.
    pub fn refuse(writer: *Writer, comptime format: []const u8, args: anytype) Allocator.Error!void {
        if (writer.unsupported == null) writer.unsupported = try std.fmt.allocPrint(writer.arena, format, args);
    }

    pub fn print(writer: *Writer, comptime format: []const u8, args: anytype) Allocator.Error!void {
        try writer.text.print(writer.arena, format, args);
    }

    /// Starts a literal's next member: ", " after another one, " " after the opening brace.
    fn separate(writer: *Writer, first: *bool) Allocator.Error!void {
        try writer.text.appendSlice(writer.arena, if (first.*) " " else ", ");
        first.* = false;
    }

    /// The name of the value being written: its path, joined with dots. No field's name holds
    /// a dot, so no two values of one message share a name.
    pub fn path_name(writer: *Writer) Allocator.Error![]const u8 {
        return std.mem.join(writer.arena, ".", writer.path.items);
    }

    /// Writes `number_text` in place, or names it in `RuleNumber` and writes the name.
    pub fn number(writer: *Writer, number_text: []const u8, magnitude: u64) Error!void {
        if (magnitude <= constants.unnamed_number_max) return writer.text.appendSlice(writer.arena, number_text);
        const name = try writer.path_name();
        try writer.numbers.append(writer.arena, .{ .name = name, .text = number_text });
        try writer.print("@This().{s}.{s}", .{ constants.rule_number_container, try names.identifier(writer.arena, name) });
    }
};

/// Writes `value` as a literal of `T`: `.{ .min_len = 1, .max_len = ... }`, or `.{}` for a
/// message with no field set.
pub fn message(writer: *Writer, comptime T: type, value: *const T) Error!void {
    if (comptime @hasField(T, "_unknown")) {
        if (value._unknown.bytes.len != 0) try rules_predefined.read(writer, T, value._unknown.bytes);
    }
    var first = true;
    try writer.text.appendSlice(writer.arena, ".{");
    inline for (T.protobuf.fields, 0..) |field, at| {
        if (field.oneof) |oneof| {
            // A oneof is one union field: its first member in the table writes the one set.
            if (comptime first_of_oneof(T, at)) try union_member(writer, T, oneof, value, &first);
        } else {
            try member(writer, field.name, @FieldType(T, field.name), &@field(value, field.name), &first);
        }
    }
    try writer.text.appendSlice(writer.arena, if (first) "}" else " }");
}

fn first_of_oneof(comptime T: type, comptime at: usize) bool {
    const fields = T.protobuf.fields;
    for (fields[0..at]) |earlier| {
        if (earlier.oneof != null and std.mem.eql(u8, earlier.oneof.?, fields[at].oneof.?)) return false;
    }
    return true;
}

/// Writes `.oneof = .{ .member = value }` for the member that is set.
fn union_member(writer: *Writer, comptime T: type, comptime oneof: []const u8, value: *const T, first: *bool) Error!void {
    const set = @field(value, oneof) orelse return;
    try writer.separate(first);
    switch (set) {
        inline else => |*payload, tag| {
            try writer.print(".{s} = .{{ .{s} = ", .{ try names.field_identifier(writer.arena, oneof), try names.field_identifier(writer.arena, @tagName(tag)) });
            try writer.path.append(writer.arena, @tagName(tag));
            try scalar_or_message(writer, @TypeOf(payload.*), payload);
            _ = writer.path.pop();
            try writer.text.appendSlice(writer.arena, " }");
        },
    }
}

/// Writes `.name = value` for a field that is set: an optional with a value, a repeated field
/// with an element, a lazy message that is present, or a plain value that is not its default.
fn member(writer: *Writer, comptime name: []const u8, comptime F: type, field: *const F, first: *bool) Error!void {
    if (comptime proto_is_repeated(F)) return repeated(writer, name, F, field, first);
    if (comptime @typeInfo(F) == .optional) {
        const payload = if (field.*) |*set| set else return;
        return named(writer, name, @TypeOf(payload.*), payload, first);
    }
    if (comptime is_lazy(F)) {
        if (!field.present()) return;
        return named(writer, name, F, field, first);
    }
    if (is_default(F, field)) return;
    return named(writer, name, F, field, first);
}

/// Writes a message that holds its own type, which its field keeps as a `proto.Lazy`:
/// `.of(&.{ ... })`.
fn lazy(writer: *Writer, comptime F: type, field: *const F) Error!void {
    const decoded = try field.get() orelse F.Message{};
    try writer.text.appendSlice(writer.arena, ".of(&");
    try message(writer, F.Message, &decoded);
    try writer.text.appendSlice(writer.arena, ")");
}

fn named(writer: *Writer, comptime name: []const u8, comptime V: type, value: *const V, first: *bool) Error!void {
    try writer.separate(first);
    try writer.print(".{s} = ", .{try names.field_identifier(writer.arena, name)});
    try writer.path.append(writer.arena, name);
    try scalar_or_message(writer, V, value);
    _ = writer.path.pop();
}

/// Writes `.name = .of(&.{ a, b })` for a repeated field with an element, and `.of(&.{a})` for
/// one element alone, as zig fmt writes a list of one.
fn repeated(writer: *Writer, comptime name: []const u8, comptime F: type, field: *const F, first: *bool) Error!void {
    if (field.is_empty()) return;
    const alone = try field.count() == 1;
    try writer.separate(first);
    try writer.print(".{s} = .of(&.{{", .{try names.field_identifier(writer.arena, name)});
    try writer.path.append(writer.arena, name);
    var elements = field.iterator();
    var index: usize = 0;
    while (try elements.next()) |element| : (index += 1) {
        if (!alone) try writer.text.appendSlice(writer.arena, if (index == 0) " " else ", ");
        try writer.path.append(writer.arena, try std.fmt.allocPrint(writer.arena, "{d}", .{index}));
        // A message's iterator gives a pointer, and any other element a value (decision 37).
        const pointer: *const F.Element = if (comptime @TypeOf(element) == *const F.Element) element else &element;
        try scalar_or_message(writer, F.Element, pointer);
        _ = writer.path.pop();
    }
    _ = writer.path.pop();
    try writer.text.appendSlice(writer.arena, if (alone) "})" else " })");
}

fn scalar_or_message(writer: *Writer, comptime V: type, value: *const V) Error!void {
    if (comptime is_lazy(V)) return lazy(writer, V, value);
    switch (@typeInfo(V)) {
        .bool => try writer.text.appendSlice(writer.arena, if (value.*) "true" else "false"),
        .int => try writer.number(try std.fmt.allocPrint(writer.arena, "{d}", .{value.*}), @abs(value.*)),
        .float => try float(writer, V, value.*),
        .@"enum" => try enumeration(writer, V, value.*),
        .pointer => try writer.text.appendSlice(writer.arena, try names.string_literal(writer.arena, value.*)),
        .@"struct" => try message(writer, V, value),
        else => @compileError("no literal for " ++ @typeName(V)),
    }
}

/// A float as a float literal: digits with a point, so the magic-numbers rule reads no integer.
/// A value with no decimal form, NaN or an infinity, is written from its bits, which are named.
pub fn float(writer: *Writer, comptime V: type, value: V) Error!void {
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(V));
    if (!std.math.isFinite(value)) {
        const bits: Bits = @bitCast(value);
        try writer.print("@bitCast(@as({s}, ", .{@typeName(Bits)});
        try writer.number(try std.fmt.allocPrint(writer.arena, "0x{x}", .{bits}), bits);
        return writer.text.appendSlice(writer.arena, "))");
    }
    const digits = try std.fmt.allocPrint(writer.arena, "{d}", .{value});
    const is_float_literal = std.mem.indexOfAny(u8, digits, ".e") != null;
    try writer.print("{s}{s}", .{ digits, if (is_float_literal) "" else ".0" });
}

/// An enum's value by its tag, or by its number when the generated enum names none.
fn enumeration(writer: *Writer, comptime V: type, value: V) Error!void {
    if (std.enums.tagName(V, value)) |tag| return writer.print(".{s}", .{try names.field_identifier(writer.arena, tag)});
    const raw = @intFromEnum(value);
    try writer.text.appendSlice(writer.arena, "@enumFromInt(");
    try writer.number(try std.fmt.allocPrint(writer.arena, "{d}", .{raw}), @abs(raw));
    try writer.text.appendSlice(writer.arena, ")");
}

/// Whether a field with no presence holds its type's default, which a literal leaves out.
fn is_default(comptime F: type, field: *const F) bool {
    return switch (@typeInfo(F)) {
        .bool => !field.*,
        .int, .float => field.* == 0,
        .@"enum" => @intFromEnum(field.*) == 0,
        .pointer => field.len == 0,
        else => false,
    };
}

fn proto_is_repeated(comptime F: type) bool {
    return @typeInfo(F) == .@"struct" and @hasDecl(F, "Iterator") and @hasDecl(F, "Element") and @hasField(F, "view");
}

fn is_lazy(comptime F: type) bool {
    return @typeInfo(F) == .@"struct" and @hasDecl(F, "Message") and @hasField(F, "bytes") and @hasField(F, "value");
}

const testing = std.testing;
const validate = @import("buf_validate_validate");

fn written(arena: Allocator, writer: *Writer, rules: *const validate.FieldRules) ![]const u8 {
    // The plugin reads rules that `decode` gave it, so the test writes what a decode gives.
    const bytes = try proto.encode(validate.FieldRules, rules, try arena.alloc(u8, try proto.encoded_len(validate.FieldRules, rules)));
    const decoded = try proto.decode(validate.FieldRules, bytes);
    try writer.path.append(arena, "val");
    try message(writer, validate.FieldRules, &decoded);
    return writer.text.items;
}

test "a rule message is written as the literal of its type, with each number above 1 named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var writer: Writer = .{ .arena = arena };
    const rules: validate.FieldRules = .{ .required = true, .ignore = .ignore_if_zero_value, .type = .{ .string = .{
        .min_len = 1,
        .max_len = 64,
        .prefix = "a\"b",
        .in = .of(&.{ "x", "y" }),
        .well_known = .{ .email = true },
    } } };
    try testing.expectEqualStrings(
        ".{ .type = .{ .string = .{ .min_len = 1, .max_len = @This().RuleNumber.@\"val.string.max_len\", .prefix = \"a\\\"b\", .in = .of(&.{ \"x\", \"y\" }), .well_known = .{ .email = true } } }, .required = true, .ignore = .ignore_if_zero_value }",
        try written(arena, &writer, &rules),
    );
    try testing.expectEqual(@as(usize, 1), writer.numbers.items.len);
    try testing.expectEqualStrings("val.string.max_len", writer.numbers.items[0].name);
    try testing.expectEqualStrings("64", writer.numbers.items[0].text);
    try testing.expect(writer.unsupported == null);
}

test "numbers, floats, lists and nested rules keep their values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signed: Writer = .{ .arena = arena };
    const int_rules: validate.FieldRules = .{ .type = .{ .sint32 = .{ .@"const" = -1, .less_than = .{ .lte = -5 }, .in = .of(&.{ 0, 7, -7 }) } } };
    try testing.expectEqualStrings(
        ".{ .type = .{ .sint32 = .{ .@\"const\" = -1, .less_than = .{ .lte = @This().RuleNumber.@\"val.sint32.lte\" }, .in = .of(&.{ 0, @This().RuleNumber.@\"val.sint32.in.1\", @This().RuleNumber.@\"val.sint32.in.2\" }) } } }",
        try written(arena, &signed, &int_rules),
    );
    try testing.expectEqualStrings("-5", signed.numbers.items[0].text);
    try testing.expectEqualStrings("7", signed.numbers.items[1].text);
    try testing.expectEqualStrings("-7", signed.numbers.items[2].text);

    var floats: Writer = .{ .arena = arena };
    const float_rules: validate.FieldRules = .{ .type = .{ .float = .{ .@"const" = 100000, .greater_than = .{ .gt = 0.5 }, .in = .of(&.{std.math.inf(f32)}) } } };
    try testing.expectEqualStrings(
        ".{ .type = .{ .float = .{ .@\"const\" = 100000.0, .greater_than = .{ .gt = 0.5 }, .in = .of(&.{@bitCast(@as(u32, @This().RuleNumber.@\"val.float.in.0\"))}) } } }",
        try written(arena, &floats, &float_rules),
    );
    try testing.expectEqualStrings("0x7f800000", floats.numbers.items[0].text);

    var nested: Writer = .{ .arena = arena };
    const item_rules: validate.FieldRules = .{ .type = .{ .timestamp = .{ .less_than = .{ .lt = .{ .seconds = 3600 } }, .within = .{ .nanos = 1 } } } };
    const list: validate.RepeatedRules = .{ .min_items = 2, .items = .of(&item_rules) };
    const list_rules: validate.FieldRules = .{ .type = .{ .repeated = .of(&list) } };
    try testing.expectEqualStrings(
        ".{ .type = .{ .repeated = .of(&.{ .min_items = @This().RuleNumber.@\"val.repeated.min_items\", .items = .of(&.{ .type = .{ .timestamp = .{ .less_than = .{ .lt = .{ .seconds = @This().RuleNumber.@\"val.repeated.items.timestamp.lt.seconds\" } }, .within = .{ .nanos = 1 } } } }) }) } }",
        try written(arena, &nested, &list_rules),
    );
    try testing.expectEqual(@as(usize, 2), nested.numbers.items.len);

    // A lazy message that is absent is left out, as any field that is not set.
    var absent: Writer = .{ .arena = arena };
    const pairs: validate.MapRules = .{ .min_pairs = 1 };
    const map_rules: validate.FieldRules = .{ .type = .{ .map = .of(&pairs) } };
    try testing.expectEqualStrings(".{ .type = .{ .map = .of(&.{ .min_pairs = 1 }) } }", try written(arena, &absent, &map_rules));
}

test "an enum's unnamed number and a rule the types do not know are both kept in sight" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var writer: Writer = .{ .arena = arena };
    try enumeration(&writer, validate.Ignore, @enumFromInt(1));
    try testing.expectEqualStrings(".ignore_if_zero_value", writer.text.items);
    // Field 1161 of StringRules is an extension's predefined rule, which the types do not hold.
    const extension_record = [_]u8{ 0xc8, 0x48, 0x01 };
    const string_rules = [_]u8{ 0x72, extension_record.len } ++ extension_record;
    const decoded = try proto.decode(validate.FieldRules, &string_rules);
    var unknown: Writer = .{ .arena = arena };
    try message(&unknown, validate.FieldRules, &decoded);
    try testing.expectEqualStrings("buf.validate.StringRules holds field 1161, which neither the plugin's validate.proto nor an extension of the request states", unknown.unsupported.?);
    try testing.expectEqualStrings(".{ .type = .{ .string = .{} } }", unknown.text.items);
}
