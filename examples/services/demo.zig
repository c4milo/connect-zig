//! The demo service: a handler for each method of demo.v1.DemoService, the interceptors around
//! them, and its entries in the route table of `routes.zig`.
//!
//! - Whoami runs behind two interceptors. `Logging` counts every call and marks its reply with a
//!   header; `Auth` refuses a call without a bearer token, before the handler runs.
//! - Chat and Sum are type handlers: they take each message as it arrives. Chat answers each one
//!   at once, so over h2 a client reads answers while it still sends. `Counting` reports how
//!   many messages a Chat read and wrote, in trailers.
//! - Countdown is a server stream, and Divide fails with a typed detail.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
const adapter = @import("connect_colibri");
const demo = @import("demo");
const app_file = @import("app.zig");
const App = app_file.App;
const text_of = app_file.text_of;
const Service = demo.DemoService;

/// The prefix of the authorization header `Auth` reads (RFC 6750 §2.1).
pub const bearer_prefix = "Bearer ";
/// The response header `Logging` adds to each reply, and its value.
pub const logged_header = "demo-logged";
pub const logged_value = "yes";
/// The largest `from` Countdown counts down from.
pub const countdown_max = 64;
/// The trailer Chat adds once the client ends its stream: whether it answered any message.
pub const turns_trailer = "chat-turns";
/// The trailers `Counting` adds: the messages a call read and wrote.
pub const received_trailer = "call-received";
pub const sent_trailer = "call-sent";
/// The trailer Whoami adds: the caller's name. A Connect unary reply sends it as the header
/// "trailer-whoami-caller".
pub const caller_trailer = "whoami-caller";

/// Counts each call and marks its reply. It wraps `Auth`, so it also sees the calls `Auth`
/// refuses, and counts them as failed.
pub const Logging = struct {
    pub fn on_call(app: *App, call: *adapter.Call) ?connect.RpcError {
        app.logged += 1;
        call.set_header(logged_header, logged_value) catch return .{ .code = .internal, .message = "no room for a header" };
        return null;
    }

    pub fn on_finish(app: *App, _: *adapter.Call, failure: ?connect.RpcError) ?connect.RpcError {
        if (failure != null) app.failed += 1;
        return failure;
    }
};

/// Refuses a call whose request has no "authorization: Bearer <name>" header.
pub const Auth = struct {
    pub fn on_call(_: *App, call: *adapter.Call) ?connect.RpcError {
        _ = caller_of(call) orelse return .{ .code = .unauthenticated, .message = "a bearer token is required" };
        return null;
    }
};

/// The name a request's bearer token carries, or null.
pub fn caller_of(call: *const adapter.Call) ?[]const u8 {
    const value = call.request_header("authorization") orelse return null;
    if (!std.mem.startsWith(u8, value, bearer_prefix)) return null;
    const name = value[bearer_prefix.len..];
    if (name.len == 0) return null;
    return name;
}

/// Adds trailers that count the messages a call read and wrote, once it ends. The trailers go
/// out as soon as `on_finish` returns, so one room in `app` serves every call.
pub const Counting = struct {
    pub fn on_finish(app: *App, call: *adapter.Call, failure: ?connect.RpcError) ?connect.RpcError {
        const received = std.fmt.bufPrint(app.counts[0..count_len_max], "{d}", .{call.received}) catch unreachable;
        const sent = std.fmt.bufPrint(app.counts[count_len_max..], "{d}", .{call.sent}) catch unreachable;
        call.add_trailer(received_trailer, received) catch {};
        call.add_trailer(sent_trailer, sent) catch {};
        return failure;
    }
};

/// The digits of a u32, at most.
const count_len_max = 10;

/// Whoami answers with the caller's name, which `Auth` already checked.
fn whoami(app: *App, call: *adapter.Call, _: *const demo.WhoamiRequest, response: *demo.WhoamiResponse) ?connect.RpcError {
    response.name = caller_of(call).?;
    call.add_trailer(caller_trailer, response.name) catch {};
    // `Logging` counted this call before the handler ran.
    response.calls_before = app.logged - 1;
    return null;
}

/// Chat answers each message the moment it arrives, and says goodbye when the client ends.
const Chat = struct {
    pub const State = struct { turns: u32 = 0 };

    pub fn on_message(app: *App, _: *adapter.Call, state: *State, request: *const demo.ChatMessage, sender: *adapter.Sender(demo.ChatMessage)) ?connect.RpcError {
        // An error from `on_message` ends the call at once, after the answers already sent.
        if (request.text.len == 0) return .{ .code = .invalid_argument, .message = "empty message" };
        state.turns += 1;
        // `send` writes the message out before it returns, so `app.text` is free again after.
        sender.send(&.{ .text = text_of(app, "echo: {s}", .{request.text}) }) catch return .{ .code = .resource_exhausted };
        return null;
    }

    pub fn on_end(app: *App, call: *adapter.Call, state: *State, sender: *adapter.Sender(demo.ChatMessage)) ?connect.RpcError {
        sender.send(&.{ .text = text_of(app, "bye after {d}", .{state.turns}) }) catch return .{ .code = .resource_exhausted };
        call.add_trailer(turns_trailer, if (state.turns == 0) "none" else "some") catch {};
        return null;
    }
};

/// Sum adds the numbers as they arrive, and answers once the client ends its stream.
const Sum = struct {
    pub const State = struct { sum: i64 = 0, count: i64 = 0 };

    pub fn on_message(_: *App, _: *adapter.Call, state: *State, request: *const demo.SumRequest) ?connect.RpcError {
        state.sum +|= request.number;
        state.count += 1;
        return null;
    }

    pub fn on_end(_: *App, _: *adapter.Call, state: *State, response: *demo.SumResponse) ?connect.RpcError {
        response.* = .{ .sum = state.sum, .count = state.count };
        return null;
    }
};

/// Countdown sends `from`, `from - 1`, ... down to 1.
fn countdown(_: *App, _: *adapter.Call, request: *const demo.CountdownRequest, sender: *adapter.Sender(demo.CountdownResponse)) ?connect.RpcError {
    if (request.from < 0 or request.from > countdown_max) return .{ .code = .out_of_range, .message = "from must be between 0 and 64" };
    const from: u32 = @intCast(request.from);
    for (0..from) |index| {
        const number: i32 = @intCast(from - index);
        sender.send(&.{ .number = number }) catch return .{ .code = .resource_exhausted };
    }
    return null;
}

/// Divide fails with a DivisionByZero detail when the divisor is 0.
fn divide(app: *App, _: *adapter.Call, request: *const demo.DivideRequest, response: *demo.DivideResponse) ?connect.RpcError {
    if (request.divisor == 0) {
        const detail: demo.DivisionByZero = .{ .dividend = request.dividend };
        const bytes = proto.encode(demo.DivisionByZero, &detail, &app.detail_bytes) catch return .{ .code = .internal };
        app.details[0] = .{ .type_name = demo.DivisionByZero.protobuf.full_name, .value = bytes };
        return .{ .code = .invalid_argument, .message = "division by zero", .details = &app.details };
    }
    // The divisor is not 0, so only the one overflow remains: the least i64 divided by -1.
    if (request.dividend == std.math.minInt(i64) and request.divisor == -1) return .{ .code = .out_of_range, .message = "quotient overflows" };
    response.* = .{ .quotient = @divTrunc(request.dividend, request.divisor), .remainder = @rem(request.dividend, request.divisor) };
    return null;
}

const plain = app_file.route_options;
const counted = with_interceptors(&.{Counting});
const guarded = with_interceptors(&.{ Logging, Auth });

fn with_interceptors(comptime interceptors: []const type) adapter.RouteOptions {
    var options = app_file.route_options;
    options.interceptors = interceptors;
    return options;
}

/// The demo's entries in the route table. Whoami runs behind its interceptors, as a POST and as
/// a GET.
pub const routes = .{
    adapter.post(App, Service.whoami, whoami, guarded),
    adapter.get(App, Service.whoami, whoami, guarded),
    adapter.post(App, Service.chat, Chat, counted),
    adapter.post(App, Service.sum, Sum, plain),
    adapter.post(App, Service.countdown, countdown, plain),
    adapter.post(App, Service.divide, divide, counted),
};
