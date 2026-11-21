//! Reads a field's predefined rules and writes them as the `predefined` list of the field's
//! entry in its message's table (design §8 step 34). A predefined rule is an extension of one
//! of validate.proto's rule messages, whose declaration states CEL rules in
//! `(buf.validate.predefined)` (validate.proto, PredefinedRules).
//!
//! The generated rule types do not know an extension, so each one arrives as a record among the
//! unknown fields of a rule message. The request's files declare it, and `Index.extension_of`
//! finds the declaration by the rule message's name and the record's number. The protobuf
//! module then reads the extension's values through a `Repeated` view of the span.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const proto = @import("protobuf");
const validate = @import("buf_validate_validate");
const pb = @import("descriptor_pb.zig");
const names = @import("names.zig");
const index_file = @import("index.zig");
const rules_literal = @import("rules_literal.zig");
const constants = @import("constants.zig");
const protocol = proto.constants.protocol;
const Writer = rules_literal.Writer;

pub const Error = rules_literal.Error;

/// Which of a field's rules hold an extension, as the table's `Predefined.Where` names them.
pub const Site = enum { field, items, keys, values };

/// One value of an extension, as a member of the table's `Predefined.Value` holds it.
pub const Value = union(enum) { boolean: bool, int: i64, uint: u64, double: f64, string: []const u8, bytes: []const u8 };

/// One extension that a field's rules hold, with the values of its records.
pub const Entry = struct {
    /// The names from the field to the extension, "val.float.(my.rules.abs_range)", which name
    /// the entry's numbers in `RuleNumber`.
    name: []const u8,
    site: Site,
    number: u32,
    extension: index_file.Extension,
    /// The type of each value: the extension's own, or the one its wrapper holds.
    kind: pb.Type,
    values: std.ArrayList(Value) = .empty,

    fn is_list(entry: *const Entry) bool {
        return entry.extension.field.label == .repeated;
    }
};

/// A scalar type: how the plugin's descriptor names it, the Zig type that holds one value, and
/// how the protobuf module reads it. An enum's value is read as the int32 it is on the wire.
const Scalar = struct { type: pb.Type, Zig: type, kind: proto.Kind };
const scalars = [_]Scalar{
    .{ .type = .double, .Zig = f64, .kind = .double },
    .{ .type = .float, .Zig = f32, .kind = .float },
    .{ .type = .int64, .Zig = i64, .kind = .int64 },
    .{ .type = .uint64, .Zig = u64, .kind = .uint64 },
    .{ .type = .int32, .Zig = i32, .kind = .int32 },
    .{ .type = .fixed64, .Zig = u64, .kind = .fixed64 },
    .{ .type = .fixed32, .Zig = u32, .kind = .fixed32 },
    .{ .type = .bool, .Zig = bool, .kind = .bool },
    .{ .type = .string, .Zig = []const u8, .kind = .string },
    .{ .type = .bytes, .Zig = []const u8, .kind = .bytes },
    .{ .type = .uint32, .Zig = u32, .kind = .uint32 },
    .{ .type = .@"enum", .Zig = i32, .kind = .int32 },
    .{ .type = .sfixed32, .Zig = i32, .kind = .sfixed32 },
    .{ .type = .sfixed64, .Zig = i64, .kind = .sfixed64 },
    .{ .type = .sint32, .Zig = i32, .kind = .sint32 },
    .{ .type = .sint64, .Zig = i64, .kind = .sint64 },
};

/// The wrappers of wrappers.proto, each of which holds its value in field 1. CEL reads a
/// wrapper as the scalar it holds.
const wrappers = [_]struct { name: []const u8, kind: pb.Type }{
    .{ .name = ".google.protobuf.DoubleValue", .kind = .double },
    .{ .name = ".google.protobuf.FloatValue", .kind = .float },
    .{ .name = ".google.protobuf.Int64Value", .kind = .int64 },
    .{ .name = ".google.protobuf.UInt64Value", .kind = .uint64 },
    .{ .name = ".google.protobuf.Int32Value", .kind = .int32 },
    .{ .name = ".google.protobuf.UInt32Value", .kind = .uint32 },
    .{ .name = ".google.protobuf.BoolValue", .kind = .bool },
    .{ .name = ".google.protobuf.StringValue", .kind = .string },
    .{ .name = ".google.protobuf.BytesValue", .kind = .bytes },
};

/// A wrapper as the protobuf module decodes it. Its value is optional, so a record that states
/// none is told from one that states the default.
fn Wrapper(comptime scalar: Scalar) type {
    return struct {
        value: ?scalar.Zig = null,
        pub const FieldNumber = enum(u29) { value = 1 };
        pub const protobuf: proto.Descriptor = .{ .full_name = "google.protobuf.Wrapper", .fields = &.{
            proto.field_of(FieldNumber.value, scalar.kind, .{}),
        } };
    };
}

/// One record of a message: its field's number, and whether a group starts or ends at it.
const Record = struct { number: u32, is_group: bool };

/// Walks the records of a message's bytes, and reads no value: the protobuf module's
/// `Repeated` reads the values of one number, and gives no list of the numbers.
const Records = struct {
    bytes: []const u8,
    position: usize = 0,

    /// The next record, or null at the end. The walk stops at a group, whose end it does not
    /// look for.
    fn next(records: *Records) proto.Error!?Record {
        if (records.position == records.bytes.len) return null;
        const tag = try records.varint();
        // "Message Structure" (encoding guide): the low three bits of a tag hold the wire type.
        const wire_type: proto.WireType = @enumFromInt(@as(u3, @truncate(tag)));
        const number = std.math.cast(u32, tag >> protocol.wire_type_bits) orelse return error.InvalidFieldNumber;
        const len: u64 = switch (wire_type) {
            .varint => skipped: {
                _ = try records.varint();
                break :skipped 0;
            },
            .i64 => protocol.fixed64_len,
            .i32 => protocol.fixed32_len,
            .len => try records.varint(),
            else => return .{ .number = number, .is_group = true },
        };
        // "Length-Delimited Records": the length must fit in what remains.
        if (len > records.bytes.len - records.position) return error.Truncated;
        records.position += @intCast(len);
        return .{ .number = number, .is_group = false };
    }

    /// "Base 128 Varints" (encoding guide): seven bits an octet, the least significant group
    /// first, in at most 10 octets. An octet with no continuation bit is the last.
    fn varint(records: *Records) proto.Error!u64 {
        var value: u64 = 0;
        for (0..protocol.varint_len_max) |at| {
            if (records.position == records.bytes.len) return error.Truncated;
            const octet = records.bytes[records.position];
            records.position += 1;
            const shift: u6 = @intCast(at * protocol.varint_group_bits);
            value |= @as(u64, octet & protocol.varint_payload_mask) << shift;
            if (octet & protocol.varint_continuation == 0) return value;
        }
        return error.VarintTooLong;
    }
};

/// Reads the fields of `message` that the rule message `T` does not know, from the span that
/// holds them. A record of an extension with predefined rules joins the writer's entries. A
/// record that no extension of the request declares marks the table unsupported: a later
/// validate.proto states it, and its rule must not go unchecked.
pub fn read(writer: *Writer, comptime T: type, bytes: []const u8) Error!void {
    return read_span(writer, T.protobuf.full_name, comptime numbers_of(T), bytes);
}

/// The numbers of the fields that `T` knows.
fn numbers_of(comptime T: type) []const u32 {
    comptime {
        var numbers: []const u32 = &.{};
        for (T.protobuf.fields) |field| numbers = numbers ++ [_]u32{field.number};
        return numbers;
    }
}

fn read_span(writer: *Writer, extendee: []const u8, known: []const u32, bytes: []const u8) Error!void {
    var records: Records = .{ .bytes = bytes };
    // Each record takes at least one byte, so the bytes' length bounds the records.
    for (0..bytes.len) |_| {
        const record = try records.next() orelse return;
        // The span runs from the first unknown record to the last, so it holds the known
        // records between them too (decision 24).
        if (std.mem.indexOfScalar(u32, known, record.number) != null) continue;
        if (record.is_group) return writer.refuse("{s} holds a group in field {d}, which the plugin does not read", .{ extendee, record.number });
        const before = writer.predefined.items.len;
        const entry = try entry_of(writer, extendee, record.number) orelse continue;
        // The first record of an extension reads each of its records.
        if (writer.predefined.items.len != before) try read_values(writer, entry, bytes);
    }
}

/// The entry of the extension numbered `number`, or null for a record whose value the plugin
/// does not read: one it refuses, or an extension that states no rule.
fn entry_of(writer: *Writer, extendee: []const u8, number: u32) Error!?*Entry {
    const index = writer.index orelse return unknown(writer, extendee, number);
    const extension = try index.extension_of(writer.arena, extendee, number) orelse return unknown(writer, extendee, number);
    // An extension with no `(buf.validate.predefined).cel` states no rule (validate.proto,
    // PredefinedRules).
    if (!states_rule(extension)) return null;
    const site = try site_of(writer) orelse {
        try writer.refuse("({s}) lies outside a field's rules, where the plugin reads no predefined rule", .{extension.full_name});
        return null;
    };
    const kind = kind_of(extension.field) orelse {
        try writer.refuse("({s}) is no scalar, wrapper or list of them, so the plugin writes no value for its rule (docs/design.md §8 step 34)", .{extension.full_name});
        return null;
    };
    const name = try std.fmt.allocPrint(writer.arena, "{s}.({s})", .{ try writer.path_name(), extension.full_name });
    for (writer.predefined.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    try writer.predefined.append(writer.arena, .{ .name = name, .site = site, .number = number, .extension = extension, .kind = kind });
    return &writer.predefined.items[writer.predefined.items.len - 1];
}

fn unknown(writer: *Writer, extendee: []const u8, number: u32) Error!?*Entry {
    try writer.refuse("{s} holds field {d}, which neither the plugin's validate.proto nor an extension of the request states", .{ extendee, number });
    return null;
}

fn states_rule(extension: index_file.Extension) bool {
    const options = extension.field.options orelse return false;
    const predefined = options.predefined orelse return false;
    return !predefined.cel.is_empty();
}

/// Where the rule message being written lies in a field's rules, from the names that lead to
/// it: "val.float" is the field's own, and "val.repeated.items.float" its elements'.
fn site_of(writer: *Writer) Allocator.Error!?Site {
    const path = writer.path.items;
    if (!writer.in_field or path.len < constants.own_rules_path_len) return null;
    const between = try std.mem.join(writer.arena, ".", path[1 .. path.len - 1]);
    if (between.len == 0) return .field;
    if (std.mem.eql(u8, between, "repeated.items")) return .items;
    if (std.mem.eql(u8, between, "map.keys")) return .keys;
    if (std.mem.eql(u8, between, "map.values")) return .values;
    return null;
}

/// The type of an extension's values, or null for one the table's `Predefined.Value` cannot
/// hold: a group, a message that is no wrapper, or a list of bytes.
fn kind_of(field: pb.FieldDescriptorProto) ?pb.Type {
    const kind = field.type orelse return null;
    const scalar_kind = switch (kind) {
        .message => wrapped_kind(field.type_name orelse "") orelse return null,
        .group, _ => return null,
        else => kind,
    };
    if (scalar_kind == .bytes and field.label == .repeated) return null;
    return scalar_kind;
}

fn wrapped_kind(type_name: []const u8) ?pb.Type {
    for (wrappers) |wrapper| {
        if (std.mem.eql(u8, wrapper.name, type_name)) return wrapper.kind;
    }
    return null;
}

/// Reads each record of the entry's extension from `bytes`, the span that holds them.
fn read_values(writer: *Writer, entry: *Entry, bytes: []const u8) Error!void {
    const is_wrapper = entry.extension.field.type == .message;
    inline for (scalars) |scalar| {
        if (entry.kind == scalar.type) {
            if (is_wrapper) return read_wrappers(writer, entry, scalar, bytes);
            return read_scalars(writer, entry, scalar, bytes);
        }
    }
    unreachable;
}

/// A view of the span reads the records of one number, packed or not ("Packed Repeated
/// Fields", encoding guide), and passes over each other record.
fn read_scalars(writer: *Writer, entry: *Entry, comptime scalar: Scalar, bytes: []const u8) Error!void {
    const list: proto.Repeated(scalar.Zig, scalar.kind) = .{ .view = .{ .bytes = bytes, .number = entry.number } };
    var values = list.iterator();
    // Each value takes at least one byte, so the span's length bounds the values.
    for (0..bytes.len) |_| {
        const value = try values.next() orelse return;
        try put(writer, entry, value_of(scalar, value));
    }
}

/// A wrapper that is no list merges its records ("Last One Wins", encoding guide), so a record
/// that states no value keeps the value of the one before it.
fn read_wrappers(writer: *Writer, entry: *Entry, comptime scalar: Scalar, bytes: []const u8) Error!void {
    const list: proto.Repeated(Wrapper(scalar), .message) = .{ .view = .{ .bytes = bytes, .number = entry.number } };
    var holders = list.iterator();
    var merged: scalar.Zig = default_of(scalar);
    // Each record takes at least one byte, so the span's length bounds the records.
    for (0..bytes.len) |_| {
        const holder = try holders.next() orelse return;
        if (entry.is_list()) merged = default_of(scalar);
        if (holder.value) |stated| merged = stated;
        try put(writer, entry, value_of(scalar, merged));
    }
}

fn default_of(comptime scalar: Scalar) scalar.Zig {
    return switch (@typeInfo(scalar.Zig)) {
        .bool => false,
        .pointer => "",
        else => 0,
    };
}

/// A value as the member of the table's `Predefined.Value` that holds its type.
fn value_of(comptime scalar: Scalar, value: scalar.Zig) Value {
    return switch (@typeInfo(scalar.Zig)) {
        .bool => .{ .boolean = value },
        .int => |int| if (int.signedness == .signed) .{ .int = value } else .{ .uint = value },
        .float => .{ .double = value },
        .pointer => if (scalar.kind == .bytes) .{ .bytes = value } else .{ .string = value },
        else => comptime unreachable,
    };
}

/// Keeps `value`: as the next of a list, or in place of the value an earlier record gave
/// ("Last One Wins", encoding guide).
fn put(writer: *Writer, entry: *Entry, value: Value) Allocator.Error!void {
    if (!entry.is_list()) entry.values.clearRetainingCapacity();
    try entry.values.append(writer.arena, value);
}

/// The members of the table's `Predefined.Value` that hold one value of a type, and a list
/// of them.
const Members = struct { one: []const u8, list: []const u8 };

fn members_of(kind: pb.Type) Members {
    return switch (kind) {
        .bool => .{ .one = "boolean", .list = "booleans" },
        .uint32, .uint64, .fixed32, .fixed64 => .{ .one = "uint", .list = "uints" },
        .float, .double => .{ .one = "double", .list = "doubles" },
        .string => .{ .one = "string", .list = "strings" },
        // `kind_of` gives no list of bytes.
        .bytes => .{ .one = "bytes", .list = "bytes" },
        else => .{ .one = "int", .list = "ints" },
    };
}

/// Writes `, .predefined = &.{ ... }` for the entries read since the last call, and forgets
/// them. It writes nothing when there is none.
pub fn write(writer: *Writer) Error!void {
    const entries = writer.predefined.items;
    if (entries.len == 0) return;
    // An entry's name holds the names that led to it, so it names its numbers alone.
    const outer = writer.path;
    writer.path = .empty;
    defer writer.path = outer;
    const alone = entries.len == 1;
    try writer.text.appendSlice(writer.arena, ", .predefined = &.{");
    for (entries, 0..) |*entry, at| {
        if (!alone) try writer.text.appendSlice(writer.arena, if (at == 0) " " else ", ");
        try write_entry(writer, entry);
    }
    try writer.text.appendSlice(writer.arena, if (alone) "}" else " }");
    writer.predefined.clearRetainingCapacity();
}

fn write_entry(writer: *Writer, entry: *const Entry) Error!void {
    const field = entry.extension.field;
    const members = members_of(entry.kind);
    try writer.path.append(writer.arena, entry.name);
    try writer.text.appendSlice(writer.arena, ".{ ");
    if (entry.site != .field) try writer.print(".site = .{s}, ", .{@tagName(entry.site)});
    try writer.text.appendSlice(writer.arena, ".number = ");
    try named(writer, "number", .{ .uint = entry.number });
    // The extension's type as descriptor.proto names it: TYPE_INT32 is the tag `type_int32`.
    try writer.print(", .name = {s}, .type = .type_{s}, .value = .{{ .{s} = ", .{
        try names.string_literal(writer.arena, entry.extension.full_name),
        @tagName(field.type.?),
        if (entry.is_list()) members.list else members.one,
    });
    try write_values(writer, entry);
    try writer.text.appendSlice(writer.arena, " }, .cel = &.{");
    try write_cel(writer, field.options.?.predefined.?.cel);
    try writer.text.appendSlice(writer.arena, " }");
    _ = writer.path.pop();
}

/// One value in place, or a list as zig fmt writes it: `&.{}`, `&.{a}` or `&.{ a, b }`.
fn write_values(writer: *Writer, entry: *const Entry) Error!void {
    const values = entry.values.items;
    if (!entry.is_list()) {
        assert(values.len == 1);
        return named(writer, "value", values[0]);
    }
    const alone = values.len <= 1;
    try writer.text.appendSlice(writer.arena, "&.{");
    for (values, 0..) |value, at| {
        if (!alone) try writer.text.appendSlice(writer.arena, if (at == 0) " " else ", ");
        try named(writer, try std.fmt.allocPrint(writer.arena, "value.{d}", .{at}), value);
    }
    try writer.text.appendSlice(writer.arena, if (alone) "}" else " }");
}

/// Writes `value`, whose number above 1 takes the name `part` under the entry's.
fn named(writer: *Writer, part: []const u8, value: Value) Error!void {
    try writer.path.append(writer.arena, part);
    switch (value) {
        .boolean => |boolean| try writer.text.appendSlice(writer.arena, if (boolean) "true" else "false"),
        inline .int, .uint => |integer| try writer.number(try std.fmt.allocPrint(writer.arena, "{d}", .{integer}), @abs(integer)),
        .double => |double| try rules_literal.float(writer, f64, double),
        inline .string, .bytes => |text| try writer.text.appendSlice(writer.arena, try names.string_literal(writer.arena, text)),
    }
    _ = writer.path.pop();
}

/// The extension's CEL rules, each as the literal of `buf.validate.Rule`, with the list's
/// closing brace.
fn write_cel(writer: *Writer, cel: anytype) Error!void {
    const alone = try cel.count() == 1;
    var rules = cel.iterator();
    var at: usize = 0;
    while (try rules.next()) |rule| : (at += 1) {
        if (!alone) try writer.text.appendSlice(writer.arena, if (at == 0) " " else ", ");
        try writer.path.append(writer.arena, try std.fmt.allocPrint(writer.arena, "cel.{d}", .{at}));
        try rules_literal.message(writer, validate.Rule, rule);
        _ = writer.path.pop();
    }
    try writer.text.appendSlice(writer.arena, if (alone) "}" else " }");
}
