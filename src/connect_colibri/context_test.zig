//! The views a handler and an interceptor take (decision 36), through colibri's router: what
//! `Context`, the requests and the responses read of a call, and what they write to the
//! response. An engine records each response header and trailer it takes.
const std = @import("std");
const testing = std.testing;
const connect = @import("connect");
const proto = @import("protobuf");
const server = @import("server");
const http = @import("http");
const rpc = @import("connect_colibri.zig");
const support = @import("pull_test_support.zig");
const Note = support.Note;

const say: connect.Method = .{ .service = "test.Svc", .name = "Say", .Request = Note, .Response = Note, .stream_type = .unary, .idempotency = .no_side_effects };
const gather: connect.Method = .{ .service = "test.Svc", .name = "Gather", .Request = Note, .Response = Note, .stream_type = .client_stream, .idempotency = .unknown };
const watch: connect.Method = .{ .service = "test.Svc", .name = "Watch", .Request = Note, .Response = Note, .stream_type = .server_stream, .idempotency = .unknown };
const tally: connect.Method = .{ .service = "test.Svc", .name = "Tally", .Request = Note, .Response = Note, .stream_type = .client_stream, .idempotency = .unknown };

const fields_max = 16;
const field_bytes = 1024;
const message_bytes = 64;
const token_bytes = 64;
const response_bytes = 512;
const note_bytes = 16;
/// Room for the envelopes of a stream's notes.
const notes_bytes = 64;
/// The timeout "5S" names, in nanoseconds.
const five_seconds_ns = 5_000_000_000;

/// What the handlers and the interceptor read.
const App = struct {
    path: []const u8 = "",
    protocol: ?connect.Protocol = null,
    codec: ?connect.Codec = null,
    timeout_ns: ?u64 = null,
    /// The "x-who" header, as the handler, the interceptor and `on_end` read it.
    who: ?[]const u8 = null,
    who_seen_by_interceptor: ?[]const u8 = null,
    who_at_end: ?[]const u8 = null,
    header_count: usize = 0,
    query: []const u8 = "",
    received: u32 = 0,
    sent: u32 = 0,
};

/// Reads the request through `AnyRequest`, marks the response through `AnyResponse`, and counts
/// the call's messages once it ends.
const Mark = struct {
    pub fn on_call(app: *App, _: *rpc.Context, request: *const rpc.AnyRequest, response: *rpc.AnyResponse) ?connect.RpcError {
        app.who_seen_by_interceptor = request.header("X-Who");
        response.add_header("x-mark", "on-call") catch return .{ .code = .internal };
        return null;
    }

    pub fn on_finish(app: *App, ctx: *rpc.Context, response: *rpc.AnyResponse, failure: ?connect.RpcError) ?connect.RpcError {
        app.received = ctx.received();
        app.sent = ctx.sent();
        response.add_trailer("x-finish", "on-finish") catch return .{ .code = .internal };
        return failure;
    }
};

fn on_say(app: *App, ctx: *rpc.Context, request: *const rpc.Request(Note), response: *rpc.Response(Note)) ?connect.RpcError {
    app.path = ctx.path();
    app.protocol = ctx.protocol();
    app.codec = ctx.codec();
    app.timeout_ns = ctx.timeout_ns();
    app.who = request.header("x-who");
    app.header_count = request.headers().len;
    app.query = request.query();
    response.message.text = request.message.text;
    response.add_header("x-handler", "say") catch return .{ .code = .internal };
    response.add_trailer("x-said", "done") catch return .{ .code = .internal };
    return null;
}

fn on_gather(app: *App, _: *rpc.Context, request: *rpc.RequestStream(Note), response: *rpc.Response(Note)) ?connect.RpcError {
    app.who = request.header("x-who");
    app.header_count = request.headers().len;
    for (0..note_bytes) |_| {
        const note = request.next() orelse break;
        response.message.text = note.text;
    }
    return null;
}

/// Sends one note, after a header, and ends with a trailer.
fn on_watch(_: *App, _: *rpc.Context, request: *const rpc.Request(Note), response: *rpc.ResponseStream(Note)) ?connect.RpcError {
    response.add_header("x-stream", "open") catch return .{ .code = .internal };
    response.send(&request.message) catch return .{ .code = .resource_exhausted };
    response.add_trailer("x-stream-end", "closed") catch return .{ .code = .internal };
    return null;
}

/// Answers once the client ends, and reads the request's header there, with no message.
const Tally = struct {
    pub const State = struct { count: u32 = 0 };

    pub fn on_message(_: *App, _: *rpc.Context, state: *State, _: *const rpc.Request(Note)) ?connect.RpcError {
        state.count += 1;
        return null;
    }

    pub fn on_end(app: *App, _: *rpc.Context, state: *State, request: *const rpc.AnyRequest, response: *rpc.Response(Note)) ?connect.RpcError {
        app.who_at_end = request.header("x-who");
        response.message.text = if (state.count == 0) "none" else "some";
        return null;
    }
};

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

const options: rpc.RouteOptions = .{ .message_bytes = message_bytes, .token_bytes = token_bytes, .interceptors = &.{Mark} };

const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = .{
        rpc.post(App, say, on_say, options),
        rpc.get(App, say, on_say, options),
        rpc.post(App, gather, on_gather, options),
        rpc.post(App, watch, on_watch, options),
        rpc.post(App, tally, Tally, options),
    },
}, .{ .requests = 1, .response_bytes = response_bytes, .body_bytes = response_bytes });

/// An engine that takes every octet at once, and keeps a copy of each response field.
const Engine = struct {
    names: [fields_max][]const u8 = undefined,
    values: [fields_max][]const u8 = undefined,
    count: usize = 0,
    octets: [field_bytes]u8 = undefined,
    used: usize = 0,
    user_data: usize = 0,
    ended: bool = false,

    fn keep(engine: *Engine, text: []const u8) []const u8 {
        const kept = engine.octets[engine.used..][0..text.len];
        @memcpy(kept, text);
        engine.used += text.len;
        return kept;
    }

    fn record(engine: *Engine, fields: []const http.Field) void {
        for (fields) |each| {
            engine.names[engine.count] = engine.keep(each.name);
            engine.values[engine.count] = engine.keep(each.value);
            engine.count += 1;
        }
    }

    /// The value of the response field `name`, in a head or in the trailers, or null.
    fn field(engine: *const Engine, name: []const u8) ?[]const u8 {
        for (engine.names[0..engine.count], engine.values[0..engine.count]) |each_name, value| {
            if (std.mem.eql(u8, each_name, name)) return value;
        }
        return null;
    }

    pub fn respond(engine: *Engine, _: server.RequestId, response: server.Response) server.SendError!void {
        engine.record(response.headers);
        engine.ended = response.end;
    }

    pub fn write_body(engine: *Engine, _: server.RequestId, body: server.ResponseBody) server.SendError!usize {
        engine.ended = body.end;
        return body.bytes.len;
    }

    pub fn write_trailers(engine: *Engine, _: server.RequestId, trailers: []const http.Field) server.SendError!void {
        engine.record(trailers);
        engine.ended = true;
    }

    pub fn set_user_data(engine: *Engine, _: server.RequestId, user_data: usize) error{RequestUnknown}!void {
        engine.user_data = user_data;
    }

    pub fn cancel(_: *Engine, _: server.RequestId) void {}

    pub fn held_len(_: *Engine, _: server.RequestId) usize {
        return 0;
    }

    pub fn wait_release(_: *Engine, _: server.RequestId) void {}
};

/// A request's header section; it is too large for a test's stack.
threadlocal var test_section: http.FieldSection align(@alignOf(http.FieldSection)) = undefined;

const request_id: server.RequestId = @bitCast(@as(u128, 1));
const h2_major = 2;
const h2_version: server.Version = .{ .major = h2_major, .minor = 0 };

const Head = struct {
    method: []const u8 = "POST",
    path: []const u8,
    query: ?[]const u8 = null,
    content_type: ?[]const u8 = "application/grpc+proto",
    timeout: ?[]const u8 = null,
};

const Fixture = struct {
    app: App = .{},
    engine: Engine = .{},
    pool: Router = .{},

    fn open(fixture: *Fixture, head: Head, end: bool) void {
        test_section.init();
        if (head.content_type) |content_type| test_section.append("content-type", content_type) catch unreachable;
        test_section.append("x-who", "ada") catch unreachable;
        if (head.timeout) |timeout| test_section.append("grpc-timeout", timeout) catch unreachable;
        fixture.handle(.{ .request = .{
            .id = request_id,
            .method = head.method,
            .version = h2_version,
            .target = head.path,
            .scheme = "https",
            .authority = "example.com",
            .path = head.path,
            .query = head.query,
            .headers = .of(&test_section),
            .end = end,
        } });
    }

    /// Sends notes in envelopes, and ends the request.
    fn send(fixture: *Fixture, count: usize) void {
        var payload: [note_bytes]u8 = undefined;
        const encoded = proto.encode(Note, &.{ .text = "hi" }, &payload) catch unreachable;
        var envelopes: [notes_bytes]u8 = undefined;
        var used: usize = 0;
        for (0..count) |_| used += (connect.envelope.write(.{}, encoded, envelopes[used..]) catch unreachable).len;
        fixture.handle(.{ .body = .{ .id = request_id, .user_data = fixture.engine.user_data, .bytes = envelopes[0..used], .end = true } });
    }

    fn handle(fixture: *Fixture, received: server.Event) void {
        const handled = fixture.pool.handle(&fixture.app, &fixture.engine, received);
        std.debug.assert(handled == .taken);
    }
};

test "a unary handler reads the call through ctx and request, and writes through response" {
    var fixture: Fixture = .{};
    fixture.open(.{ .path = "/test.Svc/Say", .timeout = "5S" }, false);
    fixture.send(1);
    const app = &fixture.app;
    try testing.expect(fixture.engine.ended);
    try testing.expectEqualStrings("/test.Svc/Say", app.path);
    try testing.expectEqual(connect.Protocol.grpc, app.protocol.?);
    try testing.expectEqual(connect.Codec.proto, app.codec.?);
    try testing.expectEqual(@as(?u64, five_seconds_ns), app.timeout_ns);
    // A header's name is compared in any case.
    try testing.expectEqualStrings("ada", app.who.?);
    try testing.expectEqualStrings("ada", app.who_seen_by_interceptor.?);
    try testing.expectEqual(@as(usize, 3), app.header_count);
    try testing.expectEqualStrings("", app.query);
    try testing.expectEqual(@as(u32, 1), app.received);
    // `on_finish` sees a one-message response before it goes out, so it may still refuse it.
    try testing.expectEqual(@as(u32, 0), app.sent);
    // What the handler and the interceptor wrote reaches the engine.
    try testing.expectEqualStrings("on-call", fixture.engine.field("x-mark").?);
    try testing.expectEqualStrings("say", fixture.engine.field("x-handler").?);
    try testing.expectEqualStrings("done", fixture.engine.field("x-said").?);
    try testing.expectEqualStrings("on-finish", fixture.engine.field("x-finish").?);
    try testing.expectEqualStrings("0", fixture.engine.field("grpc-status").?);
}

test "a GET's handler reads its query through the request" {
    var fixture: Fixture = .{};
    const query = "connect=v1&encoding=proto&base64=1&message=";
    fixture.open(.{ .method = "GET", .path = "/test.Svc/Say", .query = query, .content_type = null }, true);
    try testing.expectEqualStrings(query, fixture.app.query);
    try testing.expectEqual(connect.Protocol.connect, fixture.app.protocol.?);
    try testing.expectEqual(@as(?u64, null), fixture.app.timeout_ns);
}

test "a client stream's handler reads each message and the headers through its request" {
    var fixture: Fixture = .{};
    fixture.open(.{ .path = "/test.Svc/Gather" }, false);
    fixture.send(3);
    try testing.expect(fixture.engine.ended);
    try testing.expectEqualStrings("ada", fixture.app.who.?);
    try testing.expectEqual(@as(usize, 2), fixture.app.header_count);
    try testing.expectEqual(@as(u32, 3), fixture.app.received);
    try testing.expectEqual(@as(u32, 0), fixture.app.sent);
}

test "a type handler's on_end reads the request's headers, after no message at all" {
    var fixture: Fixture = .{};
    fixture.open(.{ .path = "/test.Svc/Tally" }, false);
    fixture.send(0);
    try testing.expect(fixture.engine.ended);
    try testing.expectEqualStrings("ada", fixture.app.who_at_end.?);
    try testing.expectEqual(@as(u32, 0), fixture.app.received);
}

test "a server stream's handler writes headers, messages and trailers through its response stream" {
    var fixture: Fixture = .{};
    fixture.open(.{ .path = "/test.Svc/Watch" }, false);
    fixture.send(1);
    try testing.expect(fixture.engine.ended);
    try testing.expectEqualStrings("open", fixture.engine.field("x-stream").?);
    try testing.expectEqualStrings("closed", fixture.engine.field("x-stream-end").?);
    try testing.expectEqualStrings("0", fixture.engine.field("grpc-status").?);
    try testing.expectEqual(@as(u32, 1), fixture.app.sent);
}
