//! The types of CEL values as the compiled code holds them (CEL language definition, "Values").
//! Each CEL type is one Zig type, so the type of a part of an expression is the type of the
//! Zig value it unfolds into:
//!
//! - int, uint, double and bool are `i64`, `u64`, `f64` and `bool`; an enum's value is an int;
//! - string is `[]const u8`, and bytes is `Bytes`, which keeps the two apart;
//! - null is `Null`, and a wrapper field that may be unset is an optional of its scalar;
//! - google.protobuf.Timestamp and Duration are their generated types, by value;
//! - any other message is a pointer to it, or the message itself where the pointer would not
//!   last: an element that an index takes out of a list or a map;
//! - a list and a map are views of a repeated field (`cel_list.zig`).
const std = @import("std");
const codec = @import("codec");
const proto = @import("protobuf");
const shape = @import("../shape.zig");
const constants = @import("../constants.zig");

pub const Bytes = struct { octets: []const u8 };
pub const Null = struct {};
/// The type of a part that fails each time it runs. Under `dyn`, a field that is not there
/// and an operator with no overload for its operands are errors of the run, not of the build
/// (CEL language definition, "Gradual Type Checking").
pub const Failing = struct {};
/// The element type of `[]`, which no element fixes, and so no value has. The checker reads
/// it as `dyn`: "The type `dyn` is used for heterogeneous values" (CEL language definition,
/// "Aggregate Values"), and cel-go gives `[]` the type `list(dyn)`.
pub const NoElement = struct {
    pub const cel_name = "dyn";
};

pub const Error = error{
    /// The expression failed as it ran: a division by zero, an overflow, a conversion of a
    /// value its target type does not hold, or a part that `dyn` let through.
    Unevaluable,
    /// The expression reads `now`, and the caller passed no time.
    TimeMissing,
    /// `format` found no room for its text in the report's storage.
    ReportFull,
    /// A repeated field's octets do not decode: `decode` never read the message.
    Malformed,
    /// The expression read more elements of lists and maps than `constants.cel_steps_max`.
    TooManyItems,
};

/// What an expression reads beside its variables, and how many elements of lists and maps it
/// may still read. A macro inside a macro reads a list once for each element of another, so
/// the count bounds an expression's work whatever a message holds.
pub const Env = struct {
    /// The CPU features `matches` searches with: the walk's `Options.cpu_features`, which an
    /// expression reads through a pointer, so a rule copies none of them.
    cpu_features: *const codec.Features,
    now: ?proto.wkt.Timestamp = null,
    steps: usize = constants.cel_steps_max,
    /// Where `format` writes its text, which only a rule whose expression formats is given
    /// (`cel_rule.zig`). One pointer, so a rule that does not format sets up one word more.
    text: ?*Text = null,

    /// Counts one element read.
    pub fn spend(env: *Env) Error!void {
        if (env.steps == 0) return error.TooManyItems;
        env.steps -= 1;
    }
};

/// The room `format` writes its text into: the free part of the report's storage.
pub const Text = struct {
    room: []u8,
    /// The octets of `room` written so far.
    len: usize = 0,
    /// The report's mark of a full storage, which a text with no room sets, as a violation
    /// with no room does.
    full: ?*bool = null,

    /// Writes `octets` after the text written before.
    pub fn write(text: *Text, octets: []const u8) Error!void {
        if (text.room.len - text.len < octets.len) return text.overflow();
        @memcpy(text.room[text.len..][0..octets.len], octets);
        text.len += octets.len;
    }

    /// The room after the text written before, for a writer that fills part of it.
    pub fn unwritten(text: *const Text) []u8 {
        return text.room[text.len..];
    }

    /// Marks the report full and fails: the text has no room.
    pub fn overflow(text: *Text) Error {
        if (text.full) |full| full.* = true;
        return error.ReportFull;
    }
};

/// The names an expression may read and the type of each one's value. `this` is the first.
pub const Scope = struct {
    names: []const []const u8 = &.{"this"},
    types: []const type,
    /// For each name up to its length, whether the checker reads it as behind `dyn`.
    dynamic: []const bool = &.{},

    pub fn index_of(comptime scope: Scope, comptime name: []const u8) ?usize {
        // A macro's variable hides a name before it, so the last one wins.
        for (0..scope.names.len) |back| {
            const index = scope.names.len - 1 - back;
            // The lengths first: a comparison of two texts costs the compiler a call.
            if (scope.names[index].len == name.len and std.mem.eql(u8, scope.names[index], name)) return index;
        }
        return null;
    }

    pub fn with(comptime scope: Scope, comptime name: []const u8, comptime T: type) Scope {
        return .{ .names = scope.names ++ [_][]const u8{name}, .types = scope.types ++ [_]type{T}, .dynamic = scope.dynamic };
    }

    /// `with` of a name the checker reads as behind `dyn`: a macro's variable over a list or a
    /// map whose elements are of two types or more (`cel_mixed.zig`), as cel-go types an
    /// element of a `list(dyn)` (CEL language definition, "Gradual Type Checking").
    pub fn with_dynamic(comptime scope: Scope, comptime name: []const u8, comptime T: type) Scope {
        const earlier = [_]bool{false} ** (scope.names.len - scope.dynamic.len);
        return .{ .names = scope.names ++ [_][]const u8{name}, .types = scope.types ++ [_]type{T}, .dynamic = scope.dynamic ++ earlier ++ [_]bool{true} };
    }

    /// Whether the name at `index` is read as behind `dyn`.
    pub fn is_dynamic(comptime scope: Scope, comptime index: usize) bool {
        return index < scope.dynamic.len and scope.dynamic[index];
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

/// The message type of a message value: a pointer to it, or the message itself. Null for any
/// other type, and for a timestamp and a duration, which are values of their own.
pub fn MessageOf(comptime T: type) ?type {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .one) return null;
            return if (is_generated(pointer.child)) pointer.child else null;
        },
        else => return if (is_generated(T) and T != proto.wkt.Timestamp and T != proto.wkt.Duration) T else null,
    }
}

fn is_generated(comptime M: type) bool {
    return @typeInfo(M) == .@"struct" and @hasDecl(M, "protobuf") and @TypeOf(M.protobuf) == proto.Descriptor;
}

pub fn is_message(comptime T: type) bool {
    return MessageOf(T) != null;
}

pub fn is_number(comptime T: type) bool {
    return T == i64 or T == u64 or T == f64;
}

/// The type's name as CEL's messages state it.
pub fn name_of(comptime T: type) []const u8 {
    if (comptime MessageOf(T)) |M| return M.protobuf.full_name;
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "cel_name")) return T.cel_name;
    if (comptime @typeInfo(T) == .array) return "list(" ++ comptime name_of(@typeInfo(T).array.child) ++ ")";
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
    if (comptime @typeInfo(T) == .pointer and is_message(T)) {
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
    try testing.expect(Of(.uint32, u32) == u64 and Of(.fixed64, u64) == u64 and Of(.fixed32, u32) == u64 and Of(.uint64, u64) == u64);
    try testing.expect(Of(.sint32, i32) == i64 and Of(.sint64, i64) == i64 and Of(.sfixed32, i32) == i64 and Of(.int64, i64) == i64);
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
    try testing.expectEqual(false, default_of(bool));
    try testing.expectEqualStrings("", default_of([]const u8));
    try testing.expectEqualStrings("", default_of(Bytes).octets);
    try testing.expectEqual(@as(i32, 0), default_of(*const Inner).count);
    try testing.expectEqual(@as(i64, 0), default_of(proto.wkt.Duration).seconds);
    try testing.expectEqualStrings("int", name_of(i64));
    try testing.expectEqualStrings("t.Inner", name_of(*const Inner));
    try testing.expectEqualStrings("wrapper(string)", name_of(?[]const u8));
    try testing.expectEqualStrings("google.protobuf.Timestamp", name_of(proto.wkt.Timestamp));
    try testing.expect(is_message(*const Inner) and is_message(Inner) and !is_message(i64) and !is_message([]const u8));
    try testing.expect(!is_message(proto.wkt.Timestamp) and !is_message(proto.wkt.Duration) and !is_message(Bytes) and !is_message(Null));
    try testing.expectEqualStrings("t.Inner", name_of(Inner));
    try testing.expectEqualStrings("list(int)", name_of([2]i64));
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
