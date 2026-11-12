//! A client call over colibri's `client.ConnectionPool`: a `connect.client.Request` written as a
//! `client.Request`, and the `client.Response` colibri fills read as a `connect.client.Response`
//! (design §7). colibri's client holds the response's headers and trailers apart (colibri decision
//! 152), so a client call speaks Connect, gRPC-Web and gRPC (decision 11).
//!
//! A call `init` builds sends its messages in one body. A client or bidirectional stream that
//! `init_stream` builds streams both bodies through the pool (colibri decision 153): its `Sender`
//! writes each message as a piece, and the program reads each answer as its piece arrives, over
//! h2 and h3 while it still sends (decision 18 as amended).
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const client = @import("client");
const http = @import("http");
const client_stream = @import("client_stream.zig");
const constants = @import("constants.zig");

pub const Buffers = struct {
    /// The request: its body, the encoding work and the header values.
    request: connect.client.Buffers,
    /// The response's header section and trailer section, each line's name and value and four
    /// octets (colibri decision 152). A section longer than its buffer ends the call
    /// resource_exhausted. gRPC sends its status in the trailers (PROTOCOL-HTTP2.md, "Responses").
    headers: []u8,
    trailers: []u8,
    /// The response body. A streamed call gathers its response's pieces here: it holds the
    /// longest envelope the call reads and one piece more.
    body: []u8,
    /// Where colibri writes each piece of a streamed response, which the call copies into `body`
    /// and gives back at once. Empty for a call whose response comes whole.
    piece: []u8 = &.{},
};

/// What a client call is built with.
pub const Options = struct {
    /// The interceptors that see each request before it goes and each response once it is
    /// read. A client interceptor is a type with any of:
    ///
    /// - `on_request(*connect.client.Request) !void`, which may add headers with `add_header`;
    /// - `on_response(*connect.client.Response) void`, which sees each response before the
    ///   program reads its messages: its HTTP status and headers. A stream's outcome follows its
    ///   messages, so `failure` is set here only when the head alone carries it.
    ///
    /// `on_request` runs in the order the list names the interceptors, and `on_response` in the
    /// reverse. A streamed call runs `on_request` in `init_stream`, before any message, so the
    /// request it sees has an empty body. It runs `on_response` once, in `on_headers`, or in
    /// `read` when the call ended before its response's head.
    interceptors: []const type = &.{},
    /// The pool a call's `start` hands it to, which a streamed call hands its pieces to.
    pool: type = client.ConnectionPool(.{}),
};

/// What a streamed call's `send`, `close_send` and `on_body_taken` return: an encoding that
/// failed, or a piece the pool refused. `PieceHeld` says the message did not fit after the piece
/// the pool holds; it fits once the `body_taken` event arrives. `BodyEnded` says `close_send` ran.
pub const SendError = connect.client.RequestError || client.WriteBodyError;

/// One call of `method`. The program keeps it in place from `init` until colibri's `finished`
/// event for its request, since colibri reads `request` and writes `response` until then.
pub fn ClientCall(comptime method: connect.Method, comptime call_options: Options) type {
    const interceptors = call_options.interceptors;
    return struct {
        const Self = @This();

        options: connect.client.Options,
        call: connect.client.Request,
        fields: [connect.client.request_headers_max]http.Field,
        /// The names of `fields` that `init` wrote in lowercase.
        names: [constants.client_header_name_bytes]u8 = undefined,
        request: client.Request,
        response: client.Response,
        /// The pool `start` handed the call to, and the id it gave.
        pool: *call_options.pool = undefined,
        id: client.RequestId = undefined,
        /// A streamed call's bodies, and the reader of its response from its head on.
        streamed: bool = false,
        outgoing: client_stream.Outgoing = .{},
        incoming: client_stream.Incoming = .{},
        work: []u8 = &.{},
        reader: connect.client.Response = undefined,

        /// Writes the messages of a streamed call's request, as the server's `ResponseStream`
        /// sends a stream's replies. Each one goes to the pool at once, or with the next
        /// `body_taken` event while the pool still holds the piece before it.
        pub const Sender = struct {
            call: *Self,

            pub fn send(stream: *Sender, message: *const method.Request) SendError!void {
                return client_stream.send(method.Request, stream.call, message);
            }

            /// Ends the request stream: the last piece says so, at once or with the next
            /// `body_taken` event.
            pub fn close_send(stream: *Sender) SendError!void {
                return client_stream.close_send(stream.call);
            }
        };

        /// Builds the request of a call that sends `messages`. Each header name goes to colibri
        /// in lowercase, the program's and its interceptors' included.
        pub fn init(self: *Self, options: *const connect.client.Options, messages: []const method.Request, buffers: *const Buffers) connect.client.RequestError!void {
            self.streamed = false;
            self.options = options.*;
            self.call = try connect.client.request(method, options, messages, &buffers.request);
            try run_on_request(interceptors, &self.call);
            self.request = .{
                .method = self.call.http_method,
                .path = self.call.target,
                .headers = try fields_of(self.call.headers(), &self.fields, &self.names),
                .body = self.call.body,
            };
            self.response = .{
                .headers = .{ .buffer = buffers.headers },
                .trailers = .{ .buffer = buffers.trailers },
                .body = buffers.body,
            };
        }

        /// Builds the request of a client or bidirectional stream whose messages its `Sender`
        /// writes, and whose response arrives in pieces in `buffers.piece`.
        pub fn init_stream(self: *Self, options: *const connect.client.Options, buffers: *const Buffers) connect.client.RequestError!void {
            comptime assert(method.stream_type == .client_stream or method.stream_type == .bidi_stream);
            assert(buffers.piece.len > 0);
            try self.init(options, &.{}, buffers);
            self.streamed = true;
            // Colibri decision 153 ruling 7: both bodies go in pieces, and with no length stated
            // h2 and h3 end the request with its stream (RFC 9113 §8.1, RFC 9114 §4.1).
            self.request.streamed = .{ .request = true, .response = true };
            self.response.body = buffers.piece;
            self.outgoing = .{ .room = buffers.request.body };
            self.incoming = .{ .body = buffers.body };
            self.work = buffers.request.scratch.work;
        }

        /// Hands the call to `pool`, and keeps the id it gives. The call stays in place until
        /// the pool reports it `finished`.
        pub fn start(self: *Self, pool: *call_options.pool) client.RequestError!void {
            self.id = try pool.request(&self.request, &self.response);
            self.pool = pool;
        }

        /// The writer of a streamed call's request messages.
        pub fn sender(self: *Self) Sender {
            assert(self.streamed);
            return .{ .call = self };
        }

        /// The pool's `body_taken` event for the call: the next piece goes.
        pub fn on_body_taken(self: *Self) SendError!void {
            return client_stream.on_body_taken(self);
        }

        /// The pool's `headers` event for a streamed call: the response's status and headers
        /// arrived. The interceptors' `on_response` runs, and `reader` then reads each message
        /// as its piece arrives, with `storage`, which the call keeps until it ends.
        pub fn on_headers(self: *Self, storage: connect.client.Storage) void {
            assert(self.streamed and !self.incoming.headers_seen);
            self.incoming.headers_seen = true;
            self.reader = connect.client.Response.init(self.call.speaks, &incoming_of(self, ""), &storage, &self.options.decoders);
            run_on_response(interceptors, &self.reader);
        }

        /// The pool's `body` event for a streamed call: the piece of `len` octets is copied after
        /// what `reader` has not read, and goes back to the pool. A message `reader.next`
        /// returned before it stays valid until the next `on_body`. An envelope longer than
        /// `Buffers.body` holds fails the call `resource_exhausted`, and the rest is dropped.
        pub fn on_body(self: *Self, len: usize) void {
            client_stream.on_body(self, len);
        }

        /// Reads the response once colibri reported the call `finished`. A streamed call's
        /// reader goes on from the messages `on_body` passed, and reads the outcome.
        pub fn read(self: *const Self, storage: connect.client.Storage) connect.client.Response {
            if (self.streamed and self.incoming.headers_seen) return client_stream.read(self);
            var response = read_response(self, storage);
            run_on_response(interceptors, &response);
            return response;
        }

        fn find(context: *const anyopaque, name: []const u8) ?[]const u8 {
            const self: *const Self = @ptrCast(@alignCast(context));
            return self.response.headers.get(name);
        }

        fn find_trailer(context: *const anyopaque, name: []const u8) ?[]const u8 {
            const self: *const Self = @ptrCast(@alignCast(context));
            return self.response.trailers.get(name);
        }
    };
}

/// Copies `headers` into colibri's `fields`, each name in lowercase. h2 and h3 carry field names
/// in lowercase alone (RFC 9113 §8.2.1, RFC 9114 §4.2), and colibri refuses another, while names
/// compare without case (RFC 9110 §5.1). A name with an uppercase letter is written in lowercase
/// into `names`; one in lowercase is used as it is.
fn fields_of(headers: []const connect.Header, fields: []http.Field, names: []u8) error{NoSpaceLeft}![]const http.Field {
    assert(headers.len <= fields.len);
    var names_len: usize = 0;
    for (headers, fields[0..headers.len]) |header, *field| {
        var name = header.name;
        if (has_uppercase(name)) {
            if (name.len > names.len - names_len) return error.NoSpaceLeft;
            name = std.ascii.lowerString(names[names_len..][0..name.len], name);
            names_len += name.len;
        }
        field.* = .{ .name = name, .value = header.value };
    }
    return fields[0..headers.len];
}

fn has_uppercase(name: []const u8) bool {
    for (name) |octet| {
        if (std.ascii.isUpper(octet)) return true;
    }
    return false;
}

fn run_on_request(comptime interceptors: []const type, request: *connect.client.Request) !void {
    inline for (interceptors) |Interceptor| {
        if (comptime @hasDecl(Interceptor, "on_request")) try Interceptor.on_request(request);
    }
}

fn run_on_response(comptime interceptors: []const type, response: *connect.client.Response) void {
    inline for (0..interceptors.len) |index| {
        const Interceptor = interceptors[interceptors.len - 1 - index];
        if (comptime @hasDecl(Interceptor, "on_response")) Interceptor.on_response(response);
    }
}

/// Reads the response of a client call once colibri reported it `finished`.
fn read_response(self: anytype, storage: connect.client.Storage) connect.client.Response {
    const Self = @TypeOf(self.*);
    const speaks = self.call.speaks;
    const lookup: connect.Lookup = .{ .context = self, .find_fn = Self.find };
    // A streamed call whose response arrived passed its head to `on_headers` first, as colibri
    // reports it (colibri decision 153 ruling 7).
    assert(!self.streamed or self.response.result != .response);
    if (self.response.result != .response) {
        var response = connect.client.Response.init(speaks, &.{ .status = connect.constants.protocol.status.ok, .headers = lookup, .body = "" }, &storage, &self.options.decoders);
        response.done = true;
        response.failure = failure_of(self.response.result);
        return response;
    }
    return connect.client.Response.init(speaks, &incoming_of(self, self.response.body[0..self.response.body_len]), &storage, &self.options.decoders);
}

/// What `connect.client.Response` reads of a call's response: its status, its headers, and its
/// body or none, for a streamed body that arrives in pieces.
fn incoming_of(self: anytype, body: []const u8) connect.client.Incoming {
    const Self = @TypeOf(self.*);
    return .{
        .status = @intFromEnum(self.response.status),
        .headers = .{ .context = self, .find_fn = Self.find },
        .body = body,
        // gRPC's status and its call's trailers come in HTTP trailers after the last message
        // (PROTOCOL-HTTP2.md, "Responses"). Connect and gRPC-Web carry theirs in the body.
        .trailers = if (self.call.speaks.protocol == .grpc) .{ .context = self, .find_fn = Self.find_trailer } else null,
        .streamed = self.streamed,
    };
}

/// The error a client gives a call that ended with no whole response.
pub fn failure_of(result: client.Result) connect.RpcError {
    assert(result != .response);
    return switch (result) {
        .pending, .response => unreachable,
        // The server processed none of it, so the call may be sent again.
        .refused => .{ .code = .unavailable, .message = "the server refused the stream" },
        .reset, .closed => .{ .code = .unavailable, .message = "the connection ended before the response" },
        .malformed => .{ .code = .internal, .message = "malformed HTTP response" },
        .invalid => .{ .code = .internal, .message = "the HTTP client refused the request" },
        .too_large => .{ .code = .resource_exhausted, .message = "the response did not fit the client's buffers" },
    };
}

test "a request's header names go to colibri in lowercase, and lowercase ones as they are" {
    const headers = [_]connect.Header{
        .{ .name = "content-type", .value = "application/proto" },
        .{ .name = "X-Test-Case", .value = "A" },
        .{ .name = "AUTHORIZATION", .value = "Bearer t" },
    };
    var fields: [headers.len]http.Field = undefined;
    var names: [constants.client_header_name_bytes]u8 = undefined;
    const written = try fields_of(&headers, &fields, &names);
    try std.testing.expectEqualStrings("x-test-case", written[1].name);
    try std.testing.expectEqualStrings("authorization", written[2].name);
    // The value keeps its case, and a lowercase name is the program's own octets.
    try std.testing.expectEqualStrings("A", written[1].value);
    try std.testing.expectEqual(headers[0].name.ptr, written[0].name.ptr);
    try std.testing.expectError(error.NoSpaceLeft, fields_of(&headers, &fields, names[0.."x-test-case".len]));
}
