//! The calculator service, errors.v1.CalculatorService: Divide, which fails with a typed
//! detail, and the interceptor around it. A program's `App` holds the service's `Room` in its
//! field `calculator`, so one route table may serve it beside other services (decision 41).
//!
//! - Divide fails with invalid_argument and a DivisionByZero detail when the divisor is 0.
//! - `Counting` reports how many messages a call read and wrote, in trailers. A gRPC error before
//!   any message is Trailers-Only, so its head carries these trailers too.
const std = @import("std");
const connect = @import("connect_zig").connect;
const proto = @import("connect_zig").protobuf;
const rpc = @import("connect_zig").connect_colibri;
const errors = @import("errors");
const constants = @import("constants.zig");

/// The service's part of a program's `App`. An error and a trailer go out before their handler
/// returns, so one room serves every call, even while several calls run at once.
pub const Room = struct {
    /// A Divide error's detail: the octets of its message, and the list that names it.
    detail_bytes: [constants.text_len_max]u8 = undefined,
    details: [1]connect.Detail = undefined,
    /// The digits of the counts `Counting` reports.
    received_digits: [constants.count_len_max]u8 = undefined,
    sent_digits: [constants.count_len_max]u8 = undefined,
};

/// The route options of Divide before its interceptor: room for a message and a JSON token of
/// `text_len_max` octets.
pub const route_options: rpc.RouteOptions = .{ .message_bytes = constants.text_len_max, .token_bytes = constants.text_len_max };

/// The trailers `Counting` adds: the messages a call read and wrote.
pub const received_trailer = "call-received";
pub const sent_trailer = "call-sent";

/// The service's handler and interceptor over `App`, and their entries in a route table:
/// `Service(App).routes`. Each passes the call to the function below, with the service's room.
pub fn Service(comptime App: type) type {
    return struct {
        /// Divide runs behind `Counting`.
        pub const routes = errors.CalculatorService.Routes(rpc, App, @This(), counted).routes;
        const counted = with_interceptors(&.{Counting});

        /// Adds trailers that count the messages a call read and wrote, once it ends.
        pub const Counting = struct {
            pub fn on_finish(app: *App, ctx: *rpc.Context, response: *rpc.AnyResponse, failure: ?connect.RpcError) ?connect.RpcError {
                return count_finish(&app.calculator, ctx, response, failure);
            }
        };

        pub fn divide(app: *App, _: *rpc.Context, request: *const rpc.Request(errors.DivideRequest), response: *rpc.Response(errors.DivideResponse)) ?connect.RpcError {
            return divide_in(&app.calculator, request, response);
        }
    };
}

fn with_interceptors(comptime interceptors: []const type) rpc.RouteOptions {
    var options = route_options;
    options.interceptors = interceptors;
    return options;
}

/// Writes the counts of messages the call read and wrote as trailers. The trailers go out as
/// soon as `on_finish` returns, so one room serves every call.
fn count_finish(room: *Room, ctx: *rpc.Context, response: *rpc.AnyResponse, failure: ?connect.RpcError) ?connect.RpcError {
    // A u32 has at most `count_len_max` digits, so each count fits.
    const received = std.fmt.bufPrint(&room.received_digits, "{d}", .{ctx.received()}) catch unreachable;
    const sent = std.fmt.bufPrint(&room.sent_digits, "{d}", .{ctx.sent()}) catch unreachable;
    response.add_trailer(received_trailer, received) catch {};
    response.add_trailer(sent_trailer, sent) catch {};
    return failure;
}

/// Divide fails with a DivisionByZero detail when the divisor is 0.
fn divide_in(room: *Room, request: *const rpc.Request(errors.DivideRequest), response: *rpc.Response(errors.DivideResponse)) ?connect.RpcError {
    const operands = &request.message;
    if (operands.divisor == 0) {
        const detail: errors.DivisionByZero = .{ .dividend = operands.dividend };
        const bytes = proto.encode(errors.DivisionByZero, &detail, &room.detail_bytes) catch return .{ .code = .internal };
        room.details[0] = .{ .type_name = errors.DivisionByZero.protobuf.full_name, .value = bytes };
        return .{ .code = .invalid_argument, .message = "division by zero", .details = &room.details };
    }
    // The divisor is not 0, so only the one overflow remains: the least i64 divided by -1.
    if (operands.dividend == std.math.minInt(i64) and operands.divisor == -1) return .{ .code = .out_of_range, .message = "quotient overflows" };
    response.message = .{ .quotient = @divTrunc(operands.dividend, operands.divisor), .remainder = @rem(operands.dividend, operands.divisor) };
    return null;
}
