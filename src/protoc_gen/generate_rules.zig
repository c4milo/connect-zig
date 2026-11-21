//! Writes a message's protovalidate rules as its table, `pub const protovalidate`, and the
//! numbers of those rules as `RuleNumber` (decision 47). A message has a table when it has a
//! rule or holds a message that has one, at any depth, so `protovalidate.validate` finds each
//! message it must read by its declaration. A message with no table keeps the code it had.
const std = @import("std");
const Allocator = std.mem.Allocator;
const validate = @import("buf_validate_validate");
const pb = @import("descriptor_pb.zig");
const names = @import("names.zig");
const index_file = @import("index.zig");
const generate_out = @import("generate_out.zig");
const rules_literal = @import("rules_literal.zig");
const rules_predefined = @import("rules_predefined.zig");
const constants = @import("constants.zig");
const Out = generate_out.Out;
const Index = index_file.Index;
const Writer = rules_literal.Writer;

pub const Error = generate_out.Error || rules_literal.Error;

/// A field with its rules, and the name of its number in the message's `FieldNumber`.
pub const Entry = struct { field: pb.FieldDescriptorProto, name: []const u8 };

/// Whether `message` states a rule: in its own options, in a field's or in a oneof's.
pub fn states_rule(message: pb.DescriptorProto) Error!bool {
    if (message.options) |options| {
        if (options.rules != null) return true;
    }
    var fields = message.field.iterator();
    while (try fields.next()) |field| {
        if (field_rules(field) != null) return true;
    }
    var oneofs = message.oneof_decl.iterator();
    while (try oneofs.next()) |oneof| {
        if (oneof_rules(oneof) != null) return true;
    }
    return false;
}

/// The rules of a field, in place: the pointer lasts as long as the field it reads.
fn field_rules(field: *const pb.FieldDescriptorProto) ?*const validate.FieldRules {
    const options = if (field.options) |*set| set else return null;
    return if (options.rules) |*rules| rules else null;
}

fn oneof_rules(oneof: *const pb.OneofDescriptorProto) ?*const validate.OneofRules {
    const options = if (oneof.options) |*set| set else return null;
    return if (options.rules) |*rules| rules else null;
}

/// Whether the message named `full_name` gets a table: it states a rule, or a field of it holds
/// a message that gets one. A map's entry is read through its field, so the entry's value counts
/// as the field's message.
pub fn has_table(index: *const Index, arena: Allocator, full_name: []const u8) Error!bool {
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    return reaches_rule(index, arena, &visited, full_name);
}

fn reaches_rule(index: *const Index, arena: Allocator, visited: *std.StringHashMapUnmanaged(void), full_name: []const u8) Error!bool {
    if (visited.contains(full_name)) return false;
    try visited.put(arena, full_name, {});
    const entry = index.get(full_name) catch return false;
    const message = entry.message orelse return false;
    if (try states_rule(message)) return true;
    var fields = message.field.iterator();
    while (try fields.next()) |field| {
        if (field.type != .message and field.type != .group) continue;
        const target = index_file.strip_dot(field.type_name orelse continue);
        if (try reaches_rule(index, arena, visited, target)) return true;
    }
    return false;
}

/// Writes the table of `message` after its descriptor, and `RuleNumber` after the table, or
/// nothing for a message with no table. `entries` holds each field in the message's order.
pub fn write(out: *Out, full: []const u8, message: pb.DescriptorProto, entries: []const Entry, depth: usize) Error!void {
    const map_entry = if (message.options) |options| options.map_entry orelse false else false;
    if (map_entry or !try has_table(out.index, out.arena, full)) return;
    try check_names(message);
    out.uses_protovalidate = true;
    var writer: Writer = .{ .arena = out.arena, .index = out.index };
    try write_message_rules(&writer, message, depth + 1);
    try write_field_rules(&writer, entries, depth + 1);
    try write_oneof_rules(&writer, message, depth + 1);
    if (writer.unsupported) |why| {
        try indent(&writer, depth + 1);
        try writer.text.print(out.arena, ".unsupported = {s},\n", .{try names.string_literal(out.arena, why)});
    }
    try out.print("\n", .{});
    try out.indent(depth);
    if (writer.text.items.len == 0) {
        try out.print("pub const {s}: validate.Rules = .{{}};\n", .{constants.rules_declaration});
        return;
    }
    const calls = std.mem.count(u8, writer.text.items, ".of(");
    if (calls > constants.table_calls_unraised_max) {
        try write_raised(out, &writer, calls, depth);
    } else {
        try out.print("pub const {s}: validate.Rules = .{{\n{s}", .{ constants.rules_declaration, writer.text.items });
        try out.indent(depth);
        try out.print("}};\n", .{});
    }
    try write_numbers(out, writer.numbers.items, depth);
}

/// Writes a table whose literal makes many calls, such as one of a message with hundreds of
/// rules: a block that raises the compiler's branch quota, then gives the literal. The quota
/// is a number of `RuleNumber`, as each of the table's numbers above 1 is.
fn write_raised(out: *Out, writer: *Writer, calls: usize, depth: usize) Error!void {
    const quota = constants.branches_default + constants.branches_per_call * calls;
    try writer.numbers.append(out.arena, .{ .name = constants.branches_name, .text = try std.fmt.allocPrint(out.arena, "{d}", .{quota}) });
    try out.print("pub const {s}: validate.Rules = table: {{\n", .{constants.rules_declaration});
    try out.indent(depth + 1);
    try out.print("@setEvalBranchQuota(@This().{s}.{s});\n", .{ constants.rule_number_container, try names.identifier(out.arena, constants.branches_name) });
    try out.indent(depth + 1);
    try out.print("break :table .{{\n", .{});
    // Each line of the literal lies one level deeper inside the block. A string literal holds
    // no line end, so each line end of the text ends a line of code.
    var lines = std.mem.splitScalar(u8, writer.text.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try out.print("    {s}\n", .{line});
    }
    try out.indent(depth + 1);
    try out.print("}};\n", .{});
    try out.indent(depth);
    try out.print("}};\n", .{});
}

/// A field, a nested message or a nested enum named as a declaration the generator adds would
/// collide with it.
fn check_names(message: pb.DescriptorProto) Error!void {
    var fields = message.field.iterator();
    while (try fields.next()) |field| try check_name(field.name orelse "");
    var nested = message.nested_type.iterator();
    while (try nested.next()) |child| try check_name(child.name orelse "");
    var enums = message.enum_type.iterator();
    while (try enums.next()) |enumeration| try check_name(enumeration.name orelse "");
    var oneofs = message.oneof_decl.iterator();
    while (try oneofs.next()) |oneof| try check_name(oneof.name orelse "");
}

fn check_name(name: []const u8) Error!void {
    if (std.mem.eql(u8, name, constants.rules_declaration)) return error.NameCollision;
    if (std.mem.eql(u8, name, constants.rule_number_container)) return error.NameCollision;
}

fn indent(writer: *Writer, depth: usize) Allocator.Error!void {
    for (0..depth) |_| try writer.text.appendSlice(writer.arena, "    ");
}

/// `.message = .{ ... },`: `(buf.validate.message)`.
fn write_message_rules(writer: *Writer, message: pb.DescriptorProto, depth: usize) Error!void {
    const options = message.options orelse return;
    const rules = if (options.rules) |*set| set else return;
    try indent(writer, depth);
    try writer.text.appendSlice(writer.arena, ".message = ");
    // No field is named with a dot, so no field's numbers share this name.
    try writer.path.append(writer.arena, ".message");
    try rules_literal.message(writer, @TypeOf(rules.*), rules);
    _ = writer.path.pop();
    try writer.text.appendSlice(writer.arena, ",\n");
}

/// `.fields = &.{ ... },`: one line for each field with `(buf.validate.field)`, which ends with
/// the predefined rules that the field's rules hold.
fn write_field_rules(writer: *Writer, entries: []const Entry, depth: usize) Error!void {
    var opened = false;
    for (entries) |*entry| {
        const rules = field_rules(&entry.field) orelse continue;
        if (!opened) {
            try indent(writer, depth);
            try writer.text.appendSlice(writer.arena, ".fields = &.{\n");
            opened = true;
        }
        try indent(writer, depth + 1);
        try writer.text.print(writer.arena, ".{{ .number = @intFromEnum(@This().FieldNumber.{s}), .rules = ", .{entry.name});
        try writer.path.append(writer.arena, entry.field.name orelse "");
        writer.in_field = true;
        try rules_literal.message(writer, @TypeOf(rules.*), rules);
        writer.in_field = false;
        _ = writer.path.pop();
        try rules_predefined.write(writer);
        try writer.text.appendSlice(writer.arena, " },\n");
    }
    if (!opened) return;
    try indent(writer, depth);
    try writer.text.appendSlice(writer.arena, "},\n");
}

/// `.oneofs = &.{ ... },`: one line for each oneof with `(buf.validate.oneof)`.
fn write_oneof_rules(writer: *Writer, message: pb.DescriptorProto, depth: usize) Error!void {
    var opened = false;
    var oneofs = message.oneof_decl.iterator();
    while (try oneofs.next()) |oneof| {
        const rules = oneof_rules(oneof) orelse continue;
        if (!opened) {
            try indent(writer, depth);
            try writer.text.appendSlice(writer.arena, ".oneofs = &.{\n");
            opened = true;
        }
        const name = oneof.name orelse "";
        try indent(writer, depth + 1);
        // The union field's Zig name, as the descriptor's `.oneof` holds it, and the .proto name.
        try writer.text.print(writer.arena, ".{{ .field = {s}, .name = {s}, .rules = ", .{
            try names.string_literal(writer.arena, try names.member_name(writer.arena, name)),
            try names.string_literal(writer.arena, name),
        });
        try writer.path.append(writer.arena, name);
        try rules_literal.message(writer, @TypeOf(rules.*), rules);
        _ = writer.path.pop();
        try writer.text.appendSlice(writer.arena, " },\n");
    }
    if (!opened) return;
    try indent(writer, depth);
    try writer.text.appendSlice(writer.arena, "},\n");
}

/// `pub const RuleNumber = struct { ... };`: each number above 1 that the table holds, named for
/// its field and its rule.
fn write_numbers(out: *Out, numbers: []const rules_literal.Number, depth: usize) Error!void {
    if (numbers.len == 0) return;
    try out.print("\n", .{});
    try out.indent(depth);
    try out.print("pub const {s} = struct {{\n", .{constants.rule_number_container});
    for (numbers) |number| {
        try out.indent(depth + 1);
        try out.print("pub const {s} = {s};\n", .{ try names.identifier(out.arena, number.name), number.text });
    }
    try out.indent(depth);
    try out.print("}};\n", .{});
}
