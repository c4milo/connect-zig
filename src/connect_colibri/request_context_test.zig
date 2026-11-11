//! The call's request context (decision 35), through colibri's router: two bidirectional streams
//! interleave, and each callback reads its own call's; a call starts with the defaults; a hook
//! that takes no request context runs beside one that takes it.
const std = @import("std");
const testing = std.testing;
const connect = @import("connect");
const proto = @import("protobuf");
const server = @import("server");
const http = @import("http");
const rpc = @import("connect_colibri.zig");
const support = @import("pull_test_support.zig");
const Note = support.Note;

const say: connect.Method = .{ .service = "test.Svc", .name = "Say", .Request = Note, .Response = Note, .stream_type = .unary, .idempotency = .unknown };

/// The values each call keeps.
const RequestContext = struct {
    /// The number the interceptor gave the call.
    caller: u32 = 0,
    /// Set by the interceptor. A call that starts with it set started with another call's value.
    written: bool = false,
};

const records_max = 16;
const requests = 2;
const message_bytes = 64;
const token_bytes = 64;
const response_bytes = 256;
const note_bytes = 16;

const App = struct {
    callers: u32 = 0,
    /// The calls whose request context was not the defaults when the interceptor first saw it.
    dirty_starts: u32 = 0,
    plain_calls: u32 = 0,
    /// The caller each handler callback read, in order.
    seen: [records_max]u32 = @splat(0),
    seen_len: usize = 0,
    /// The caller each `on_finish` read, in order.
    finished: [records_max]u32 = @splat(0),
    finished_len: usize = 0,

    fn saw(app: *App, call: *rpc.Call) void {
        app.seen[app.seen_len] = call.request_context(RequestContext).caller;
        app.seen_len += 1;
    }
};

/// Gives each call the next number, in the call's request context.
const Stamp = struct {
    pub fn on_call(app: *App, _: *rpc.Call, context: *RequestContext) ?connect.RpcError {
        if (context.written or context.caller != 0) app.dirty_starts += 1;
        app.callers += 1;
        context.* = .{ .caller = app.callers, .written = true };
        return null;
    }

    pub fn on_finish(app: *App, _: *rpc.Call, context: *RequestContext, failure: ?connect.RpcError) ?connect.RpcError {
        app.finished[app.finished_len] = context.caller;
        app.finished_len += 1;
        return failure;
    }
};

/// A hook that takes no request context.
const Plain = struct {
    pub fn on_call(app: *App, _: *rpc.Call) ?connect.RpcError {
        app.plain_calls += 1;
        return null;
    }
};

/// Answers nothing, and records the caller each callback reads.
const Listener = struct {
    pub const State = struct {};

    pub fn on_message(app: *App, call: *rpc.Call, _: *State, _: *const Note, _: *rpc.Sender(Note)) ?connect.RpcError {
        app.saw(call);
        return null;
    }

    pub fn on_end(app: *App, call: *rpc.Call, _: *State, _: *rpc.Sender(Note)) ?connect.RpcError {
        app.saw(call);
        return null;
    }
};

fn on_say(app: *App, call: *rpc.Call, _: *const Note, _: *Note) ?connect.RpcError {
    app.saw(call);
    return null;
}

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

const options: rpc.RouteOptions = .{
    .message_bytes = message_bytes,
    .token_bytes = token_bytes,
    .interceptors = &.{ Plain, Stamp },
    .RequestContext = RequestContext,
};

const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = .{
        rpc.post(App, support.chat, Listener, options),
        rpc.post(App, say, on_say, options),
    },
}, .{ .requests = requests, .response_bytes = response_bytes, .body_bytes = response_bytes });

/// An engine that takes every octet at once, and keeps each request's user data apart.
const Engine = struct {
    user_data: [requests]usize = @splat(0),
    ended: [requests]bool = @splat(false),

    pub fn respond(engine: *Engine, id: server.RequestId, response: server.Response) server.SendError!void {
        engine.ended[slot_of(id)] = response.end;
    }

    pub fn write_body(engine: *Engine, id: server.RequestId, body: server.ResponseBody) server.SendError!usize {
        engine.ended[slot_of(id)] = body.end;
        return body.bytes.len;
    }

    pub fn write_trailers(engine: *Engine, id: server.RequestId, _: []const http.Field) server.SendError!void {
        engine.ended[slot_of(id)] = true;
    }

    pub fn set_user_data(engine: *Engine, id: server.RequestId, user_data: usize) error{RequestUnknown}!void {
        engine.user_data[slot_of(id)] = user_data;
    }

    pub fn cancel(_: *Engine, _: server.RequestId) void {}

    pub fn held_len(_: *Engine, _: server.RequestId) usize {
        return 0;
    }

    pub fn wait_release(_: *Engine, _: server.RequestId) void {}
};

/// The request ids are 1 and 2.
fn slot_of(id: server.RequestId) usize {
    return @intCast(@as(u128, @bitCast(id)) - 1);
}

fn id_of(slot: usize) server.RequestId {
    return @bitCast(@as(u128, slot + 1));
}

/// A request's header section; it is too large for a test's stack.
threadlocal var test_section: http.FieldSection align(@alignOf(http.FieldSection)) = undefined;

const h2_major = 2;
const h2_version: server.Version = .{ .major = h2_major, .minor = 0 };

const Fixture = struct {
    app: App = .{},
    engine: Engine = .{},
    pool: Router = .{},

    fn open(fixture: *Fixture, slot: usize, path: []const u8, content_type: []const u8) void {
        test_section.init();
        test_section.append("content-type", content_type) catch unreachable;
        fixture.handle(.{ .request = .{
            .id = id_of(slot),
            .method = "POST",
            .version = h2_version,
            .target = path,
            .scheme = "https",
            .authority = "example.com",
            .path = path,
            .query = null,
            .headers = .of(&test_section),
            .end = false,
        } });
    }

    /// Sends one note of a stream in an envelope, and ends the request when `end`.
    fn send(fixture: *Fixture, slot: usize, end: bool) void {
        var payload: [note_bytes]u8 = undefined;
        const encoded = proto.encode(Note, &.{ .text = "hi" }, &payload) catch unreachable;
        var envelope: [note_bytes + connect.constants.protocol.envelope_prefix_len]u8 = undefined;
        const bytes = connect.envelope.write(.{}, encoded, &envelope) catch unreachable;
        fixture.body(slot, bytes, end);
    }

    fn body(fixture: *Fixture, slot: usize, bytes: []const u8, end: bool) void {
        fixture.handle(.{ .body = .{ .id = id_of(slot), .user_data = fixture.engine.user_data[slot], .bytes = bytes, .end = end } });
    }

    /// Reports the request's end, as an engine does once its response went out, which frees
    /// the router's entry for the next call.
    fn finish(fixture: *Fixture, slot: usize) void {
        fixture.handle(.{ .finished = .{ .id = id_of(slot), .user_data = fixture.engine.user_data[slot], .result = .sent } });
    }

    fn handle(fixture: *Fixture, received: server.Event) void {
        const handled = fixture.pool.handle(&fixture.app, &fixture.engine, received);
        std.debug.assert(handled == .taken);
    }

    fn expect_seen(fixture: *const Fixture, expected: []const u32) !void {
        try testing.expectEqualSlices(u32, expected, fixture.app.seen[0..fixture.app.seen_len]);
    }
};

const chat_path = "/test.Svc/Chat";
const say_path = "/test.Svc/Say";
const stream_type = "application/connect+proto";

test "each callback of a stream reads its own call's request context, while another call runs" {
    var fixture: Fixture = .{};
    fixture.open(0, chat_path, stream_type);
    fixture.send(0, false);
    fixture.open(1, chat_path, stream_type);
    fixture.send(1, false);
    // The first call's second message comes after the second call's interceptor wrote its own.
    fixture.send(0, false);
    fixture.body(0, "", true);
    fixture.send(1, true);
    try fixture.expect_seen(&.{ 1, 2, 1, 1, 2, 2 });
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, fixture.app.finished[0..fixture.app.finished_len]);
    try testing.expect(fixture.engine.ended[0] and fixture.engine.ended[1]);
    // The hook that takes no request context ran for each call too.
    try testing.expectEqual(@as(u32, 2), fixture.app.plain_calls);
    try testing.expectEqual(@as(u32, 0), fixture.app.dirty_starts);
}

test "a call starts with the request context's defaults, after another call wrote it" {
    var fixture: Fixture = .{};
    // Each entry of the router serves two calls, one after the other.
    for (0..requests) |round| {
        for (0..requests) |slot| {
            fixture.open(slot, chat_path, stream_type);
            fixture.send(slot, true);
            try testing.expect(fixture.engine.ended[slot]);
            fixture.engine.ended[slot] = false;
            fixture.finish(slot);
        }
        _ = round;
    }
    try testing.expectEqual(@as(u32, 2 * requests), fixture.app.callers);
    try testing.expectEqual(@as(u32, 0), fixture.app.dirty_starts);
    try fixture.expect_seen(&.{ 1, 1, 2, 2, 3, 3, 4, 4 });
}

test "a function handler reads the request context its interceptor wrote" {
    var fixture: Fixture = .{};
    fixture.open(0, chat_path, stream_type);
    fixture.send(0, false);
    fixture.open(1, say_path, "application/proto");
    var payload: [note_bytes]u8 = undefined;
    fixture.body(1, proto.encode(Note, &.{ .text = "hi" }, &payload) catch unreachable, true);
    fixture.send(0, true);
    try fixture.expect_seen(&.{ 1, 2, 1, 1 });
    try testing.expectEqualSlices(u32, &.{ 2, 1 }, fixture.app.finished[0..fixture.app.finished_len]);
}
