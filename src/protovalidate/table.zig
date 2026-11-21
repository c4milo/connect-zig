//! `Rules`: the table a generated message declares as `pub const protovalidate`, which the
//! plugin writes from the message's `buf.validate` options (decision 47), and what `validate`
//! reads of a table and of a descriptor at comptime.
const std = @import("std");
const assert = std.debug.assert;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const descriptor_pb = @import("google_protobuf_descriptor");
const constants = @import("constants.zig");
const once = @import("table_once.zig");

/// A field's type as a path element states it: descriptor.proto's FieldDescriptorProto.Type.
pub const Type = descriptor_pb.FieldDescriptorProto.Type;
pub const Element = pb.FieldPathElement;

/// The name of the declaration that holds a message's table.
pub const declaration = "protovalidate";

pub const Rules = struct {
    /// `(buf.validate.message)`: the rules of the message itself.
    message: pb.MessageRules = .{},
    /// `(buf.validate.field)` of each field that has rules.
    fields: []const Field = &.{},
    /// `(buf.validate.oneof)` of each oneof that has rules.
    oneofs: []const Oneof = &.{},
    /// Why the plugin wrote no table for one of the message's rules: a rule it cannot write
    /// yet. `validate` fails the build with this text, so no such rule goes unchecked.
    unsupported: ?[]const u8 = null,

    pub const Field = struct {
        /// The field's number, which names it in the message's descriptor.
        number: u32,
        rules: pb.FieldRules,
        /// The predefined rules of the extensions that the field's rules hold, which the
        /// plugin reads from its request (design §8 step 34). An extension lies in a rule
        /// message, so `rules` state the type whose rule message holds it.
        predefined: []const Predefined = &.{},
    };

    /// One extension of a rule message, such as `(my.rules.even)` of `Int32Rules`, with the
    /// CEL rules its declaration states in `(buf.validate.predefined)` (validate.proto,
    /// PredefinedRules).
    pub const Predefined = struct {
        /// Which of the field's rules holds the extension: the field's own, or those of its
        /// elements, of its keys or of its values.
        site: Where = .field,
        /// The extension's number, its full name and its type, which a violation's rule path
        /// states.
        number: u32,
        name: []const u8,
        type: Type,
        /// The extension's value, which an expression reads as `rule`.
        value: Value,
        cel: []const pb.Rule,

        pub const Where = enum { field, items, keys, values };

        /// A scalar, or a list of scalars of one type. An enum's value is an int, and a
        /// wrapper's is the scalar it holds.
        pub const Value = union(enum) {
            boolean: bool,
            int: i64,
            uint: u64,
            double: f64,
            string: []const u8,
            bytes: []const u8,
            booleans: []const bool,
            ints: []const i64,
            uints: []const u64,
            doubles: []const f64,
            strings: []const []const u8,
        };
    };

    pub const Oneof = struct {
        /// The Zig name of the oneof's union field, as the descriptor's `Field.oneof` holds it.
        field: []const u8,
        /// The oneof's name in the .proto file, which a violation's path states.
        name: []const u8,
        rules: pb.OneofRules,
    };
};

/// Whether `T` declares a table: it has a rule, or holds a message that has one.
pub fn has_rules(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, declaration);
}

/// The table of `T`.
pub fn of(comptime T: type) Rules {
    comptime assert(has_rules(T));
    return @field(T, declaration);
}

/// The rules of the field of `T` numbered `number`, or none.
pub fn field_rules(comptime T: type, comptime number: u32) ?pb.FieldRules {
    comptime {
        const at = entry_of(T, number) orelse return null;
        return of(T).fields[at].rules;
    }
}

/// The predefined rules of the field of `T` numbered `number` that lie at `site`.
pub fn predefined_of(comptime T: type, comptime number: u32, comptime site: Rules.Predefined.Where) []const Rules.Predefined {
    comptime {
        var list: []const Rules.Predefined = &.{};
        const at = entry_of(T, number) orelse return list;
        for (of(T).fields[at].predefined) |predefined| {
            if (predefined.site == site) list = list ++ [_]Rules.Predefined{predefined};
        }
        return list;
    }
}

/// The place in the table of `T` of the entry of the field numbered `number`, or null for a
/// field with no entry and for a number the message lacks.
pub fn entry_of(comptime T: type, comptime number: u32) ?usize {
    comptime {
        if (!has_rules(T)) return null;
        const place = place_of(T, number) orelse return null;
        return Places(T).of_field[place];
    }
}

/// Where the table of `T` holds each field's entry: for each field, by its place in the
/// descriptor, the place of its entry, or none. The compiler computes it once for each type,
/// so a message of many fields takes no search of its table for each one.
fn Places(comptime T: type) type {
    return struct {
        const of_field: [T.protobuf.fields.len]?usize = once.places_of(T);
    };
}

/// The place in the descriptor of `T` of the field numbered `number`, or null. A generated
/// descriptor's numbers rise, so the search halves what is left at each step. A descriptor
/// written by hand whose numbers do not rise is read field by field.
pub fn place_of(comptime T: type, comptime number: u32) ?usize {
    comptime {
        const fields = T.protobuf.fields;
        if (!Order(T).rises) {
            for (fields, 0..) |field, place| {
                if (field.number == number) return place;
            }
            return null;
        }
        var low: usize = 0;
        var high: usize = fields.len;
        // Each step halves the fields left, so the bits of a count bound the steps.
        for (0..@bitSizeOf(usize)) |_| {
            if (low == high) return null;
            const middle = low + (high - low) / halves;
            if (fields[middle].number == number) return middle;
            if (fields[middle].number < number) low = middle + 1 else high = middle;
        }
        return null;
    }
}
const halves = 2;

/// Whether the numbers of the fields of `T` rise, which the compiler reads once for each type.
fn Order(comptime T: type) type {
    return struct {
        const rises: bool = once.numbers_rise(T);
    };
}

/// The type a path element states for a field of `kind`: the same name in descriptor.proto,
/// where a string is one type whether its UTF-8 is checked or not.
pub fn type_of(comptime kind: proto.Kind) Type {
    return switch (kind) {
        .double => .type_double,
        .float => .type_float,
        .int64 => .type_int64,
        .uint64 => .type_uint64,
        .int32 => .type_int32,
        .fixed64 => .type_fixed64,
        .fixed32 => .type_fixed32,
        .bool => .type_bool,
        .string, .unvalidated_string => .type_string,
        .group => .type_group,
        .message => .type_message,
        .bytes => .type_bytes,
        .uint32 => .type_uint32,
        .@"enum" => .type_enum,
        .sfixed32 => .type_sfixed32,
        .sfixed64 => .type_sfixed64,
        .sint32 => .type_sint32,
        .sint64 => .type_sint64,
    };
}

/// Which name of a field a search reads: its name in Zig, or its name in the .proto file.
pub const NameKind = enum { zig, proto };

/// An enum with one member for each field of `T`. A member's name is the field's name of
/// `kind`, and its value is the field's place in the descriptor. The compiler finds an enum's
/// member by its name in one step, where a comparison with each field's name takes it a step
/// for each octet of each field (docs/performance.md). It builds the enum once for each type:
/// the enum is a constant's value, which `table_once.zig` computes.
fn Names(comptime T: type, comptime kind: NameKind) type {
    return struct {
        const Enum: type = once.names_enum(T, kind);
    };
}

/// The place in the descriptor of `T` of the field whose name of `kind` is `name`, or null.
pub fn place_of_name(comptime T: type, comptime kind: NameKind, comptime name: []const u8) ?usize {
    const Enum = Names(T, kind).Enum;
    if (!@hasField(Enum, name)) return null;
    return @intFromEnum(@field(Enum, name));
}

/// The descriptor's entry of the field of `Message` whose Zig name is `name`.
pub fn field_named(comptime Message: type, comptime name: []const u8) proto.Field {
    const place = place_of_name(Message, .zig, name) orelse @compileError(Message.protobuf.full_name ++ " has no field " ++ name);
    return Message.protobuf.fields[place];
}

/// The path element of the rule `name` of the rule message `Message`: its number, its name in
/// validate.proto and its type.
pub fn rule_element(comptime Message: type, comptime name: []const u8) Element {
    const field = comptime field_named(Message, name);
    return .{ .field_number = @intCast(field.number), .field_name = field.proto_name, .field_type = comptime type_of(field.kind) };
}

/// The path of a rule within `buf.validate.FieldRules`: `prefix`, then one element for each
/// of `steps`, where a step names a rule message and one of its fields.
pub fn rule_path(comptime prefix: []const Element, comptime steps: []const Step) pb.FieldPath {
    comptime {
        var elements: []const Element = prefix;
        for (steps) |step| elements = elements ++ [_]Element{rule_element(step.message, step.name)};
        return .{ .elements = .of(elements) };
    }
}

pub const Step = struct { message: type, name: []const u8 };

const testing = std.testing;

const Sample = struct {
    name: []const u8 = "",
    pub const FieldNumber = enum(u29) { name = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Sample", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),
    } };
    pub const protovalidate: Rules = .{
        .fields = &.{.{ .number = @intFromEnum(FieldNumber.name), .rules = .{ .type = .{ .string = .{ .min_len = 1 } } } }},
    };
};

const Plain = struct {
    name: []const u8 = "",
    pub const FieldNumber = enum(u29) { name = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Plain", .fields = &.{
        proto.field_of(FieldNumber.name, .string, .{}),
    } };
};

/// A message whose second field has one name in Zig and another in its .proto file.
const Renamed = struct {
    plain: i32 = 0,
    kind_: i32 = 0,
    pub const FieldNumber = enum(u29) { plain = 1, kind = 2 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Renamed", .fields = &.{
        .{ .name = "plain", .number = @intFromEnum(FieldNumber.plain), .kind = .int32, .json_name = "plain", .proto_name = "plain" },
        .{ .name = "kind_", .number = @intFromEnum(FieldNumber.kind), .kind = .int32, .json_name = "kind", .proto_name = "kind" },
    } };
};

test "a field is found by its name in Zig, or by its name in the .proto file" {
    try testing.expectEqual(@as(?usize, 0), comptime place_of_name(Renamed, .zig, "plain"));
    try testing.expectEqual(@as(?usize, 1), comptime place_of_name(Renamed, .zig, "kind_"));
    try testing.expectEqual(@as(?usize, null), comptime place_of_name(Renamed, .zig, "kind"));
    try testing.expectEqual(@as(?usize, 0), comptime place_of_name(Renamed, .proto, "plain"));
    try testing.expectEqual(@as(?usize, 1), comptime place_of_name(Renamed, .proto, "kind"));
    try testing.expectEqual(@as(?usize, null), comptime place_of_name(Renamed, .proto, "kind_"));
    try testing.expectEqual(@as(?usize, null), comptime place_of_name(Renamed, .proto, "missing"));
    try testing.expectEqualStrings("kind", (comptime field_named(Renamed, "kind_")).proto_name);
    try testing.expectEqualStrings("name", (comptime field_named(Sample, "name")).name);
}

test "a table is found by its declaration, and a field's rules by its number" {
    try testing.expect(comptime has_rules(Sample));
    try testing.expect(comptime !has_rules(Plain));
    try testing.expect(comptime !has_rules(u32));
    const rules = (comptime field_rules(Sample, 1)) orelse return error.TestExpectedRules;
    const typed = rules.type orelse return error.TestExpectedRules;
    try testing.expectEqual(@as(?u64, 1), typed.string.min_len);
    try testing.expect(comptime field_rules(Sample, 2) == null);
    try testing.expect(comptime field_rules(Plain, 1) == null);
}

/// A message of five fields whose table holds entries for three of them, out of order, and a
/// second entry for one.
fn Wide(comptime numbers: [wide_len]u32) type {
    return struct {
        a: i32 = 0,
        b: i32 = 0,
        c: i32 = 0,
        d: i32 = 0,
        e: i32 = 0,
        pub const protobuf: proto.Descriptor = .{ .full_name = "t.Wide", .fields = &.{
            .{ .name = "a", .number = numbers[0], .kind = .int32, .json_name = "a", .proto_name = "a" },
            .{ .name = "b", .number = numbers[1], .kind = .int32, .json_name = "b", .proto_name = "b" },
            .{ .name = "c", .number = numbers[wide_c], .kind = .int32, .json_name = "c", .proto_name = "c" },
            .{ .name = "d", .number = numbers[wide_d], .kind = .int32, .json_name = "d", .proto_name = "d" },
            .{ .name = "e", .number = numbers[wide_e], .kind = .int32, .json_name = "e", .proto_name = "e" },
        } };
        pub const protovalidate: Rules = .{
            .fields = &.{
                .{ .number = numbers[wide_e], .rules = .{ .type = .{ .int32 = .{ .@"const" = wide_e } } }, .predefined = &.{
                    .{ .site = .items, .number = extension_number, .name = "t.x", .type = .type_bool, .value = .{ .boolean = true }, .cel = &.{} },
                    .{ .number = extension_number, .name = "t.y", .type = .type_bool, .value = .{ .boolean = true }, .cel = &.{} },
                } },
                .{ .number = numbers[0], .rules = .{ .type = .{ .int32 = .{ .@"const" = 0 } } } },
                .{ .number = numbers[wide_c], .rules = .{ .type = .{ .int32 = .{ .@"const" = wide_c } } } },
                // A second entry of one field, which the first one hides.
                .{ .number = numbers[0], .rules = .{ .type = .{ .int32 = .{ .@"const" = 1 } } } },
                // An entry of no field.
                .{ .number = missing_number, .rules = .{} },
            },
        };
    };
}
const wide_len = 5;
const wide_c = 2;
const wide_d = 3;
const wide_e = 4;
const extension_number = 1161;
const missing_number = 99;

test "a field's entry is found by its number, whatever the order of the table and of the descriptor" {
    // Numbers that rise, which a search halves, and numbers that do not, which it reads in turn.
    inline for (.{ [wide_len]u32{ 1, 3, 7, 20, 536_870_911 }, [wide_len]u32{ 20, 3, 536_870_911, 1, 7 } }) |numbers| {
        const W = Wide(numbers);
        inline for (numbers, 0..) |number, place| try testing.expectEqual(@as(?usize, place), comptime place_of(W, number));
        inline for (.{ 0, 2, 8, 19, 21, missing_number }) |absent| try testing.expect(comptime place_of(W, absent) == null);
        try testing.expectEqual(@as(?i32, 0), (comptime field_rules(W, numbers[0])).?.type.?.int32.@"const");
        try testing.expectEqual(@as(?i32, wide_c), (comptime field_rules(W, numbers[wide_c])).?.type.?.int32.@"const");
        try testing.expectEqual(@as(?i32, wide_e), (comptime field_rules(W, numbers[wide_e])).?.type.?.int32.@"const");
        try testing.expect(comptime field_rules(W, numbers[1]) == null);
        try testing.expect(comptime field_rules(W, numbers[wide_d]) == null);
        try testing.expect(comptime field_rules(W, missing_number) == null);
        try testing.expectEqual(@as(?usize, 1), comptime entry_of(W, numbers[0]));
        // A field's predefined rules are those of its entry that lie at the site asked for.
        const at_items = comptime predefined_of(W, numbers[wide_e], .items);
        try testing.expectEqual(@as(usize, 1), at_items.len);
        try testing.expectEqualStrings("t.x", at_items[0].name);
        try testing.expectEqualStrings("t.y", (comptime predefined_of(W, numbers[wide_e], .field))[0].name);
        try testing.expectEqual(@as(usize, 0), (comptime predefined_of(W, numbers[wide_e], .keys)).len);
        try testing.expectEqual(@as(usize, 0), (comptime predefined_of(W, numbers[0], .field)).len);
    }
}

test "a rule's path takes each number, name and type from validate.proto's descriptors" {
    const path = comptime rule_path(&.{}, &.{ .{ .message = pb.FieldRules, .name = "string" }, .{ .message = pb.StringRules, .name = "min_len" } });
    const elements = path.elements.items;
    try testing.expectEqual(@as(usize, 2), elements.len);
    try testing.expectEqual(@as(?i32, 14), elements[0].field_number);
    try testing.expectEqualStrings("string", elements[0].field_name.?);
    try testing.expectEqual(@as(?Type, .type_message), elements[0].field_type);
    try testing.expectEqual(@as(?i32, 2), elements[1].field_number);
    try testing.expectEqualStrings("min_len", elements[1].field_name.?);
    try testing.expectEqual(@as(?Type, .type_uint64), elements[1].field_type);
    // A prefix leads the path, as `repeated.items` leads an element's rule.
    const nested = comptime rule_path(path.elements.items, &.{.{ .message = pb.Int32Rules, .name = "const" }});
    try testing.expectEqual(@as(usize, 3), nested.elements.items.len);
    try testing.expectEqualStrings("const", nested.elements.items[2].field_name.?);
    try testing.expectEqual(@as(?Type, .type_int32), nested.elements.items[2].field_type);
}

test "a path element's type is the descriptor's, and a string's is one type" {
    try testing.expectEqual(Type.type_string, type_of(.unvalidated_string));
    try testing.expectEqual(Type.type_string, type_of(.string));
    try testing.expectEqual(Type.type_group, type_of(.group));
    try testing.expectEqual(Type.type_sint64, type_of(.sint64));
    try testing.expectEqual(Type.type_enum, type_of(.@"enum"));
}
