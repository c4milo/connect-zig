//! interop.v1.InteropService, which clients in other languages call through
//! `tools/interop_languages_check.sh`: each RPC shape once, each message a coverage.v1.Everything,
//! the message that holds every protobuf type.
//!
//! Echo answers with the message as it was decoded. Decoding copies nothing, so its repeated
//! fields and its recursive messages go back out from the request's own octets.
const std = @import("std");
const connect = @import("connect");
const proto = @import("protobuf");
const rpc = @import("connect_colibri");
const interop = @import("interop");
const coverage = @import("coverage");
const App = @import("app.zig").App;
const Service = interop.InteropService;

/// The largest message a route reads or writes: the largest coverage case, in JSON, with room.
const message_bytes = 64 * 1024;
const token_bytes = 16 * 1024;
/// The most messages Repeat sends.
pub const repeat_max = 16;
/// The prefix of the request headers Inspect reports and sends back.
const inspected_prefix = "x-interop-";
/// The headers Inspect reports at most, and the octets of their "name: value" lines.
const inspected_max = 4;
const inspected_len = 1024;
const detail_len = 256;
const nanoseconds_per_millisecond = std.time.ns_per_ms;

/// The service's part of the example server's `App`. A reply is encoded before its handler's
/// call returns, so one room serves every call.
pub const Room = struct {
    lines: [inspected_max][]const u8 = undefined,
    line_octets: [inspected_len]u8 = undefined,
    detail_bytes: [detail_len]u8 = undefined,
    details: [1]connect.Detail = undefined,
};

fn echo(_: *App, _: *rpc.Context, request: *const rpc.Request(coverage.Everything), response: *rpc.Response(coverage.Everything)) ?connect.RpcError {
    response.message = request.message;
    return null;
}

fn repeat(_: *App, _: *rpc.Context, request: *const rpc.Request(interop.RepeatRequest), response: *rpc.ResponseStream(coverage.Everything)) ?connect.RpcError {
    const asked = &request.message;
    if (asked.count < 0 or asked.count > repeat_max) return .{ .code = .out_of_range, .message = "count must be between 0 and 16" };
    const message = asked.message orelse coverage.Everything{};
    for (0..@as(usize, @intCast(asked.count))) |_| {
        response.send(&message) catch return .{ .code = .resource_exhausted, .message = "no room to send" };
    }
    return null;
}

/// Counts the messages and keeps the last one's encoding, since the octets each message points
/// into are reused for the next.
const Collect = struct {
    pub const State = struct {
        count: i32 = 0,
        last: [message_bytes]u8 = undefined,
        last_len: usize = 0,
    };

    pub fn on_message(_: *App, _: *rpc.Context, state: *State, request: *const rpc.Request(coverage.Everything)) ?connect.RpcError {
        const kept = proto.encode(coverage.Everything, &request.message, &state.last) catch return .{ .code = .resource_exhausted, .message = "message too large" };
        state.last_len = kept.len;
        state.count += 1;
        return null;
    }

    pub fn on_end(_: *App, _: *rpc.Context, state: *State, _: *const rpc.AnyRequest, response: *rpc.Response(interop.CollectResponse)) ?connect.RpcError {
        const last = proto.decode(coverage.Everything, state.last[0..state.last_len]) catch return .{ .code = .internal };
        response.message = .{ .count = state.count, .last = if (state.count == 0) null else last };
        return null;
    }
};

/// Answers each message the moment it arrives.
const Chat = struct {
    pub const State = struct {};

    pub fn on_message(_: *App, _: *rpc.Context, _: *State, request: *const rpc.Request(coverage.Everything), response: *rpc.ResponseStream(coverage.Everything)) ?connect.RpcError {
        response.send(&request.message) catch return .{ .code = .resource_exhausted, .message = "no room to send" };
        return null;
    }

    pub fn on_end(_: *App, _: *rpc.Context, _: *State, _: *const rpc.AnyRequest, _: *rpc.ResponseStream(coverage.Everything)) ?connect.RpcError {
        return null;
    }
};

fn fail(app: *App, _: *rpc.Context, request: *const rpc.Request(interop.FailRequest), _: *rpc.Response(coverage.Everything)) ?connect.RpcError {
    const asked = &request.message;
    // statuscodes.md: the codes are 1 to 16; 0 is success, which is no failure.
    if (asked.code < @intFromEnum(connect.Code.canceled) or asked.code > @intFromEnum(connect.Code.unauthenticated)) {
        return .{ .code = .invalid_argument, .message = "code must be between 1 and 16" };
    }
    const room = &app.interop;
    const bytes = proto.encode(interop.FailRequest, asked, &room.detail_bytes) catch return .{ .code = .internal };
    room.details[0] = .{ .type_name = interop.FailRequest.protobuf.full_name, .value = bytes };
    return .{ .code = @enumFromInt(asked.code), .message = asked.message, .details = &room.details };
}

fn inspect(app: *App, ctx: *rpc.Context, request: *const rpc.Request(interop.InspectRequest), response: *rpc.Response(interop.InspectResponse)) ?connect.RpcError {
    const room = &app.interop;
    var count: usize = 0;
    var used: usize = 0;
    for (request.headers()) |header| {
        if (!std.ascii.startsWithIgnoreCase(header.name, inspected_prefix)) continue;
        if (count == inspected_max) return .{ .code = .resource_exhausted, .message = "too many x-interop headers" };
        const line = std.fmt.bufPrint(room.line_octets[used..], "{s}: {s}", .{ header.name, header.value }) catch
            return .{ .code = .resource_exhausted, .message = "x-interop headers too long" };
        room.lines[count] = line;
        count += 1;
        used += line.len;
        response.add_header(header.name, header.value) catch return .{ .code = .internal, .message = "no room for a header" };
        response.add_trailer(header.name, header.value) catch return .{ .code = .internal, .message = "no room for a trailer" };
    }
    const timeout_ms: i64 = if (ctx.timeout_ns()) |timeout| @intCast(timeout / nanoseconds_per_millisecond) else 0;
    response.message = .{ .timeout_ms = timeout_ms, .headers = .of(room.lines[0..count]) };
    return null;
}

const options: rpc.RouteOptions = .{ .message_bytes = message_bytes, .token_bytes = token_bytes };

pub const routes = .{
    rpc.post(App, Service.echo, echo, options),
    rpc.post(App, Service.echo_get, echo, options),
    rpc.get(App, Service.echo_get, echo, options),
    rpc.post(App, Service.repeat, repeat, options),
    rpc.post(App, Service.collect, Collect, options),
    rpc.post(App, Service.chat, Chat, options),
    rpc.post(App, Service.fail, fail, options),
    rpc.post(App, Service.inspect, inspect, options),
};
