//! Tests of `Interceptor` over a stand-in for the `connect` module: what its `on_message`
//! answers for a message that passes, that breaks a rule, and that cannot be checked.
const std = @import("std");
const platform = @import("stdx").platform;
const assert = std.debug.assert;
const testing = std.testing;
const proto = @import("protobuf");
/// The tests decode and encode with the build target's CPU features.
const protobuf_decoder: proto.Decoder = .init(.target());
const pb = @import("buf_validate_validate");
const constants = @import("constants.zig");
const interceptor = @import("interceptor.zig");
const support = @import("rule_test_support.zig");
const walk_test = @import("validate_test.zig");
const pattern = @import("pattern.zig");

/// The names of `connect` the interceptor reads: an error, its code and its detail.
const stand_in = struct {
    pub const Code = enum { invalid_argument, resource_exhausted, internal };
    pub const Detail = struct { type_name: []const u8, value: []const u8 };
    pub const RpcError = struct { code: Code, message: []const u8 = "", details: []const Detail = &.{} };
};

/// A call's context, which gives the values the route table names.
fn Context(comptime Values: type) type {
    return struct {
        held: *Values,

        pub fn values(ctx: *const @This(), comptime T: type) *T {
            comptime assert(T == Values);
            return ctx.held;
        }
    };
}

/// The interceptor with `options`, the values of one call, and that call's outcome for a
/// message.
fn Fixture(comptime options: interceptor.InterceptorOptions) type {
    return struct {
        const Values = struct { protovalidate: interceptor.InterceptorRoom(stand_in, options) = .{} };
        const Checked = interceptor.Interceptor(stand_in, Values, options);

        values: Values = .{},

        fn check(fixture: *@This(), app: anytype, comptime T: type, message: *const T) ?stand_in.RpcError {
            const ctx: Context(Values) = .{ .held = &fixture.values };
            return Checked.on_message(app, &ctx, T, message);
        }
    };
}

const Plain = Fixture(.{});
/// An App with the CPU features every App holds, and no time.
const no_time = struct { cpu_features: platform.CpuFeatures = .target() };

/// The rule ids of the violations an error's detail holds, joined with spaces.
fn expect_detail(failure: stand_in.RpcError, expected: []const u8) !void {
    try testing.expectEqual(@as(usize, 1), failure.details.len);
    try testing.expectEqualStrings("buf.validate.Violations", failure.details[0].type_name);
    const decoded = try protobuf_decoder.decode(pb.Violations, failure.details[0].value);
    var buffer: [constants.refusal_message_len_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var each = decoded.violations.iterator();
    for (0..constants.compared_items_max) |index| {
        const violation = try each.next() orelse break;
        try writer.print("{s}{s}", .{ if (index == 0) "" else " ", violation.rule_id.? });
    }
    try testing.expectEqualStrings(expected, writer.buffered());
}

const NoRules = struct {
    text: []const u8 = "",
    pub const FieldNumber = enum(u29) { text = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "t.NoRules", .fields = &.{proto.field_of(FieldNumber.text, .string, .{})} };
};

const min_len = 3;
const Named = support.One([]const u8, .string, .{ .type = .{ .string = .{ .min_len = min_len } } });

test "a message with no rule, and one that keeps its rules, pass" {
    var fixture: Plain = .{};
    try testing.expectEqual(@as(?stand_in.RpcError, null), fixture.check(&no_time{}, NoRules, &.{ .text = "" }));
    try testing.expectEqual(@as(?stand_in.RpcError, null), fixture.check(&no_time{}, Named, &.{ .val = "long enough" }));
}

test "a message that breaks a rule is refused with invalid_argument, a text and its violations" {
    var fixture: Plain = .{};
    const failure = fixture.check(&no_time{}, Named, &.{ .val = "ab" }).?;
    try testing.expectEqual(stand_in.Code.invalid_argument, failure.code);
    try testing.expectEqualStrings("val: must be at least 3 characters", failure.message);
    try expect_detail(failure, "string.min_len");
    // The text and the detail lie in the call's values, which last until the reply is written.
    const room = &fixture.values.protovalidate;
    try testing.expectEqual(@intFromPtr(&room.message), @intFromPtr(failure.message.ptr));
    try testing.expectEqual(@intFromPtr(&room.detail), @intFromPtr(failure.details[0].value.ptr));
    try testing.expectEqual(@intFromPtr(&room.details), @intFromPtr(failure.details.ptr));
}

/// A message that breaks two rules of `Outer`: `id` is required, and `maybe` is under 10.
fn two_wrong() walk_test.Outer {
    var message = walk_test.valid();
    message.id = 0;
    message.maybe = walk_test.Outer.RuleNumber.maybe_lt;
    return message;
}

test "the error counts each violation, and its detail holds them all in order" {
    var fixture: Plain = .{};
    const failure = fixture.check(&no_time{}, walk_test.Outer, &two_wrong()).?;
    try testing.expectEqualStrings("id: value is required (and 1 more)", failure.message);
    try expect_detail(failure, "required int32.lt");
}

test "a detail longer than its room holds the first violations that fit, or the error has none" {
    const message = two_wrong();
    // The two violations encode in more octets than this room, and the first one in fewer.
    const one_violation_bytes = 100;
    var plain: Plain = .{};
    const whole = plain.check(&no_time{}, walk_test.Outer, &message).?;
    try testing.expect(whole.details[0].value.len > one_violation_bytes);
    var cut: Fixture(.{ .detail_bytes = one_violation_bytes }) = .{};
    const kept = cut.check(&no_time{}, walk_test.Outer, &message).?;
    try testing.expectEqualStrings("id: value is required (and 1 more)", kept.message);
    try expect_detail(kept, "required");
    var none: Fixture(.{ .detail_bytes = 1 }) = .{};
    const bare = none.check(&no_time{}, walk_test.Outer, &message).?;
    try testing.expectEqual(stand_in.Code.invalid_argument, bare.code);
    try testing.expectEqual(@as(usize, 0), bare.details.len);
}

test "a report with no room for a violation still refuses the message" {
    var fixture: Fixture(.{ .report_bytes = 0 }) = .{};
    const failure = fixture.check(&no_time{}, Named, &.{ .val = "ab" }).?;
    try testing.expectEqual(stand_in.Code.invalid_argument, failure.code);
    try testing.expectEqualStrings("the message breaks a rule of its schema", failure.message);
    try testing.expectEqual(@as(usize, 0), failure.details.len);
}

const Timed = support.One(?proto.wkt.Timestamp, .message, .{ .type = .{ .timestamp = .{ .less_than = .{ .lt_now = true } } } });

test "a rule that reads the time takes it from the App, and fails closed without it" {
    const second = 1;
    var fixture: Plain = .{};
    const message: Timed = .{ .val = .{ .seconds = second } };
    const failure = fixture.check(&no_time{}, Timed, &message).?;
    try testing.expectEqual(stand_in.Code.internal, failure.code);
    try testing.expectEqual(@as(usize, 0), failure.details.len);
    // The App's time decides: a timestamp at it passes, and one after it does not
    // (validate.proto, timestamp.lt_now: "this > now").
    const Clock = struct { cpu_features: platform.CpuFeatures = .target(), protovalidate_now: proto.wkt.Timestamp };
    try testing.expectEqual(@as(?stand_in.RpcError, null), fixture.check(&Clock{ .protovalidate_now = .{ .seconds = second } }, Timed, &message));
    const late = fixture.check(&Clock{ .protovalidate_now = .{ .seconds = second - 1 } }, Timed, &message).?;
    try testing.expectEqual(stand_in.Code.invalid_argument, late.code);
    try expect_detail(late, "timestamp.lt_now");
}

const Unique = support.One(proto.Repeated(i32, .int32), .int32, .{ .type = .{ .repeated = .of(&.{ .unique = true }) } });

test "a list too long to compare is refused with resource_exhausted" {
    var fixture: Plain = .{};
    var items: [constants.compared_items_max + 1]i32 = undefined;
    for (&items, 0..) |*item, index| item.* = @intCast(index);
    const failure = fixture.check(&no_time{}, Unique, &.{ .val = .of(&items) }).?;
    try testing.expectEqual(stand_in.Code.resource_exhausted, failure.code);
    // A list of the most items the module compares passes.
    try testing.expectEqual(@as(?stand_in.RpcError, null), fixture.check(&no_time{}, Unique, &.{ .val = .of(items[0..constants.compared_items_max]) }));
}

const capitalized = "^[A-Z][a-z]+$";
const Capitalized = support.One([]const u8, .string, .{ .type = .{ .string = .{ .pattern = capitalized } } });

test "a rule's regular expression searches with the App's CPU features" {
    var fixture: Plain = .{};
    const sets = [_]platform.CpuFeatures{ platform.CpuFeatures.none(), platform.CpuFeatures.target(), platform.CpuFeatures.detect() };
    for (sets) |set| {
        const app: no_time = .{ .cpu_features = set };
        try testing.expectEqual(@as(?stand_in.RpcError, null), fixture.check(&app, Capitalized, &.{ .val = "Ada" }));
        try testing.expect(std.meta.eql(pattern.kept_cpu_features(capitalized), @as(?platform.CpuFeatures, set)));
        try testing.expectEqual(stand_in.Code.invalid_argument, fixture.check(&app, Capitalized, &.{ .val = "ada" }).?.code);
    }
}

test "the program's App needs its CPU features, of the module's type" {
    try testing.expect(interceptor.app_error(no_time) == null);
    try testing.expect(interceptor.app_error(struct {}) != null);
    try testing.expect(interceptor.app_error(struct { cpu_features: u8 = 0 }) != null);
}

test "the route table's values need the interceptor's room, of the interceptor's options" {
    const Room = interceptor.InterceptorRoom(stand_in, .{});
    try testing.expect(interceptor.values_error(struct { protovalidate: Room = .{} }, Room) == null);
    try testing.expect(interceptor.values_error(struct {}, Room) != null);
    // A room of other sizes is another type.
    const Other = interceptor.InterceptorRoom(stand_in, .{ .detail_bytes = 1 });
    try testing.expect(interceptor.values_error(struct { protovalidate: Other = .{} }, Room) != null);
}
