//! A client call over colibri's `client.ConnectionPool`: a `connect.client.Request` written as a
//! `client.Request`, and the `client.Response` colibri fills read as a `connect.client.Response`
//! (design §7). colibri's client holds the response's headers and trailers apart (colibri decision
//! 152), so a client call speaks Connect, gRPC-Web and gRPC (decision 11). It sends each request
//! body whole, so a client stream is half-duplex.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const client = @import("client");
const http = @import("http");

pub const Buffers = struct {
    /// The request: its body, the encoding work and the header values.
    request: connect.client.Buffers,
    /// The response's header section and trailer section, each line's name and value and four
    /// octets (colibri decision 152). A section longer than its buffer ends the call
    /// resource_exhausted. gRPC sends its status in the trailers (PROTOCOL-HTTP2.md, "Responses").
    headers: []u8,
    trailers: []u8,
    /// The response body.
    body: []u8,
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
    /// reverse.
    interceptors: []const type = &.{},
};

/// One call of `method`. The program keeps it in place from `init` until colibri's `finished`
/// event for its request, since colibri reads `request` and writes `response` until then.
pub fn ClientCall(comptime method: connect.Method, comptime call_options: Options) type {
    const interceptors = call_options.interceptors;
    return struct {
        const Self = @This();

        options: connect.client.Options,
        call: connect.client.Request,
        fields: [connect.client.request_headers_max]http.Field,
        request: client.Request,
        response: client.Response,

        /// Builds the request of a call that sends `messages`.
        pub fn init(self: *Self, options: *const connect.client.Options, messages: []const method.Request, buffers: *const Buffers) connect.client.RequestError!void {
            self.options = options.*;
            self.call = try connect.client.request(method, options, messages, &buffers.request);
            try run_on_request(interceptors, &self.call);
            const headers = self.call.headers();
            for (headers, 0..) |header, index| self.fields[index] = .{ .name = header.name, .value = header.value };
            self.request = .{
                .method = self.call.http_method,
                .path = self.call.target,
                .headers = self.fields[0..headers.len],
                .body = self.call.body,
            };
            self.response = .{
                .headers = .{ .buffer = buffers.headers },
                .trailers = .{ .buffer = buffers.trailers },
                .body = buffers.body,
            };
        }

        /// Reads the response once colibri reported the call `finished`.
        pub fn read(self: *const Self, storage: connect.client.Storage) connect.client.Response {
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
    if (self.response.result != .response) {
        var response = connect.client.Response.init(speaks, &.{ .status = connect.constants.protocol.status.ok, .headers = lookup, .body = "" }, &storage, &self.options.decoders);
        response.done = true;
        response.failure = failure_of(self.response.result);
        return response;
    }
    const incoming: connect.client.Incoming = .{
        .status = self.response.status,
        .headers = lookup,
        .body = self.response.body[0..self.response.body_len],
        // gRPC's status and its call's trailers come in HTTP trailers after the last message
        // (PROTOCOL-HTTP2.md, "Responses"). Connect and gRPC-Web carry theirs in the body.
        .trailers = if (speaks.protocol == .grpc) .{ .context = self, .find_fn = Self.find_trailer } else null,
    };
    return connect.client.Response.init(speaks, &incoming, &storage, &self.options.decoders);
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
