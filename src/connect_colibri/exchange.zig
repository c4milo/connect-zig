//! A client call over colibri's `client.ConnectionPool`: a `connect.client.Request` written as a
//! `client.Request`, and the `client.Response` colibri fills read as a `connect.client.Response`
//! (design §7). colibri's client sends whole bodies and exposes no trailers, so it speaks Connect
//! and gRPC-Web, and plain gRPC only when the server answers Trailers-Only (decision 11).
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const client = @import("client");
const http = @import("http");

/// The response headers a client reads.
pub const wanted_names = [_][]const u8{
    "content-type",
    "content-encoding",
    "connect-content-encoding",
    "grpc-encoding",
    "grpc-status",
    "grpc-message",
    "grpc-status-details-bin",
};

pub const Buffers = struct {
    /// The request: its body, the encoding work and the header values.
    request: connect.client.Buffers,
    /// The values of the response headers in `wanted_names`.
    values: []u8,
    /// The response body.
    body: []u8,
};

/// One call of `method`. The program keeps it in place from `init` until colibri's `finished`
/// event for its request, since colibri reads `request` and writes `response` until then.
pub fn Exchange(comptime method: connect.Method) type {
    return ExchangeWith(method, &.{});
}

/// An `Exchange` whose interceptors see each request before it goes and each response once it
/// is read. A client interceptor is a type with any of:
///
/// - `on_request(*connect.client.Request) !void`, which may add headers with `add_header`;
/// - `on_response(*connect.client.Response) void`, which sees each response before the program
///   reads its messages: its HTTP status and headers. A stream's outcome follows its messages,
///   so `failure` is set here only when the head alone carries it.
///
/// `on_request` runs in the order the list names the interceptors, and `on_response` in the
/// reverse.
pub fn ExchangeWith(comptime method: connect.Method, comptime interceptors: []const type) type {
    return struct {
        const Self = @This();

        options: connect.client.Options,
        call: connect.client.Request,
        fields: [connect.client.request_headers_max]http.Field,
        request: client.Request,
        wanted: [wanted_names.len]client.WantedHeader,
        response: client.Response,

        /// Builds the request of a call that sends `messages`.
        pub fn init(self: *Self, options: connect.client.Options, messages: []const method.Request, buffers: Buffers) connect.client.RequestError!void {
            self.options = options;
            self.call = try connect.client.request(method, options, messages, buffers.request);
            try run_on_request(interceptors, &self.call);
            const headers = self.call.headers();
            for (headers, 0..) |header, index| self.fields[index] = .{ .name = header.name, .value = header.value };
            self.request = .{
                .method = self.call.http_method,
                .path = self.call.target,
                .headers = self.fields[0..headers.len],
                .body = self.call.body,
            };
            for (&self.wanted, wanted_names) |*wanted, name| wanted.* = .{ .name = name };
            self.response = .{ .wanted = &self.wanted, .values = buffers.values, .body = buffers.body };
        }

        /// Reads the response once colibri reported the exchange `finished`.
        pub fn read(self: *const Self, storage: connect.client.Storage) connect.client.Response {
            var response = read_response(self, storage);
            run_on_response(interceptors, &response);
            return response;
        }

        fn find(context: *const anyopaque, name: []const u8) ?[]const u8 {
            const self: *const Self = @ptrCast(@alignCast(context));
            return find_wanted(&self.wanted, name);
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

fn find_wanted(wanted: []const client.WantedHeader, name: []const u8) ?[]const u8 {
    for (wanted) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }
    return null;
}

/// Reads the response of an exchange once colibri reported it `finished`.
fn read_response(self: anytype, storage: connect.client.Storage) connect.client.Response {
    const Self = @TypeOf(self.*);
    const speaks = self.call.speaks;
    const lookup: connect.Lookup = .{ .context = self, .find_fn = Self.find };
    if (self.response.result != .response) {
        var response = connect.client.read(speaks, .{ .status = connect.constants.protocol.status.ok, .headers = lookup, .body = "" }, storage, self.options.decoders);
        response.done = true;
        response.failure = failure_of(self.response.result);
        return response;
    }
    const incoming: connect.client.Incoming = .{
        .status = self.response.status,
        .headers = lookup,
        .body = self.response.body[0..self.response.body_len],
    };
    return connect.client.read(speaks, incoming, storage, self.options.decoders);
}

/// The error a client gives an exchange that ended with no whole response.
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
