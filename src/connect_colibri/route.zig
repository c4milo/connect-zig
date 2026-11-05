//! A `connect.Method` served as a struct route of colibri's `server.router` (design §7). The route
//! reads the whole request body (`.whole_body`), decodes its messages, calls the program's
//! handler, and writes the reply in the protocol the request spoke. A stream is written into the
//! router's response memory, so it is bounded by `response_bytes` (decision 12).
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const server = @import("server");
const http = @import("http");
const constants = @import("constants.zig");
const call_file = @import("call.zig");

pub const Options = struct {
    /// The longest message the route reads or writes, encoded or decoded.
    message_bytes: usize = constants.message_bytes_default,
    /// The longest JSON token of a request: a string's octets.
    token_bytes: usize = constants.token_bytes_default,
};

/// What a route keeps in its request's entry of the router pool. The request and the reply each
/// have their own areas, so a response may point into its request.
pub fn CallState(comptime options: Options) type {
    return struct {
        accepted: ?connect.server.Accepted = null,
        done: bool = false,
        request_message: [options.message_bytes]u8 = undefined,
        request_work: [options.message_bytes]u8 = undefined,
        tokens: [options.token_bytes]u8 = undefined,
        reply_message: [options.message_bytes]u8 = undefined,
        reply_work: [options.message_bytes]u8 = undefined,
        room: call_file.Room = .{},
    };
}

/// The codings a server uses, which the program keeps in a field `codings` of its context. A
/// context with no such field reads and writes uncompressed messages alone.
pub const Codings = struct {
    decoders: connect.Decoders = .{},
    encoder: ?*connect.GzipEncoder = null,
};

fn codings_of(app: anytype) Codings {
    const App = @TypeOf(app.*);
    if (comptime @hasField(App, "codings")) return app.codings;
    return .{};
}

/// The struct route of `method`, which calls `handler`. Its signature follows the stream type:
///
/// - unary: `fn (*App, *Call, *const Request, *Response) ?connect.RpcError`
/// - server stream: `fn (*App, *Call, *const Request, *Sender(Response)) ?connect.RpcError`
/// - client stream: `fn (*App, *Call, *Receiver(Request), *Response) ?connect.RpcError`
/// - bidirectional stream: `fn (*App, *Call, *Receiver(Request), *Sender(Response)) ?connect.RpcError`
///
/// A handler returns null for success, or the error the client reads.
pub fn Route(comptime App: type, comptime method: connect.Method, comptime handler: anytype, comptime options: Options) type {
    return struct {
        pub const State = CallState(options);

        pub fn on_request(app: *App, state: *@This().State, request: *const server.Request, _: void, _: void, response: *server.ResponseWriter) !void {
            const codings = codings_of(app);
            const decision = connect.server.accept(request.method, request.query, lookup_of(&request.headers), .{
                .stream_type = method.stream_type,
                .idempotency = method.idempotency,
                .decoders = codings.decoders,
                .can_compress = codings.encoder != null,
            });
            switch (decision) {
                .accepted => |accepted| {
                    state.accepted = accepted;
                    // A GET's message is in its query, which lives as long as this call.
                    if (accepted.query != null) return serve(app, state, "", response);
                },
                .refused => |refused| {
                    state.done = true;
                    return call_file.answer_refusal(refused, scratch_of(options, state, .reply), &state.room, response);
                },
            }
        }

        pub fn on_body(app: *App, state: *@This().State, body: *std.Io.Reader, response: *server.ResponseWriter) !void {
            if (state.done) return;
            return serve(app, state, body.buffered(), response);
        }

        fn serve(app: *App, state: *@This().State, body: []const u8, response: *server.ResponseWriter) !void {
            assert(!state.done);
            state.done = true;
            const codings = codings_of(app);
            const accepted = state.accepted.?;
            var call: call_file.Call = .{
                .reply = .{ .accepted = accepted, .scratch = scratch_of(options, state, .reply), .encoder = codings.encoder },
                .response = response,
                .room = &state.room,
            };
            var messages = connect.server.Messages.init(accepted, body, scratch_of(options, state, .request), codings.decoders);
            return call_file.dispatch(App, method, handler, app, &call, &messages);
        }
    };
}

const Side = enum { request, reply };

fn scratch_of(comptime options: Options, state: *CallState(options), side: Side) connect.Scratch {
    return switch (side) {
        .request => .{ .message = &state.request_message, .work = &state.request_work, .tokens = &state.tokens },
        .reply => .{ .message = &state.reply_message, .work = &state.reply_work, .tokens = &state.tokens },
    };
}

fn find_header(context: *const anyopaque, name: []const u8) ?[]const u8 {
    const headers: *const server.Headers = @ptrCast(@alignCast(context));
    const header = headers.find(name) orelse return null;
    return header.value;
}

/// A lookup over a request's headers.
pub fn lookup_of(headers: *const server.Headers) connect.Lookup {
    return .{ .context = headers, .find_fn = find_header };
}

/// The router entry that serves `method` as a POST, reading the whole body.
pub fn post(comptime App: type, comptime method: connect.Method, comptime handler: anytype, comptime options: Options) @TypeOf(.{ .post, method.path(), Route(App, method, handler, options), .{ .whole_body = true } }) {
    return .{ .post, comptime method.path(), Route(App, method, handler, options), .{ .whole_body = true } };
}

/// The router entry that serves `method` as a GET, for a method with no side effects (Connect
/// protocol, "Unary-Get-Request").
pub fn get(comptime App: type, comptime method: connect.Method, comptime handler: anytype, comptime options: Options) @TypeOf(.{ .get, method.path(), Route(App, method, handler, options), .{ .whole_body = true } }) {
    comptime assert(method.stream_type == .unary and method.idempotency == .no_side_effects);
    return .{ .get, comptime method.path(), Route(App, method, handler, options), .{ .whole_body = true } };
}
