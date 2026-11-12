//! The handlers that take a stream of requests: ClientStream and BidiStream, as type handlers
//! that take each message as it arrives (decision 18; docs/testing_servers.md in the conformance
//! suite, "ClientStream" and "BidiStream").
//!
//! A full-duplex BidiStream answers each request as it arrives, so over h2 the client reads an
//! answer before it sends the next request. A half-duplex one answers once the client ends.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const proto = @import("protobuf");
const rpc = @import("connect_colibri");
const service = @import("connectrpc_conformance_v1_service");
const echo_file = @import("echo.zig");
const unary = @import("unary.zig");
const constants = @import("constants.zig");
const App = @import("app.zig").App;

const Any = proto.wkt.Any;
const RequestInfo = service.ConformancePayload.RequestInfo;

/// The requests a stream received and has not echoed yet, each encoded for its Any, and the
/// first request, which holds the response definition.
pub fn Received(comptime Request: type) type {
    return struct {
        const Self = @This();

        first: [constants.definition_bytes]u8 = undefined,
        first_len: usize = 0,
        count_total: usize = 0,
        octets: [constants.requests_bytes]u8 = undefined,
        octets_len: usize = 0,
        anys: [constants.requests_max]Any = undefined,
        count: usize = 0,

        /// Keeps `request` for the next echo, and the first request for its definition.
        pub fn add(received: *Self, request: *const Request) !void {
            if (received.count == received.anys.len) return error.TooManyRequests;
            if (received.count_total == 0) {
                // The definition is what a stream reads again; the data may be as long as the
                // receive limit, so it is left out.
                var kept = request.*;
                kept.request_data = "";
                received.first_len = (try proto.encode(Request, &kept, &received.first)).len;
            }
            const any = try echo_file.any_of(Request, request, received.octets[received.octets_len..]);
            received.octets_len += any.value.len;
            received.anys[received.count] = any;
            received.count += 1;
            received.count_total += 1;
        }

        /// The requests received since the last `clear`.
        pub fn requests(received: *const Self) []const Any {
            return received.anys[0..received.count];
        }

        /// Forgets the requests echoed so far, and keeps the first.
        pub fn clear(received: *Self) void {
            received.count = 0;
            received.octets_len = 0;
        }

        /// The first request, decoded again. Its slices point into `first`.
        pub fn first_request(received: *const Self) ?Request {
            if (received.count_total == 0) return null;
            return proto.decode(Request, received.first[0..received.first_len]) catch null;
        }
    };
}

/// ClientStream echoes every request in its one response, as the first request's definition
/// asks.
pub const ClientStream = struct {
    pub const State = struct { received: Received(service.ClientStreamRequest) = .{} };

    pub fn on_message(_: *App, _: *rpc.Context, state: *State, request: *const rpc.Request(service.ClientStreamRequest)) ?connect.RpcError {
        state.received.add(&request.message) catch return echo_file.internal;
        return null;
    }

    pub fn on_end(app: *App, ctx: *rpc.Context, state: *State, request: *const rpc.AnyRequest, response: *rpc.Response(service.ClientStreamResponse)) ?connect.RpcError {
        const info = app.echo.request_info(ctx, request, state.received.requests());
        const first = state.received.first_request() orelse service.ClientStreamRequest{};
        return unary.answer(app, ctx, &response.any, first.response_definition, &info, &response.message.payload);
    }
};

/// BidiStream answers as the first request's definition asks: one response for each request
/// when `full_duplex` is set, or every response once the client ends.
pub const BidiStream = struct {
    pub const State = struct {
        received: Received(service.BidiStreamRequest) = .{},
        full_duplex: bool = false,
        sent: usize = 0,
        slept_ms: u64 = 0,
    };

    const Stream = rpc.ResponseStream(service.BidiStreamResponse);

    pub fn on_message(app: *App, ctx: *rpc.Context, state: *State, request: *const rpc.Request(service.BidiStreamRequest), response: *Stream) ?connect.RpcError {
        state.received.add(&request.message) catch return echo_file.internal;
        const first = state.received.first_request() orelse return echo_file.internal;
        const wanted = first.response_definition orelse return null;
        if (state.received.count_total == 1) {
            state.full_duplex = first.full_duplex;
            if (echo_file.apply_metadata(&response.any, &wanted.response_headers, &wanted.response_trailers)) |failure| return failure;
        }
        if (!state.full_duplex) return null;
        const data = nth(&wanted.response_data, state.sent) orelse return finish(app, ctx, &request.any, state, &wanted);
        return respond(app, ctx, &request.any, state, &wanted, data, response);
    }

    pub fn on_end(app: *App, ctx: *rpc.Context, state: *State, request: *const rpc.AnyRequest, response: *Stream) ?connect.RpcError {
        const first = state.received.first_request() orelse return null;
        const wanted = first.response_definition orelse return null;
        for (0..constants.responses_max) |_| {
            const data = nth(&wanted.response_data, state.sent) orelse break;
            if (respond(app, ctx, request, state, &wanted, data, response)) |failure| return failure;
        }
        return finish(app, ctx, request, state, &wanted);
    }

    /// Sends one response. The first echoes everything the server observed, and each later one
    /// the requests received since the response before it.
    fn respond(app: *App, ctx: *const rpc.Context, request: *const rpc.AnyRequest, state: *State, wanted: *const service.StreamResponseDefinition, data: []const u8, response: *Stream) ?connect.RpcError {
        if (echo_file.pause(app.io, ctx, wanted.response_delay_ms, &state.slept_ms)) |failure| return failure;
        const requests = state.received.requests();
        const info: RequestInfo = if (state.sent == 0) app.echo.request_info(ctx, request, requests) else .{ .requests = .of(requests) };
        response.send(&.{ .payload = .{ .data = data, .request_info = info } }) catch return echo_file.internal;
        state.sent += 1;
        state.received.clear();
        return null;
    }

    /// Ends the stream with the definition's error, if any, which carries the request info when
    /// no response went out.
    fn finish(app: *App, ctx: *const rpc.Context, request: *const rpc.AnyRequest, state: *State, wanted: *const service.StreamResponseDefinition) ?connect.RpcError {
        const failure = if (wanted.@"error") |*failure| failure else return null;
        if (state.sent != 0) return app.echo.failure(failure, null);
        const info = app.echo.request_info(ctx, request, state.received.requests());
        return app.echo.failure(failure, &info);
    }
};

/// The response data at `index`, or null past the last.
fn nth(data: *const proto.Repeated([]const u8, .bytes), index: usize) ?[]const u8 {
    var items = data.iterator();
    for (0..constants.responses_max) |position| {
        const bytes = (items.next() catch return null) orelse return null;
        if (position == index) return bytes;
    }
    return null;
}

const testing = std.testing;

/// What the tests fill; it is too large for a test's stack.
threadlocal var test_received: Received(service.BidiStreamRequest) align(@alignOf(Received(service.BidiStreamRequest))) = undefined;

test "a stream keeps its first request across a clear, and echoes only those since" {
    const received = &test_received;
    received.* = .{};
    try testing.expectEqual(@as(?service.BidiStreamRequest, null), received.first_request());
    try received.add(&.{ .full_duplex = true, .request_data = "one" });
    try received.add(&.{ .request_data = "two" });
    try testing.expectEqual(@as(usize, 2), received.requests().len);
    received.clear();
    try received.add(&.{ .request_data = "three" });
    try testing.expectEqual(@as(usize, 1), received.requests().len);
    const echoed = try proto.decode(service.BidiStreamRequest, received.requests()[0].value);
    try testing.expectEqualStrings("three", echoed.request_data);
    const first = received.first_request().?;
    try testing.expect(first.full_duplex);
    try testing.expectEqualStrings("", first.request_data);
}

test "the nth response data, and null past the last" {
    const items = [_][]const u8{ "a", "b" };
    const data: proto.Repeated([]const u8, .bytes) = .of(&items);
    try testing.expectEqualStrings("b", nth(&data, 1).?);
    try testing.expectEqual(@as(?[]const u8, null), nth(&data, 2));
}

comptime {
    assert(constants.definition_bytes <= constants.requests_bytes);
}
