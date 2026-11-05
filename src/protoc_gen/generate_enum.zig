//! Writes an enum and a service. An enum's tags are its value names in snake case, and its table
//! names each value's number through a tag, aliases through the tag that holds their number. A
//! service is a struct of one `connect.Method` for each RPC.
const std = @import("std");
const pb = @import("descriptor_pb.zig");
const names = @import("names.zig");
const index_file = @import("index.zig");
const generate_out = @import("generate_out.zig");
const Out = generate_out.Out;
const Error = generate_out.Error;

pub fn write(out: *Out, scope: []const u8, enumeration: pb.EnumDescriptorProto, depth: usize) Error!void {
    const name = enumeration.name orelse "";
    const full = try generate_out.full_name(out.arena, scope, name);
    try out.print("\n", .{});
    try out.indent(depth);
    try out.print("pub const {s} = enum(i32) {{\n", .{try names.identifier(out.arena, name)});
    // The first name of each number is its tag; an alias repeats a number, which a Zig enum cannot.
    var tags: std.AutoArrayHashMapUnmanaged(i32, []const u8) = .empty;
    var values = enumeration.value.iterator();
    while (try values.next()) |value| {
        const number = value.number orelse 0;
        const entry = try tags.getOrPut(out.arena, number);
        if (entry.found_existing) continue;
        entry.value_ptr.* = try names.field_identifier(out.arena, try names.snake_case(out.arena, value.name orelse ""));
        try out.indent(depth + 1);
        try out.print("{s} = {d},\n", .{ entry.value_ptr.*, number });
    }
    try out.indent(depth + 1);
    try out.print("_,\n\n", .{});
    try out.indent(depth + 1);
    try out.print("pub const protobuf: proto.EnumDescriptor = .{{ .full_name = {s}, .values = &.{{\n", .{try names.string_literal(out.arena, full)});
    var named = enumeration.value.iterator();
    while (try named.next()) |value| {
        try out.indent(depth + 1 + 1);
        try out.print(".{{ .name = {s}, .number = @intFromEnum(@This().{s}) }},\n", .{
            try names.string_literal(out.arena, value.name orelse ""),
            tags.get(value.number orelse 0).?,
        });
    }
    try out.indent(depth + 1);
    try out.print("}} }};\n", .{});
    try out.indent(depth);
    try out.print("}};\n", .{});
}

pub fn write_service(out: *Out, package: []const u8, service: pb.ServiceDescriptorProto) Error!void {
    out.uses_connect = true;
    const name = service.name orelse "";
    try out.print("\npub const {s} = struct {{\n", .{try names.identifier(out.arena, name)});
    try out.print("    pub const service_name = {s};\n", .{try names.string_literal(out.arena, try generate_out.full_name(out.arena, package, name))});
    var methods = service.method.iterator();
    while (try methods.next()) |method| try write_method(out, method);
    try write_routes(out, service);
    try out.print("}};\n", .{});
}

/// `Routes`: every method as a route of a transport such as `connect_colibri`, which a program
/// passes in, so generated code imports no HTTP library (decision 2). A method with no side
/// effects is served as a GET too (Connect protocol, "Unary-Get-Request"). The routes are a
/// declaration's literal, not a function's result, so a router joins them with `++` at comptime.
fn write_routes(out: *Out, service: pb.ServiceDescriptorProto) Error!void {
    var entries: std.ArrayList(u8) = .empty;
    var methods = service.method.iterator();
    while (try methods.next()) |method| {
        const field = try names.identifier(out.arena, try names.snake_case(out.arena, method.name orelse ""));
        try entries.print(out.arena, "                transport.post(App, {s}, Handlers.{s}, options),\n", .{ field, field });
        if (no_side_effects(method)) try entries.print(out.arena, "                transport.get(App, {s}, Handlers.{s}, options),\n", .{ field, field });
    }
    try out.print(
        \\
        \\    /// Every method as a route of `transport`, such as `connect_colibri`, in `routes`. Each
        \\    /// handler is the declaration of `Handlers` the method names, so one a service lacks fails
        \\    /// to compile.
        \\    pub fn Routes(comptime transport: type, comptime App: type, comptime Handlers: type, comptime options: transport.RouteOptions) type {{
        \\        return struct {{
        \\            pub const routes = .{{
        \\{s}            }};
        \\        }};
        \\    }}
        \\
    , .{entries.items});
}

/// Whether a method is served as a GET too: a unary method with no side effects (Connect
/// protocol, "Unary-Get-Request"). A stream is never a GET, whatever its idempotency.
fn no_side_effects(method: pb.MethodDescriptorProto) bool {
    if ((method.client_streaming orelse false) or (method.server_streaming orelse false)) return false;
    const options = method.options orelse return false;
    return (options.idempotency_level orelse .idempotency_unknown) == .no_side_effects;
}

fn stream_type_of(method: pb.MethodDescriptorProto) []const u8 {
    const client_stream = method.client_streaming orelse false;
    const server_stream = method.server_streaming orelse false;
    if (client_stream and server_stream) return "bidi_stream";
    if (client_stream) return "client_stream";
    if (server_stream) return "server_stream";
    return "unary";
}

fn write_method(out: *Out, method: pb.MethodDescriptorProto) Error!void {
    const level = if (method.options) |options| options.idempotency_level orelse .idempotency_unknown else .idempotency_unknown;
    const idempotency = switch (level) {
        .no_side_effects => "no_side_effects",
        .idempotent => "idempotent",
        else => "unknown",
    };
    const method_name = method.name orelse "";
    try out.print("\n    pub const {s}: connect.Method = .{{\n", .{try names.identifier(out.arena, try names.snake_case(out.arena, method_name))});
    try out.print("        .service = service_name,\n        .name = {s},\n", .{try names.string_literal(out.arena, method_name)});
    try out.print("        .Request = {s},\n", .{try out.reference(index_file.strip_dot(method.input_type orelse ""))});
    try out.print("        .Response = {s},\n", .{try out.reference(index_file.strip_dot(method.output_type orelse ""))});
    try out.print("        .stream_type = .{s},\n        .idempotency = .{s},\n    }};\n", .{ stream_type_of(method), idempotency });
}
