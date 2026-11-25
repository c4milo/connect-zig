//! The Zig side of the CEL conformance check (`tools/cel_conformance_check.sh`).
//!
//! The check writes `cases.zig`: one case for each test of cel-spec's conformance suite that
//! declares no variables, with its full name and its expression. This program compiles each
//! expression as a rule's expression compiles, runs it, and prints one line for each case: the
//! name, a tab, and the result as JSON. The result is the value in the form of cel-spec's
//! `cel.expr.Value`, as `{"int64Value":"1"}`, or `{"error":"Unevaluable"}` for an expression
//! that fails as it runs, or `{"refused":"..."}` with the problem of one that does not compile.
//! `tools/cel_conformance/compare.py` compares the lines with the suite's expected results.
const std = @import("std");
const proto = @import("protobuf");
const cel = @import("cel_expression");
const platform = @import("stdx").platform;
const cases = @import("cases");

/// The suite's expressions read no names.
const scope: cel.Scope = .{ .names = &.{}, .types = &.{} };
/// The build target's CPU features, which `matches` searches with. The answers are the same
/// with any features.
const features: platform.CpuFeatures = .target();
/// The room an expression writes its text into, and the room of one value's JSON.
const room_len = 65_536;
const value_text_len_max = 65_536;
const io_buffer_len = 65_536;
/// The branches the compiler may take to unroll the loop over the cases: a hundred for each.
const branches_per_case = 100;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const room = try arena.alloc(u8, room_len);
    const value_text = try arena.alloc(u8, value_text_len_max);
    const out_buffer = try arena.alloc(u8, io_buffer_len);
    var stdout = std.Io.File.stdout().writerStreaming(init.io, out_buffer);
    const out = &stdout.interface;
    @setEvalBranchQuota(branches_per_case * cases.cases.len);
    inline for (cases.cases) |case| {
        try out.print("{s}\t", .{case.name});
        try run_case(case.expr, room, value_text, out);
        try out.writeAll("\n");
    }
    try out.flush();
}

/// Writes the result of one expression: its value, its failure, or why it does not compile.
fn run_case(comptime text: []const u8, room: []u8, value_text: []u8, out: *std.Io.Writer) !void {
    if (comptime cel.problem_of(text, scope)) |problem| {
        try out.writeAll("{\"refused\":");
        try std.json.Stringify.encodeJsonString(problem, .{}, out);
        return out.writeAll("}");
    } else {
        var written: cel.Text = .{ .room = room };
        var env: cel.Env = .{ .cpu_features = &features, .text = &written };
        const value = cel.run(text, scope, .{}, &env) catch |failure| return out.print("{{\"error\":\"{s}\"}}", .{@errorName(failure)});
        // A list is read as it is written, and a read may fail: the value is written whole
        // before any of it goes out.
        var value_writer: std.Io.Writer = .fixed(value_text);
        write_value(value, &env, &value_writer) catch |failure| return out.print("{{\"error\":\"{s}\"}}", .{@errorName(failure)});
        return out.writeAll(value_writer.buffered());
    }
}

const WriteError = std.Io.Writer.Error || cel.Error;

/// A value in the JSON form of `cel.expr.Value`. A bytes value is written in hexadecimal, a
/// double as Zig's shortest text of it, and a timestamp and a duration as their seconds and
/// nanoseconds, which compare.py reads.
fn write_value(value: anytype, env: *cel.Env, out: *std.Io.Writer) WriteError!void {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .optional) {
        if (value) |held| return write_value(held, env, out);
        return out.writeAll("{\"nullValue\":null}");
    }
    if (comptime cel.is_list(T)) return write_list(value, env, out);
    if (comptime cel.is_map(T)) return write_map(value, env, out);
    if (comptime cel.is_mixed_list(T)) return write_mixed_list(value, env, out);
    if (comptime cel.is_mixed_map(T)) return write_mixed_map(value, env, out);
    switch (T) {
        bool => try out.print("{{\"boolValue\":{}}}", .{value}),
        i64 => try out.print("{{\"int64Value\":\"{d}\"}}", .{value}),
        u64 => try out.print("{{\"uint64Value\":\"{d}\"}}", .{value}),
        f64 => try out.print("{{\"doubleValue\":\"{e}\"}}", .{value}),
        []const u8 => {
            try out.writeAll("{\"stringValue\":");
            try std.json.Stringify.encodeJsonString(value, .{}, out);
            try out.writeAll("}");
        },
        cel.Bytes => try out.print("{{\"bytesHex\":\"{x}\"}}", .{value.octets}),
        cel.Null => try out.writeAll("{\"nullValue\":null}"),
        cel.TypeValue => try out.print("{{\"typeValue\":\"{s}\"}}", .{value.name}),
        proto.wkt.Timestamp => try out.print("{{\"timestamp\":[{d},{d}]}}", .{ value.seconds, value.nanos }),
        proto.wkt.Duration => try out.print("{{\"duration\":[{d},{d}]}}", .{ value.seconds, value.nanos }),
        else => try out.print("{{\"unwritten\":\"{s}\"}}", .{@typeName(T)}),
    }
}

fn write_list(list: anytype, env: *cel.Env, out: *std.Io.Writer) WriteError!void {
    try out.writeAll("{\"listValue\":{\"values\":[");
    var elements = cel.iterate(list);
    for (0..proto.constants.limits.elements_max) |index| {
        const element = try elements.next(env) orelse break;
        if (index != 0) try out.writeAll(",");
        try write_value(element, env, out);
    }
    try out.writeAll("]}}");
}

fn write_map(map: anytype, env: *cel.Env, out: *std.Io.Writer) WriteError!void {
    try out.writeAll("{\"mapValue\":{\"entries\":[");
    var keys = map.iterator();
    for (0..proto.constants.limits.elements_max) |index| {
        const key = try keys.next(env) orelse break;
        if (index != 0) try out.writeAll(",");
        try out.writeAll("{\"key\":");
        try write_value(key, env, out);
        try out.writeAll(",\"value\":");
        try write_value(try map.get(key, env) orelse return error.Unevaluable, env, out);
        try out.writeAll("}");
    }
    try out.writeAll("]}}");
}

fn write_mixed_list(list: anytype, env: *cel.Env, out: *std.Io.Writer) WriteError!void {
    try out.writeAll("{\"listValue\":{\"values\":[");
    inline for (list.items, 0..) |element, index| {
        if (index != 0) try out.writeAll(",");
        try write_value(element, env, out);
    }
    try out.writeAll("]}}");
}

fn write_mixed_map(map: anytype, env: *cel.Env, out: *std.Io.Writer) WriteError!void {
    try out.writeAll("{\"mapValue\":{\"entries\":[");
    inline for (map.keys, map.values, 0..) |key, value, index| {
        if (index != 0) try out.writeAll(",");
        try out.writeAll("{\"key\":");
        try write_value(key, env, out);
        try out.writeAll(",\"value\":");
        try write_value(value, env, out);
        try out.writeAll("}");
    }
    try out.writeAll("]}}");
}
