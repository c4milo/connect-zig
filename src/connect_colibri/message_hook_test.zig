//! An interceptor's `on_message` (decision 47), through colibri's router: it reads each request
//! message once the route decoded it and before the handler takes it, at each place a route
//! decodes one. A function handler takes one message or reads a `RequestStream`; a type handler
//! takes each message in `on_message`, or a server stream's one request in `on_request`.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const connect = @import("connect");
const proto = @import("protobuf");
const server = @import("colibri").server;
const http = @import("colibri").http;
const rpc = @import("connect_colibri.zig");
const support = @import("pull_test_support.zig");
const platform = @import("platform");
const Note = support.Note;

fn method_of(comptime name: []const u8, comptime stream_type: connect.StreamType) connect.Method {
    return .{ .service = "test.Svc", .name = name, .Request = Note, .Response = Note, .stream_type = stream_type, .idempotency = .unknown };
}

const message_bytes = 64;
const token_bytes = 64;
const response_bytes = 512;
/// Octets of a request's note and of its envelope.
const note_bytes = 16;
const envelope_bytes = note_bytes + connect.constants.protocol.envelope_prefix_len;
/// The events a test records, at most.
const events_max = 16;
/// The notes a handler reads from a stream, at most.
const notes_max = 8;
/// The text of a note the first interceptor refuses.
const refused_text = "bad";
/// gRPC's status of `invalid_argument` (gRPC's "Status codes and their use in gRPC").
const status_invalid_argument = "3";

/// What ran, in order: 'a' the first interceptor read a message, 'b' the second one, 'h' the
/// handler took it, and 'e' the handler saw the stream's end.
const App = struct {
    cpu_features: platform.CpuFeatures = support.cpu_features,
    events: [events_max]u8 = undefined,
    count: usize = 0,
    /// The outcome `on_finish` read, and whether it ran.
    finished: bool = false,
    outcome: ?connect.Code = null,
    /// Whether a handler asked its stream for a message after the stream gave none.
    asks_again: bool = false,

    fn record(app: *App, event: u8) void {
        app.events[app.count] = event;
        app.count += 1;
    }

    fn seen(app: *const App) []const u8 {
        return app.events[0..app.count];
    }
};

/// Refuses a note whose text is `refused_text`, and reads the call's outcome.
const Guard = struct {
    pub fn on_message(app: *App, ctx: *rpc.Context, comptime T: type, message: *const T) ?connect.RpcError {
        comptime assert(T == Note);
        // The route counted the message before the hook read it.
        assert(ctx.received() > 0);
        app.record('a');
        if (std.mem.eql(u8, message.text, refused_text)) return .{ .code = .invalid_argument, .message = "bad note" };
        return null;
    }

    pub fn on_finish(app: *App, _: *rpc.Context, _: *rpc.AnyResponse, failure: ?connect.RpcError) ?connect.RpcError {
        app.finished = true;
        app.outcome = if (failure) |rpc_failure| rpc_failure.code else null;
        return failure;
    }
};

/// Runs after `Guard`, so it reads only what `Guard` let through.
const Second = struct {
    pub fn on_message(app: *App, _: *rpc.Context, comptime T: type, _: *const T) ?connect.RpcError {
        app.record('b');
        return null;
    }
};

/// Declares no `on_message`: the list still runs the two that do.
const Silent = struct {
    pub fn on_call(_: *App, _: *rpc.Context, _: *const rpc.AnyRequest, _: *rpc.AnyResponse) ?connect.RpcError {
        return null;
    }
};

fn on_one(app: *App, _: *rpc.Context, _: *const rpc.Request(Note), response: *rpc.Response(Note)) ?connect.RpcError {
    app.record('h');
    response.message.text = "ok";
    return null;
}

fn on_one_stream(app: *App, _: *rpc.Context, request: *const rpc.Request(Note), response: *rpc.ResponseStream(Note)) ?connect.RpcError {
    app.record('h');
    response.send(&request.message) catch return .{ .code = .resource_exhausted };
    return null;
}

/// Reads its stream to the end, as a function handler of a client stream does.
fn on_many(app: *App, _: *rpc.Context, request: *rpc.RequestStream(Note), _: *rpc.Response(Note)) ?connect.RpcError {
    read_all(app, request);
    return null;
}

fn on_many_stream(app: *App, _: *rpc.Context, request: *rpc.RequestStream(Note), _: *rpc.ResponseStream(Note)) ?connect.RpcError {
    read_all(app, request);
    return null;
}

fn read_all(app: *App, request: *rpc.RequestStream(Note)) void {
    for (0..notes_max) |_| {
        if (request.next() == null) break;
        app.record('h');
    }
    app.record('e');
    // A stream that ended with a failure gives no message to a handler that asks again.
    if (app.asks_again and request.next() != null) app.record('h');
}

/// A type handler of a client stream, and of a bidirectional stream.
fn Each(comptime bidirectional: bool) type {
    return struct {
        pub const State = struct {};
        pub const on_message = if (bidirectional) on_message_stream else on_message_one;

        fn on_message_one(app: *App, _: *rpc.Context, _: *State, _: *const rpc.Request(Note)) ?connect.RpcError {
            app.record('h');
            return null;
        }

        fn on_message_stream(app: *App, _: *rpc.Context, _: *State, _: *const rpc.Request(Note), _: *rpc.ResponseStream(Note)) ?connect.RpcError {
            app.record('h');
            return null;
        }

        pub fn on_end(app: *App, _: *rpc.Context, _: *State, _: *const rpc.AnyRequest, _: if (bidirectional) *rpc.ResponseStream(Note) else *rpc.Response(Note)) ?connect.RpcError {
            app.record('e');
            return null;
        }
    };
}

/// A type handler of a server stream, which takes its one request in `on_request`.
const Pulled = struct {
    pub const State = struct {};

    pub fn on_request(app: *App, _: *rpc.Context, _: *State, _: *const rpc.Request(Note)) ?connect.RpcError {
        app.record('h');
        return null;
    }

    pub fn next(_: *App, _: *rpc.Context, _: *State, _: *rpc.Response(Note)) rpc.Next {
        return .end;
    }
};

fn on_error(_: *App, _: *server.RequestContext, _: *const server.Request, _: anyerror, response: *server.Response) void {
    response.status = .internal_server_error;
}

const options: rpc.RouteOptions = .{ .message_bytes = message_bytes, .token_bytes = token_bytes, .interceptors = &.{ Guard, Silent, Second } };

const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = .{
        rpc.post(App, method_of("One", .unary), on_one, options),
        rpc.post(App, method_of("OneStream", .server_stream), on_one_stream, options),
        rpc.post(App, method_of("Many", .client_stream), on_many, options),
        rpc.post(App, method_of("ManyStream", .bidi_stream), on_many_stream, options),
        rpc.post(App, method_of("Each", .client_stream), Each(false), options),
        rpc.post(App, method_of("EachStream", .bidi_stream), Each(true), options),
        rpc.post(App, method_of("Pulled", .server_stream), Pulled, options),
    },
}, .{ .requests = 1, .response_bytes = response_bytes, .body_bytes = response_bytes, .header_bytes = 0 });

/// A request's header section; it is too large for a test's stack.
threadlocal var test_section: http.FieldSection align(@alignOf(http.FieldSection)) = undefined;

const request_id: server.RequestId = @bitCast(@as(u128, 1));
const h2_major = 2;

const Fixture = struct {
    app: App = .{},
    engine: support.Engine = .{ .window = response_bytes },
    pool: Router = .{},

    /// Sends a gRPC request to `path` with one note for each text, in one event, and ends it.
    fn call(fixture: *Fixture, comptime path: []const u8, texts: []const []const u8) void {
        test_section.init();
        test_section.append("content-type", "application/grpc+proto") catch unreachable;
        // colibri's `Headers` reads the lines through this slice while the router handles the head.
        const lines = test_section.slice();
        var head_body: std.Io.Reader = .fixed(&.{});
        fixture.handle(.{ .request = .{
            .id = request_id,
            .method = "POST",
            .version = .{ .major = h2_major, .minor = 0 },
            .target = path,
            .scheme = "https",
            .authority = "example.com",
            .path = path,
            .query = null,
            .headers = .init(&lines),
            .body = &head_body,
            .end = false,
        } });
        var envelopes: [notes_max * envelope_bytes]u8 = undefined;
        var used: usize = 0;
        for (texts) |text| {
            var payload: [note_bytes]u8 = undefined;
            const encoded = proto.encode(Note, &.{ .text = text }, &payload) catch unreachable;
            used += (connect.envelope.write(.{}, encoded, envelopes[used..]) catch unreachable).len;
        }
        fixture.handle(.{ .body = .{ .id = request_id, .user_data = fixture.engine.user_data, .bytes = envelopes[0..used], .end = true } });
        // A route with `next` writes its stream's end at the router's `writable`.
        if (!fixture.engine.ended) fixture.handle(.{ .writable = .{ .id = request_id, .user_data = fixture.engine.user_data } });
    }

    fn handle(fixture: *Fixture, received: server.Event) void {
        const handled = fixture.pool.handle(&fixture.app, &fixture.engine, received);
        assert(handled == .taken);
    }

    /// The call ended with success, after `events`.
    fn expect_passed(fixture: *const Fixture, events: []const u8) !void {
        try testing.expectEqualStrings(events, fixture.app.seen());
        try testing.expect(fixture.engine.ended);
        try testing.expectEqualStrings("0", fixture.engine.status());
        try testing.expect(fixture.app.finished);
        try testing.expectEqual(@as(?connect.Code, null), fixture.app.outcome);
    }

    /// The call ended with the first interceptor's error, after `events`, and `on_finish` read it.
    fn expect_refused(fixture: *const Fixture, events: []const u8) !void {
        try testing.expectEqualStrings(events, fixture.app.seen());
        try testing.expect(fixture.engine.ended);
        try testing.expectEqualStrings(status_invalid_argument, fixture.engine.status());
        try testing.expectEqualStrings("bad note", fixture.engine.message());
        try testing.expectEqual(@as(?connect.Code, .invalid_argument), fixture.app.outcome);
    }
};

test "decision 47: on_message reads a function handler's one message before the handler" {
    inline for (.{ "/test.Svc/One", "/test.Svc/OneStream" }) |path| {
        var fixture: Fixture = .{};
        fixture.call(path, &.{"good"});
        // Each interceptor that declares the hook runs, in the list's order, then the handler.
        try fixture.expect_passed("abh");
    }
}

test "decision 47: a message on_message refuses ends the call, and its handler does not run" {
    inline for (.{ "/test.Svc/One", "/test.Svc/OneStream", "/test.Svc/Pulled" }) |path| {
        var fixture: Fixture = .{};
        fixture.call(path, &.{refused_text});
        // The first error ends the list: the second interceptor reads nothing.
        try fixture.expect_refused("a");
    }
}

test "decision 47: on_message reads each message a function handler takes from its stream" {
    inline for (.{ "/test.Svc/Many", "/test.Svc/ManyStream" }) |path| {
        var fixture: Fixture = .{};
        fixture.call(path, &.{ "one", "two" });
        try fixture.expect_passed("abhabhe");
    }
}

test "decision 47: a refused message ends a function handler's stream, and the call fails" {
    inline for (.{ "/test.Svc/Many", "/test.Svc/ManyStream" }) |path| {
        var fixture: Fixture = .{ .app = .{ .asks_again = true } };
        fixture.call(path, &.{ "one", refused_text, "three" });
        // The handler took the first note, saw the stream end at the second, and a second ask
        // gave it no third.
        try fixture.expect_refused("abhae");
    }
}

test "decision 47: on_message reads each message before a type handler's on_message" {
    inline for (.{ "/test.Svc/Each", "/test.Svc/EachStream" }) |path| {
        var fixture: Fixture = .{};
        fixture.call(path, &.{ "one", "two" });
        try fixture.expect_passed("abhabhe");
    }
}

test "decision 47: a refused message ends a type handler's call before its on_end" {
    inline for (.{ "/test.Svc/Each", "/test.Svc/EachStream" }) |path| {
        var fixture: Fixture = .{};
        fixture.call(path, &.{ "one", refused_text, "three" });
        try fixture.expect_refused("abha");
    }
}

test "decision 47: on_message reads the one request of a server stream's type handler" {
    var fixture: Fixture = .{};
    fixture.call("/test.Svc/Pulled", &.{"good"});
    try fixture.expect_passed("abh");
}
