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

fn echo(_: *App, _: *rpc.Call, request: *const coverage.Everything, response: *coverage.Everything) ?connect.RpcError {
    response.* = request.*;
    return null;
}

fn repeat(_: *App, _: *rpc.Call, request: *const interop.RepeatRequest, sender: *rpc.Sender(coverage.Everything)) ?connect.RpcError {
    if (request.count < 0 or request.count > repeat_max) return .{ .code = .out_of_range, .message = "count must be between 0 and 16" };
    const message = request.message orelse coverage.Everything{};
    for (0..@as(usize, @intCast(request.count))) |_| {
        sender.send(&message) catch return .{ .code = .resource_exhausted, .message = "no room to send" };
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

    pub fn on_message(_: *App, _: *rpc.Call, state: *State, request: *const coverage.Everything) ?connect.RpcError {
        const kept = proto.encode(coverage.Everything, request, &state.last) catch return .{ .code = .resource_exhausted, .message = "message too large" };
        state.last_len = kept.len;
        state.count += 1;
        return null;
    }

    pub fn on_end(_: *App, _: *rpc.Call, state: *State, response: *interop.CollectResponse) ?connect.RpcError {
        const last = proto.decode(coverage.Everything, state.last[0..state.last_len]) catch return .{ .code = .internal };
        response.* = .{ .count = state.count, .last = if (state.count == 0) null else last };
        return null;
    }
};

/// Answers each message the moment it arrives.
const Chat = struct {
    pub const State = struct {};

    pub fn on_message(_: *App, _: *rpc.Call, _: *State, request: *const coverage.Everything, sender: *rpc.Sender(coverage.Everything)) ?connect.RpcError {
        sender.send(request) catch return .{ .code = .resource_exhausted, .message = "no room to send" };
        return null;
    }

    pub fn on_end(_: *App, _: *rpc.Call, _: *State, _: *rpc.Sender(coverage.Everything)) ?connect.RpcError {
        return null;
    }
};

fn fail(app: *App, _: *rpc.Call, request: *const interop.FailRequest, _: *coverage.Everything) ?connect.RpcError {
    // statuscodes.md: the codes are 1 to 16; 0 is success, which is no failure.
    if (request.code < @intFromEnum(connect.Code.canceled) or request.code > @intFromEnum(connect.Code.unauthenticated)) {
        return .{ .code = .invalid_argument, .message = "code must be between 1 and 16" };
    }
    const room = &app.interop;
    const bytes = proto.encode(interop.FailRequest, request, &room.detail_bytes) catch return .{ .code = .internal };
    room.details[0] = .{ .type_name = interop.FailRequest.protobuf.full_name, .value = bytes };
    return .{ .code = @enumFromInt(request.code), .message = request.message, .details = &room.details };
}

fn inspect(app: *App, call: *rpc.Call, _: *const interop.InspectRequest, response: *interop.InspectResponse) ?connect.RpcError {
    const room = &app.interop;
    var count: usize = 0;
    var used: usize = 0;
    for (call.request_headers()) |header| {
        if (!std.ascii.startsWithIgnoreCase(header.name, inspected_prefix)) continue;
        if (count == inspected_max) return .{ .code = .resource_exhausted, .message = "too many x-interop headers" };
        const line = std.fmt.bufPrint(room.line_octets[used..], "{s}: {s}", .{ header.name, header.value }) catch
            return .{ .code = .resource_exhausted, .message = "x-interop headers too long" };
        room.lines[count] = line;
        count += 1;
        used += line.len;
        call.add_header(header.name, header.value) catch return .{ .code = .internal, .message = "no room for a header" };
        call.add_trailer(header.name, header.value) catch return .{ .code = .internal, .message = "no room for a trailer" };
    }
    const timeout_ms: i64 = if (call.timeout_ns()) |timeout| @intCast(timeout / nanoseconds_per_millisecond) else 0;
    response.* = .{ .timeout_ms = timeout_ms, .headers = .of(room.lines[0..count]) };
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
