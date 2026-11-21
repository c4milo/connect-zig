//! `Interceptor`: the check of each request message of a call, as a server's interceptor
//! (decision 47, design §8 step 33). A route calls its `on_message` with each request message
//! once it is decoded, before the handler takes it.
//!
//! The module imports no `connect` module, so the interceptor takes it as a parameter, as a
//! generated `Routes` takes its transport (decision 2). It reads the call through what the hook
//! receives: a context with `values`, as `connect_colibri`'s has.
//!
//! ```zig
//! const validation: protovalidate.InterceptorOptions = .{};
//! const Values = struct { protovalidate: protovalidate.InterceptorRoom(connect, validation) = .{} };
//! const Validate = protovalidate.Interceptor(connect, Values, validation);
//! // In the route options: .interceptors = &.{Validate}; in the route table: .Values = Values.
//! ```
const std = @import("std");
const assert = std.debug.assert;
const proto = @import("protobuf");
const pb = @import("buf_validate_validate");
const constants = @import("constants.zig");
const report_file = @import("report.zig");
const table = @import("table.zig");
const validate_file = @import("validate.zig");
const refusal_text = @import("refusal_text.zig");
const Report = report_file.Report;
const Violation = report_file.Violation;

pub const InterceptorOptions = struct {
    /// The octets of the report of one message's violations. The default holds about 16.
    report_bytes: usize = constants.report_bytes_default,
    /// The octets of the `buf.validate.Violations` an error carries as its detail. A longer one
    /// is cut to the first violations that fit.
    detail_bytes: usize = constants.detail_bytes_default,
};

/// What the error of a refused message points to, which must last until the reply is written:
/// the route table's `.Values` holds one for each call, in a field `protovalidate` (decision
/// 35). Each field starts undefined, so a call that refuses no message writes none of them.
pub fn InterceptorRoom(comptime connect: type, comptime options: InterceptorOptions) type {
    return struct {
        report: [options.report_bytes]u8 align(report_file.storage_alignment) = undefined,
        detail: [options.detail_bytes]u8 = undefined,
        message: [constants.refusal_message_len_max]u8 = undefined,
        details: [1]connect.Detail = undefined,
    };
}

/// The interceptor that validates each request message of the routes that list it, for the
/// `connect` module the program builds with.
///
/// - A message that breaks a rule ends its call with `invalid_argument`. The error's message
///   names the first violation's field and what it broke, and its one detail is a
///   `buf.validate.Violations` with each violation the report and the detail had room for.
/// - A rule that reads the time takes it from the program's `App`, in a field
///   `protovalidate_now: proto.wkt.Timestamp` that the program writes from its clock (decision
///   3). With no such field the call ends with `internal`.
/// - A message the module cannot check whole ends its call too: `resource_exhausted` for a
///   `unique` list or a map longer than `constants.compared_items_max`.
/// - A message type with no rule costs its call no instruction.
///
/// `on_message` takes any context with `values`, as `connect_colibri`'s has it.
pub fn Interceptor(comptime connect: type, comptime Values: type, comptime options: InterceptorOptions) type {
    const Room = InterceptorRoom(connect, options);
    comptime if (values_error(Values, Room)) |problem| @compileError(problem);
    return struct {
        pub fn on_message(app: anytype, ctx: anytype, comptime T: type, message: *const T) ?connect.RpcError {
            if (comptime !table.has_rules(T)) return null;
            const room: *Room = &ctx.values(Values).protovalidate;
            var report: Report = .init(&room.report);
            validate_file.validate(T, message, .{ .now = now_of(app) }, &report) catch |failure| return switch (failure) {
                error.Invalid => invalid(connect, room, report.violations()),
                // A rule that cannot be checked fails closed: the handler does not take the
                // message (decision 47).
                error.TimeMissing => .{ .code = .internal, .message = "the server gives its validation no time" },
                error.TooManyItems => .{ .code = .resource_exhausted, .message = "a list or a map is too long to validate" },
                error.TooDeep => .{ .code = .invalid_argument, .message = "the message nests too deep to validate" },
                error.Malformed => .{ .code = .invalid_argument, .message = "malformed message" },
                error.Unevaluable => .{ .code = .internal, .message = "a rule of the message's schema failed as it ran" },
            };
            return null;
        }
    };
}

/// What is wrong with the route table's `.Values` for an interceptor whose room is `Room`, or
/// null.
pub fn values_error(comptime Values: type, comptime Room: type) ?[]const u8 {
    if (@hasField(Values, "protovalidate") and @FieldType(Values, "protovalidate") == Room) return null;
    return "protovalidate.Interceptor: the route table's .Values needs a field `protovalidate: protovalidate.InterceptorRoom(connect, options) = .{}`, with the interceptor's own options";
}

/// The time the program's `App` holds for the rules that read it, or none.
fn now_of(app: anytype) ?proto.wkt.Timestamp {
    if (comptime !@hasField(@TypeOf(app.*), "protovalidate_now")) return null;
    return app.protovalidate_now;
}

/// The error of a message that broke a rule, whose message and detail lie in `room`.
fn invalid(comptime connect: type, room: anytype, violations: []const Violation) connect.RpcError {
    const message = refusal_text.describe(violations, &room.message);
    const encoded = encode_fitting(violations, &room.detail);
    // An empty detail states no violation, so the error carries none.
    if (encoded.len == 0) return .{ .code = .invalid_argument, .message = message };
    room.details[0] = .{ .type_name = pb.Violations.protobuf.full_name, .value = encoded };
    return .{ .code = .invalid_argument, .message = message, .details = &room.details };
}

/// Encodes the most violations, from the first, that `buffer` holds, as a
/// `buf.validate.Violations`.
fn encode_fitting(violations: []const Violation, buffer: []u8) []const u8 {
    for (0..violations.len) |dropped| {
        const kept: pb.Violations = .{ .violations = .of(violations[0 .. violations.len - dropped]) };
        return proto.encode(pb.Violations, &kept, buffer) catch continue;
    }
    return buffer[0..0];
}
