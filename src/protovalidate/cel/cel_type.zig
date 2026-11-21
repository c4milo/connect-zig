//! The types of CEL values as the compiled code holds them (CEL language definition, "Values").
//! Each CEL type is one Zig type, so the type of a part of an expression is the type of the
//! Zig value it unfolds into:
//!
//! - int, uint, double and bool are `i64`, `u64`, `f64` and `bool`; an enum's value is an int;
//! - string is `[]const u8`, and bytes is `Bytes`, which keeps the two apart;
//! - null is `Null`, and a wrapper field that may be unset is an optional of its scalar;
//! - google.protobuf.Timestamp and Duration are their generated types, by value;
//! - any other message is a pointer to it.
const std = @import("std");
const proto = @import("protobuf");
const shape = @import("../shape.zig");

pub const Bytes = struct { octets: []const u8 };
pub const Null = struct {};
/// The type of a part that fails each time it runs. Under `dyn`, a field that is not there
/// and an operator with no overload for its operands are errors of the run, not of the build
/// (CEL language definition, "Gradual Type Checking").
pub const Failing = struct {};

pub const Error = error{
    /// The expression failed as it ran: a division by zero, an overflow, a conversion of a
    /// value its target type does not hold, or a part that `dyn` let through.
    Unevaluable,
    /// The expression reads `now`, and the caller passed no time.
    TimeMissing,
};

/// What an expression reads beside its variables.
pub const Env = struct {
    now: ?proto.wkt.Timestamp = null,
};

/// The names an expression may read and the type of each one's value. `this` is the first.
pub const Scope = struct {
    names: []const []const u8 = &.{"this"},
    types: []const type,

    pub fn index_of(comptime scope: Scope, comptime name: []const u8) ?usize {
        // A macro's variable hides a name before it, so the last one wins.
        for (0..scope.names.len) |back| {
            const index = scope.names.len - 1 - back;
            if (std.mem.eql(u8, scope.names[index], name)) return index;
        }
        return null;
    }

    pub fn with(comptime scope: Scope, comptime name: []const u8, comptime T: type) Scope {
        return .{ .names = scope.names ++ [_][]const u8{name}, .types = scope.types ++ [_]type{T} };
    }
};

/// The type of a part of an expression, or why it has none.
pub const Typed = union(enum) {
    ok: Ok,
    problem: []const u8,

    pub const Ok = struct {
        type: type,
        /// Whether the part came through `dyn`: a mistake of types in it fails the run.
        dynamic: bool = false,
    };

    pub fn of(comptime T: type) Typed {
        return .{ .ok = .{ .type = T } };
    }
};

pub fn is_message(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .one) return false;
            return @typeInfo(pointer.child) == .@"struct" and @hasDecl(pointer.child, "protobuf");
        },
        else => return false,
    }
}

pub fn is_number(comptime T: type) bool {
    return T == i64 or T == u64 or T == f64;
}

/// The type's name as CEL's messages state it.
pub fn name_of(comptime T: type) []const u8 {
    if (comptime is_message(T)) return @typeInfo(T).pointer.child.protobuf.full_name;
    if (comptime @typeInfo(T) == .optional) return "wrapper(" ++ comptime name_of(@typeInfo(T).optional.child) ++ ")";
    return switch (T) {
        i64 => "int",
        u64 => "uint",
        f64 => "double",
        bool => "bool",
        []const u8 => "string",
        Bytes => "bytes",
        Null => "null",
        Failing => "error",
        proto.wkt.Timestamp => "google.protobuf.Timestamp",
        proto.wkt.Duration => "google.protobuf.Duration",
        else => @typeName(T),
    };
}

/// The CEL type of a value of `kind` that the generated code holds as a `V`.
pub fn Of(comptime kind: proto.Kind, comptime V: type) type {
    return switch (kind) {
        .double, .float => f64,
        .int32, .int64, .sint32, .sint64, .sfixed32, .sfixed64, .@"enum" => i64,
        .uint32, .uint64, .fixed32, .fixed64 => u64,
        .bool => bool,
        .string, .unvalidated_string => []const u8,
        .bytes => Bytes,
        .message, .group => OfMessage(V),
    };
}

fn OfMessage(comptime M: type) type {
    // A wrapper reads as the scalar it holds (CEL language definition, "Protocol Buffer Data
    // Conversion").
    if (shape.wrapper_kind(M)) |kind| return Of(kind, @FieldType(M, "value"));
    if (M == proto.wkt.Timestamp or M == proto.wkt.Duration) return M;
    return *const M;
}

/// The CEL value of `value`, a field's value of `kind`.
pub fn from(comptime kind: proto.Kind, comptime V: type, value: *const V) Of(kind, V) {
    return switch (kind) {
        .bytes => .{ .octets = value.* },
        .@"enum" => @intFromEnum(value.*),
        .message, .group => from_message(V, value),
        else => value.*,
    };
}

fn from_message(comptime M: type, value: *const M) OfMessage(M) {
    if (comptime shape.wrapper_kind(M)) |kind| return from(kind, @FieldType(M, "value"), &value.value);
    if (comptime M == proto.wkt.Timestamp or M == proto.wkt.Duration) return value.*;
    return value;
}

/// The value of a field that is not set: its type's default (CEL language definition, "Field
/// Selection").
pub fn default_of(comptime T: type) T {
    if (comptime is_message(T)) {
        const M = @typeInfo(T).pointer.child;
        const Default = struct {
            const instance: M = .{};
        };
        return &Default.instance;
    }
    return switch (T) {
        i64, u64, f64 => 0,
        bool => false,
        []const u8 => "",
        Bytes => .{ .octets = "" },
        else => .{},
    };
}

const testing = std.testing;

const Color = enum(i32) { unspecified = 0, red = 1, _ };
const Inner = struct {
    count: i32 = 0,
    pub const FieldNumber = enum(u29) { count = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.Inner", .fields = &.{proto.field_of(FieldNumber.count, .int32, .{})} };
};

test "each kind's value reads as its CEL type" {
    try testing.expect(Of(.int32, i32) == i64 and Of(.sfixed64, i64) == i64 and Of(.@"enum", Color) == i64);
    try testing.expect(Of(.uint32, u32) == u64 and Of(.fixed64, u64) == u64);
    try testing.expect(Of(.float, f32) == f64 and Of(.double, f64) == f64 and Of(.bool, bool) == bool);
    try testing.expect(Of(.string, []const u8) == []const u8 and Of(.bytes, []const u8) == Bytes);
    try testing.expect(Of(.message, Inner) == *const Inner);
    try testing.expect(Of(.message, proto.wkt.Timestamp) == proto.wkt.Timestamp);
    try testing.expect(Of(.message, proto.wkt.Int32Value) == i64 and Of(.message, proto.wkt.BytesValue) == Bytes);
    const minus_three: i32 = -3;
    try testing.expectEqual(@as(i64, minus_three), from(.sint32, i32, &minus_three));
    try testing.expectEqual(@as(i64, 1), from(.@"enum", Color, &.red));
    try testing.expectEqual(@as(f64, 0.5), from(.float, f32, &0.5));
    try testing.expectEqualStrings("ab", from(.bytes, []const u8, &"ab").octets);
    try testing.expectEqual(@as(u64, 1), from(.message, proto.wkt.UInt32Value, &.{ .value = 1 }));
    const inner: Inner = .{ .count = 1 };
    try testing.expectEqual(&inner, from(.message, Inner, &inner));
}

test "an unset field reads as its type's default, and a type has CEL's name" {
    try testing.expectEqual(@as(i64, 0), default_of(i64));
    try testing.expectEqualStrings("", default_of([]const u8));
    try testing.expectEqualStrings("", default_of(Bytes).octets);
    try testing.expectEqual(@as(i32, 0), default_of(*const Inner).count);
    try testing.expectEqual(@as(i64, 0), default_of(proto.wkt.Duration).seconds);
    try testing.expectEqualStrings("int", name_of(i64));
    try testing.expectEqualStrings("t.Inner", name_of(*const Inner));
    try testing.expectEqualStrings("wrapper(string)", name_of(?[]const u8));
    try testing.expectEqualStrings("google.protobuf.Timestamp", name_of(proto.wkt.Timestamp));
    try testing.expect(is_message(*const Inner) and !is_message(i64) and !is_message([]const u8));
    try testing.expect(is_number(u64) and !is_number(bool));
}

test "a macro's variable hides a name before it" {
    const scope: Scope = .{ .types = &.{i64} };
    try testing.expectEqual(@as(?usize, 0), comptime scope.index_of("this"));
    try testing.expectEqual(@as(?usize, null), comptime scope.index_of("k"));
    const inner = comptime scope.with("k", bool).with("this", u64);
    const last = 2;
    try testing.expectEqual(@as(?usize, 1), comptime inner.index_of("k"));
    try testing.expectEqual(@as(?usize, last), comptime inner.index_of("this"));
}
