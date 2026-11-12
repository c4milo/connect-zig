//! A `connect.Method` served as a struct route of colibri's `server.Router` (design §7).
//!
//! A function handler's route reads the whole request body (`.whole_body`), decodes its messages,
//! calls the handler, and writes the reply in the protocol the request spoke. A type handler's
//! route reads the body as it arrives and passes each message on while the reply goes out, which
//! is how a bidirectional stream runs full-duplex over h2 (decision 18). Every message a `Sender`
//! writes goes out at once, and what it writes in one call stays bounded by the router's
//! `response_bytes` (decision 12). A type handler with `next` has no such bound: its route asks
//! it for one message at a time, at colibri's `on_writable` (`pull.zig`, decision 33).
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const server = @import("server");
const constants = @import("constants.zig");
const call_file = @import("call.zig");
const context_file = @import("context.zig");
const dispatch = @import("dispatch.zig");
const pull = @import("pull.zig");

pub const Options = struct {
    /// The longest message the route reads or writes, encoded or decoded.
    message_bytes: usize = constants.message_bytes_default,
    /// The longest JSON token of a request: a string's octets.
    token_bytes: usize = constants.token_bytes_default,
    /// The interceptors around the handler, outermost first (`dispatch.zig`).
    interceptors: []const type = &.{},
    /// The program's values for each call: a struct whose fields each have a default. Every call
    /// starts with `.{}`, and an interceptor and a handler read it with `Context.values`
    /// (decision 35).
    Values: type = struct {},
};

/// What a route keeps in its request's entry of the router pool. The request and the reply each
/// have their own areas, so a response may point into its request.
pub fn CallState(comptime options: Options, comptime handler: anytype) type {
    return struct {
        /// The route reads no more of the request. A route with no `next` has then written its
        /// whole response too.
        done: bool = false,
        started: bool = false,
        /// The longest request message the call reads (`receive_limit_of`).
        limit: usize = options.message_bytes,
        call: call_file.Call = undefined,
        request_message: [options.message_bytes]u8 = undefined,
        request_work: [options.message_bytes]u8 = undefined,
        tokens: [options.token_bytes]u8 = undefined,
        /// A reply message of `message_bytes`, after the octets of its envelope's prefix
        /// (`connect.server.Reply.prepare`).
        reply_message: [reply_bytes]u8 = undefined,
        reply_work: [reply_bytes]u8 = undefined,
        room: call_file.Room = .{},
        headers: call_file.RequestHeaders = .{},
        query: call_file.RequestQuery = .{},
        handler_state: dispatch.HandlerState(handler) = .{},
        /// The program's values for the call (decision 35). colibri sets the state to its
        /// defaults at each request, so each call starts with `.{}`.
        values: options.Values = .{},
        /// How far a route with `next` wrote its response.
        outgoing: if (pulls) pull.Outgoing else struct {} = .{},

        const reply_bytes = options.message_bytes + connect.constants.protocol.envelope_prefix_len;
        /// Whether the route asks the handler for each message of the response.
        pub const pulls = dispatch.pulls(handler);
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

/// The struct route of `method`, which calls `handler`. A handler takes the call's `Context`, its
/// request and its response (`context.zig`, decision 36). A function handler's signature follows
/// the stream type, with `Req` and `Res` the method's message types:
///
/// - unary: `fn (*App, *Context, *const Request(Req), *Response(Res)) ?connect.RpcError`
/// - server stream: `fn (*App, *Context, *const Request(Req), *ResponseStream(Res)) ?connect.RpcError`
/// - client stream: `fn (*App, *Context, *RequestStream(Req), *Response(Res)) ?connect.RpcError`
/// - bidirectional stream: `fn (*App, *Context, *RequestStream(Req), *ResponseStream(Res)) ?connect.RpcError`
///
/// A type handler of a client or bidirectional stream declares an optional `State` and:
///
/// - `on_message(*App, *Context, *State, *const Request(Req), *ResponseStream(Res))` for a
///   bidirectional stream, or `on_message(*App, *Context, *State, *const Request(Req))` for a
///   client stream;
/// - `on_end(*App, *Context, *State, *const AnyRequest, *ResponseStream(Res))`, or
///   `on_end(..., *Response(Res))`: the request with no message, whose headers last to the end.
///
/// Each returns null to go on, or the error that ends the call.
///
/// A type handler of a server or bidirectional stream may also declare
/// `next(*App, *Context, *State, *Response(Res)) Next`. The route calls it for one message at a
/// time while the response memory has room, so the stream may be longer than the router's
/// `response_bytes` (decision 33). A server stream's type handler declares `next` and
/// `on_request(*App, *Context, *State, *const Request(Req))`, which takes the stream's one
/// request. The request's strings point into the request body, which lasts only until
/// `on_request` returns.
///
/// The program's `App` may hold a field `message_receive_limit`, a count of octets: a request message
/// longer than it, once decompressed, fails the call with `resource_exhausted`.
pub fn Route(comptime App: type, comptime method: connect.Method, comptime handler: anytype, comptime options: Options) type {
    comptime dispatch.check(method, handler);
    comptime check_values(options.Values);
    const Spec = RouteSpec{ .method = method, .options = options };
    const Whole = struct {
        pub const State = CallState(options, handler);

        pub fn on_request(app: *App, state: *State, request: *const server.Request, _: void, _: void, response: *server.ResponseWriter) !void {
            return begin(Spec, handler, app, state, request, response);
        }

        pub fn on_body(app: *App, state: *State, body: *std.Io.Reader, response: *server.ResponseWriter) !void {
            if (state.done) return;
            state.call.response = response;
            if (comptime dispatch.reads_pieces(method, handler)) return serve_streaming(Spec, handler, app, state, body);
            if (comptime dispatch.is_streaming(handler)) return serve_request(Spec, handler, app, state, body.buffered());
            return serve_whole(Spec, handler, app, state, body.buffered());
        }
    };
    if (comptime !dispatch.pulls(handler)) return Whole;
    // colibri's router ends the response of a route with no `on_writable` once its body ended, so
    // only a route with `next` declares one.
    return struct {
        pub const State = Whole.State;
        pub const on_request = Whole.on_request;
        pub const on_body = Whole.on_body;

        pub fn on_writable(app: *App, state: *State, response: *server.ResponseWriter) !void {
            return serve_writable(Spec, handler, app, state, response);
        }
    };
}

/// Fails the build when `Values` is not a struct whose fields each have a default, so each call
/// can start with `.{}` (decision 35).
fn check_values(comptime Values: type) void {
    if (@typeInfo(Values) != .@"struct") @compileError("RouteOptions.Values is a struct, not " ++ @typeName(Values));
    for (@typeInfo(Values).@"struct".fields) |field| {
        if (field.defaultValue() == null) @compileError("each field of RouteOptions.Values has a default, and " ++ field.name ++ " has none");
    }
}

/// What a route's free functions need to know about it at compile time.
const RouteSpec = struct { method: connect.Method, options: Options };

/// Reads the head: copies the headers and the query, accepts or refuses the request, and starts
/// the call.
fn begin(comptime spec: RouteSpec, comptime handler: anytype, app: anytype, state: *CallState(spec.options, handler), request: *const server.Request, response: *server.ResponseWriter) !void {
    const codings = codings_of(app);
    state.limit = receive_limit_of(app, spec.options.message_bytes);
    state.headers.copy(request.headers) catch {
        refuse(state);
        // RFC 6585 §5: headers larger than the server keeps get 431.
        response.status = constants.status_headers_too_large;
        return response.end();
    };
    // The accepted GET's query points into this copy, which lasts until the call ends.
    const query = state.query.copy(request.query) catch {
        refuse(state);
        // RFC 9110 §15.5.15: a target longer than the server reads gets 414.
        response.status = constants.status_uri_too_long;
        return response.end();
    };
    const decision = connect.server.accept(request.method, query, state.headers.lookup(), &.{
        .stream_type = spec.method.stream_type,
        .idempotency = spec.method.idempotency,
        .decoders = codings.decoders,
        .encoders = codings.encoders,
    });
    const accepted = switch (decision) {
        .accepted => |accepted| accepted,
        .refused => |refused| {
            refuse(state);
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
        .values_pointer = &state.values,
        .values_name = @typeName(spec.options.Values),
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
    var messages = connect.server.Messages.init(&state.call.reply.accepted, body, &scratch_of(spec.options, handler, state, .request), &codings_of(app).decoders);
    return dispatch.whole(spec.method, handler, dispatch.Interceptors(spec.options.interceptors), app, &state.call, &messages);
}

/// Takes each whole envelope that arrived, and keeps a partial one for the next call.
fn serve_streaming(comptime spec: RouteSpec, comptime handler: anytype, app: anytype, state: *CallState(spec.options, handler), body: *std.Io.Reader) !void {
    const I = dispatch.Interceptors(spec.options.interceptors);
    const call = &state.call;
    if (start_once(I, app, state)) |refusal| return stop(I, app, state, refusal);
    const buffered = body.buffered();
    const whole_len = dispatch.whole_envelopes_len(buffered, state.limit) catch |failure|
        return stop(I, app, state, connect.server.failure_of(failure));
    var messages = connect.server.Messages.init(&state.call.reply.accepted, buffered[0..whole_len], &scratch_of(spec.options, handler, state, .request), &codings_of(app).decoders);
    if (dispatch.each_message(spec.method, handler, app, call, &state.handler_state, &messages)) |failure| return stop(I, app, state, failure);
    body.toss(whole_len);
    // A read past the octets that arrived says whether the body ended or more will come.
    _ = body.peek(body.bufferedLen() + 1) catch |failure| switch (failure) {
        error.EndOfStream => {
            // Connect protocol, "Streaming-Request", and gRPC's "Length-Prefixed-Message": a body
            // ends between envelopes. One that stops inside an envelope fails the call.
            if (body.bufferedLen() != 0) return stop(I, app, state, .{ .code = .invalid_argument, .message = "truncated message" });
            state.done = true;
            if (comptime !dispatch.pulls(handler)) return dispatch.end_stream(spec.method, handler, I, app, call, &state.handler_state);
            // The handler's `next` ends the stream, at the `on_writable` that follows this call.
            if (dispatch.end_input(spec.method, handler, app, call, &state.handler_state)) |rpc_failure| return stop(I, app, state, rpc_failure);
            return;
        },
        // More bytes will come; the router keeps those left unread for the next call.
        error.ReadFailed => return,
    };
}

/// Reads the one request of a server stream whose handler declares `next`, and passes it to the
/// handler's `on_request`. The router then calls `on_writable`, which sends the stream.
fn serve_request(comptime spec: RouteSpec, comptime handler: anytype, app: anytype, state: *CallState(spec.options, handler), body: []const u8) !void {
    comptime assert(spec.method.stream_type == .server_stream);
    assert(!state.done);
    state.done = true;
    const I = dispatch.Interceptors(spec.options.interceptors);
    const call = &state.call;
    if (start_once(I, app, state)) |refusal| return stop(I, app, state, refusal);
    var messages = connect.server.Messages.init(&call.reply.accepted, body, &scratch_of(spec.options, handler, state, .request), &codings_of(app).decoders);
    var request: context_file.Request(spec.method.Request) = .{ .message = .{}, .any = .{ .call = call } };
    switch (call_file.read_one(spec.method.Request, call, &messages, &request.message)) {
        .failure => |failure| return stop(I, app, state, failure),
        .message => {},
    }
    var ctx: context_file.Context = .{ .call = call };
    if (handler.on_request(app, &ctx, &state.handler_state, &request)) |failure| return stop(I, app, state, failure);
}

/// Sends what a stream with `next` has, while the response memory takes it (`pull.zig`).
fn serve_writable(comptime spec: RouteSpec, comptime handler: anytype, app: anytype, state: *CallState(spec.options, handler), response: *server.ResponseWriter) !void {
    if (state.outgoing.phase == .done) return;
    const I = dispatch.Interceptors(spec.options.interceptors);
    state.call.response = response;
    // A server stream sends nothing before its request arrived whole.
    if (comptime !dispatch.reads_pieces(spec.method, handler)) {
        if (!state.started) return;
    } else if (start_once(I, app, state)) |refusal| return stop(I, app, state, refusal);
    return pull.serve(spec.method, handler, I, app, &state.call, &state.outgoing, &state.handler_state, !state.done);
}

/// Runs the interceptors' `on_call` before the handler first runs, and returns their refusal.
fn start_once(comptime I: type, app: anytype, state: anytype) ?connect.RpcError {
    if (state.started) return null;
    state.started = true;
    return I.on_call(app, &state.call);
}

/// Ends the call with `failure`. A route with `next` may hold a message, and may have no room
/// for the end, so its stream writes the end (`pull.end`).
fn stop(comptime I: type, app: anytype, state: anytype, failure: connect.RpcError) !void {
    state.done = true;
    if (comptime @TypeOf(state.*).pulls) return pull.end(I, app, &state.call, &state.outgoing, failure);
    return call_file.finish(&state.call, I.on_finish(app, &state.call, failure));
}

/// Marks a request the route refused at its head, which no handler sees.
fn refuse(state: anytype) void {
    state.done = true;
    if (comptime @TypeOf(state.*).pulls) state.outgoing.phase = .done;
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

/// The router entry that serves `method` as a POST. A type handler's route of a client or
/// bidirectional stream reads the body as it arrives; every other route reads it whole.
pub fn post(comptime App: type, comptime method: connect.Method, comptime handler: anytype, comptime options: Options) @TypeOf(.{ .post, method.path(), Route(App, method, handler, options), .{ .whole_body = !dispatch.reads_pieces(method, handler) } }) {
    return .{ .post, comptime method.path(), Route(App, method, handler, options), .{ .whole_body = comptime !dispatch.reads_pieces(method, handler) } };
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
