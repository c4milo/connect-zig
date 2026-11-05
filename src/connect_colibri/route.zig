//! A `connect.Method` served as a struct route of colibri's `server.router` (design §7).
//!
//! A function handler's route reads the whole request body (`.whole_body`), decodes its messages,
//! calls the handler, and writes the reply in the protocol the request spoke. A type handler's
//! route reads the body as it arrives and passes each message on while the reply goes out, which
//! is how a bidirectional stream runs full-duplex over h2 (decision 18). Every message a stream
//! writes goes out at once, and the whole reply stays bounded by the router's `response_bytes`
//! (decision 12).
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const server = @import("server");
const constants = @import("constants.zig");
const call_file = @import("call.zig");
const dispatch = @import("dispatch.zig");

pub const Options = struct {
    /// The longest message the route reads or writes, encoded or decoded.
    message_bytes: usize = constants.message_bytes_default,
    /// The longest JSON token of a request: a string's octets.
    token_bytes: usize = constants.token_bytes_default,
    /// The interceptors around the handler, outermost first (`dispatch.zig`).
    interceptors: []const type = &.{},
};

/// What a route keeps in its request's entry of the router pool. The request and the reply each
/// have their own areas, so a response may point into its request.
pub fn CallState(comptime options: Options, comptime handler: anytype) type {
    return struct {
        done: bool = false,
        started: bool = false,
        /// The longest request message the call reads (`receive_limit_of`).
        limit: usize = options.message_bytes,
        call: call_file.Call = undefined,
        request_message: [options.message_bytes]u8 = undefined,
        request_work: [options.message_bytes]u8 = undefined,
        tokens: [options.token_bytes]u8 = undefined,
        reply_message: [options.message_bytes]u8 = undefined,
        reply_work: [options.message_bytes]u8 = undefined,
        room: call_file.Room = .{},
        headers: call_file.RequestHeaders = .{},
        query: call_file.RequestQuery = .{},
        handler_state: dispatch.HandlerState(handler) = .{},
    };
}

/// The codings a server uses, which the program keeps in a field `codings` of its context. A
/// context with no such field reads and writes uncompressed messages alone.
pub const Codings = struct {
    decoders: connect.Decoders = .{},
    encoders: connect.Encoders = .{},
};

fn codings_of(app: anytype) Codings {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "codings")) return app.codings;
    return .{};
}

/// The longest request message a route reads: the context's field `message_receive_limit` when
/// it has one and it is not 0, else `message_bytes`. The limit counts a message's octets once
/// decompressed.
fn receive_limit_of(app: anytype, comptime message_bytes: usize) usize {
    const App = @TypeOf(app.*);
    if (comptime !@hasField(App, "message_receive_limit")) return message_bytes;
    const limit: usize = app.message_receive_limit;
    if (limit == 0) return message_bytes;
    return @min(limit, message_bytes);
}

/// The struct route of `method`, which calls `handler`. A function handler's signature follows
/// the stream type:
///
/// - unary: `fn (*App, *Call, *const Request, *Response) ?connect.RpcError`
/// - server stream: `fn (*App, *Call, *const Request, *Sender(Response)) ?connect.RpcError`
/// - client stream: `fn (*App, *Call, *Receiver(Request), *Response) ?connect.RpcError`
/// - bidirectional stream: `fn (*App, *Call, *Receiver(Request), *Sender(Response)) ?connect.RpcError`
///
/// A type handler of a client or bidirectional stream declares an optional `State` and:
///
/// - `on_message(*App, *Call, *State, *const Request, *Sender(Response))` for a bidirectional
///   stream, or `on_message(*App, *Call, *State, *const Request)` for a client stream;
/// - `on_end(*App, *Call, *State, *Sender(Response))`, or `on_end(..., *Response)`.
///
/// Each returns null to go on, or the error that ends the call.
///
/// A context may hold a field `message_receive_limit`, a count of octets: a request message
/// longer than it, once decompressed, fails the call with `resource_exhausted`.
pub fn Route(comptime App: type, comptime method: connect.Method, comptime handler: anytype, comptime options: Options) type {
    if (dispatch.is_streaming(handler)) assert(method.stream_type == .client_stream or method.stream_type == .bidi_stream);
    return struct {
        pub const State = CallState(options, handler);
        const Spec = RouteSpec{ .method = method, .options = options };

        pub fn on_request(app: *App, state: *State, request: *const server.Request, _: void, _: void, response: *server.ResponseWriter) !void {
            return begin(Spec, handler, app, state, request, response);
        }

        pub fn on_body(app: *App, state: *State, body: *std.Io.Reader, response: *server.ResponseWriter) !void {
            if (state.done) return;
            state.call.response = response;
            if (comptime dispatch.is_streaming(handler)) return serve_streaming(Spec, handler, app, state, body);
            return serve_whole(Spec, handler, app, state, body.buffered());
        }
    };
}

/// What a route's free functions need to know about it at compile time.
const RouteSpec = struct { method: connect.Method, options: Options };

/// Reads the head: copies the headers and the query, accepts or refuses the request, and starts
/// the call.
fn begin(comptime spec: RouteSpec, comptime handler: anytype, app: anytype, state: *CallState(spec.options, handler), request: *const server.Request, response: *server.ResponseWriter) !void {
    const codings = codings_of(app);
    state.limit = receive_limit_of(app, spec.options.message_bytes);
    state.headers.copy(request.headers) catch {
        state.done = true;
        // RFC 6585 §5: headers larger than the server keeps get 431.
        response.status = constants.status_headers_too_large;
        return response.end();
    };
    // The accepted GET's query points into this copy, which lasts until the call ends.
    const query = state.query.copy(request.query) catch {
        state.done = true;
        // RFC 9110 §15.5.15: a target longer than the server reads gets 414.
        response.status = constants.status_uri_too_long;
        return response.end();
    };
    const decision = connect.server.accept(request.method, query, state.headers.lookup(), .{
        .stream_type = spec.method.stream_type,
        .idempotency = spec.method.idempotency,
        .decoders = codings.decoders,
        .encoders = codings.encoders,
    });
    const accepted = switch (decision) {
        .accepted => |accepted| accepted,
        .refused => |refused| {
            state.done = true;
            return call_file.answer_refusal(refused, scratch_of(spec.options, handler, state, .reply), &state.room, &state.headers, response);
        },
    };
    state.call = .{
        .reply = .{ .accepted = accepted, .scratch = scratch_of(spec.options, handler, state, .reply), .encoders = codings.encoders },
        .response = response,
        .room = &state.room,
        .headers = &state.headers,
        .path = comptime spec.method.path(),
        .query = query orelse "",
    };
}

fn serve_whole(comptime spec: RouteSpec, comptime handler: anytype, app: anytype, state: *CallState(spec.options, handler), body: []const u8) !void {
    assert(!state.done);
    state.done = true;
    // A Connect unary body is the message itself, and an uncompressed one is read in place, so
    // its length is checked here; every other message is read into storage of `limit` octets.
    if (read_in_place(state.call.reply.accepted) and body.len > state.limit) {
        return stop(dispatch.Interceptors(spec.options.interceptors), app, state, too_large);
    }
    var messages = connect.server.Messages.init(state.call.reply.accepted, body, scratch_of(spec.options, handler, state, .request), codings_of(app).decoders);
    return dispatch.whole(spec.method, handler, dispatch.Interceptors(spec.options.interceptors), app, &state.call, &messages);
}

/// Takes each whole envelope that arrived, and keeps a partial one for the next call.
fn serve_streaming(comptime spec: RouteSpec, comptime handler: anytype, app: anytype, state: *CallState(spec.options, handler), body: *std.Io.Reader) !void {
    const I = dispatch.Interceptors(spec.options.interceptors);
    const call = &state.call;
    if (!state.started) {
        state.started = true;
        if (I.on_call(app, call)) |refusal| return stop(I, app, state, refusal);
    }
    const buffered = body.buffered();
    const whole_len = dispatch.whole_envelopes_len(buffered, state.limit) catch |failure|
        return stop(I, app, state, connect.server.failure_of(failure));
    var messages = connect.server.Messages.init(state.call.reply.accepted, buffered[0..whole_len], scratch_of(spec.options, handler, state, .request), codings_of(app).decoders);
    if (dispatch.each_message(spec.method, handler, app, call, &state.handler_state, &messages)) |failure| return stop(I, app, state, failure);
    body.toss(whole_len);
    // A read past the octets that arrived says whether the body ended or more will come.
    _ = body.peek(body.bufferedLen() + 1) catch |failure| switch (failure) {
        error.EndOfStream => {
            // Connect protocol, "Streaming-Request", and gRPC's "Length-Prefixed-Message": a body
            // ends between envelopes. One that stops inside an envelope fails the call.
            if (body.bufferedLen() != 0) return stop(I, app, state, .{ .code = .invalid_argument, .message = "truncated message" });
            state.done = true;
            return dispatch.end_stream(spec.method, handler, I, app, call, &state.handler_state);
        },
        // More bytes will come; the router keeps those left unread for the next call.
        error.ReadFailed => return,
    };
}

fn stop(comptime I: type, app: anytype, state: anytype, failure: connect.RpcError) !void {
    state.done = true;
    return call_file.finish(&state.call, I.on_finish(app, &state.call, failure));
}

/// Whether the request's one message is its body as it arrived: a Connect unary POST with no
/// coding. `Messages` reads it in place, with no copy that `limit` bounds.
fn read_in_place(accepted: connect.server.Accepted) bool {
    return !accepted.speaks.enveloped and accepted.query == null and accepted.request_coding == .identity;
}

/// statuscodes.md, RESOURCE_EXHAUSTED: a message over the server's limit.
const too_large: connect.RpcError = .{ .code = .resource_exhausted, .message = "message larger than the server reads" };

const Side = enum { request, reply };

fn scratch_of(comptime options: Options, comptime handler: anytype, state: *CallState(options, handler), side: Side) connect.Scratch {
    assert(state.limit <= options.message_bytes);
    return switch (side) {
        .request => .{ .message = state.request_message[0..state.limit], .work = &state.request_work, .tokens = &state.tokens },
        .reply => .{ .message = &state.reply_message, .work = &state.reply_work, .tokens = &state.tokens },
    };
}

/// The router entry that serves `method` as a POST. A type handler's route reads the body as it
/// arrives; a function handler's reads it whole.
pub fn post(comptime App: type, comptime method: connect.Method, comptime handler: anytype, comptime options: Options) @TypeOf(.{ .post, method.path(), Route(App, method, handler, options), .{ .whole_body = !dispatch.is_streaming(handler) } }) {
    return .{ .post, comptime method.path(), Route(App, method, handler, options), .{ .whole_body = comptime !dispatch.is_streaming(handler) } };
}

/// The router entry that serves `method` as a GET, for a method with no side effects (Connect
/// protocol, "Unary-Get-Request").
pub fn get(comptime App: type, comptime method: connect.Method, comptime handler: anytype, comptime options: Options) @TypeOf(.{ .get, method.path(), Route(App, method, handler, options), .{ .whole_body = true } }) {
    comptime assert(method.stream_type == .unary and method.idempotency == .no_side_effects);
    return .{ .get, comptime method.path(), Route(App, method, handler, options), .{ .whole_body = true } };
}

const testing = std.testing;

test "the receive limit is the context's when it is set and smaller, else message_bytes" {
    const message_bytes = 100;
    const Limited = struct { message_receive_limit: u32 = 0 };
    var limited: Limited = .{ .message_receive_limit = 40 };
    try testing.expectEqual(@as(usize, 40), receive_limit_of(&limited, message_bytes));
    limited.message_receive_limit = 0;
    try testing.expectEqual(@as(usize, message_bytes), receive_limit_of(&limited, message_bytes));
    limited.message_receive_limit = message_bytes + 1;
    try testing.expectEqual(@as(usize, message_bytes), receive_limit_of(&limited, message_bytes));
    const Plain = struct {};
    var plain: Plain = .{};
    try testing.expectEqual(@as(usize, message_bytes), receive_limit_of(&plain, message_bytes));
}

test "only an uncompressed Connect unary POST is read in place" {
    const unary: connect.server.Accepted = .{ .speaks = .{ .protocol = .connect, .codec = .proto, .enveloped = false }, .request_coding = .identity, .response_coding = .identity, .timeout_ns = null };
    try testing.expect(read_in_place(unary));
    var gzipped = unary;
    gzipped.request_coding = .gzip;
    try testing.expect(!read_in_place(gzipped));
    var get_request = unary;
    get_request.query = .{ .codec = .proto, .message = "" };
    try testing.expect(!read_in_place(get_request));
    var stream = unary;
    stream.speaks.enveloped = true;
    try testing.expect(!read_in_place(stream));
}
