//! What a handler and an interceptor read and write of one call (decision 36), as connect-go
//! splits a call into a context, a request and a response:
//!
//! - `Context`: the call itself, its path, protocol, codec and timeout, and the program's values
//!   for it (decision 35);
//! - `Request(T)` and `RequestStream(T)`: the request's messages, headers and query;
//! - `Response(T)` and `ResponseStream(T)`: the response's messages, headers and trailers;
//! - `AnyRequest` and `AnyResponse`: the request and the response with no message, which an
//!   interceptor takes.
//!
//! Each is a view of the call the route keeps, valid during the callback that receives it.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const call_file = @import("call.zig");
const Call = call_file.Call;

/// The call: what it is, and the program's values for it.
pub const Context = struct {
    call: *Call,

    /// The path that names the method: "/connectrpc.eliza.v1.ElizaService/Say".
    pub fn path(ctx: *const Context) []const u8 {
        return ctx.call.path;
    }

    /// The protocol the request spoke.
    pub fn protocol(ctx: *const Context) connect.Protocol {
        return ctx.call.protocol();
    }

    /// The codec the request spoke.
    pub fn codec(ctx: *const Context) connect.Codec {
        return ctx.call.codec();
    }

    /// The timeout the client asked for, in nanoseconds. The program turns it into a deadline
    /// with its own clock (decision 3).
    pub fn timeout_ns(ctx: *const Context) ?u64 {
        return ctx.call.timeout_ns();
    }

    /// The messages the call read so far.
    pub fn received(ctx: *const Context) u32 {
        return ctx.call.received;
    }

    /// The messages the call wrote so far.
    pub fn sent(ctx: *const Context) u32 {
        return ctx.call.sent;
    }

    /// The program's values for this call, of the type `RouteOptions.Values` names (decision
    /// 35). Every call starts with `.{}`, and the values last as long as the call: each callback
    /// of a stream reads the same ones.
    pub fn values(ctx: *const Context, comptime Values: type) *Values {
        return ctx.call.values(Values);
    }
};

/// The request with no message: its headers and its query.
pub const AnyRequest = struct {
    call: *Call,

    /// A request header's value, by a name in any case, or null.
    pub fn header(request: *const AnyRequest, name: []const u8) ?[]const u8 {
        return request.call.request_header(name);
    }

    /// The request's headers, every line in the order it arrived. A name may repeat.
    pub fn headers(request: *const AnyRequest) []const connect.Header {
        return request.call.request_headers();
    }

    /// The request's query, after the path's "?", or empty: a unary GET's parameters (Connect
    /// protocol, "Unary-Get-Request").
    pub fn query(request: *const AnyRequest) []const u8 {
        return request.call.query;
    }
};

pub const HeaderError = error{ TooManyHeaders, HeadSent, InvalidField };
pub const TrailerError = error{ TooManyTrailers, InvalidField };

/// The response with no message: what adds its headers and its trailers.
pub const AnyResponse = struct {
    call: *Call,

    /// Adds a response header. It goes out with the response's head, so a handler adds it
    /// before it sends its first message.
    pub fn add_header(response: *AnyResponse, name: []const u8, value: []const u8) HeaderError!void {
        return response.call.add_header(name, value);
    }

    /// Adds a trailer: in the end-stream message, gRPC's trailers or gRPC-Web's trailers
    /// frame, and for a Connect unary response in a header "trailer-<name>" (Connect protocol,
    /// "Unary-Response").
    pub fn add_trailer(response: *AnyResponse, name: []const u8, value: []const u8) TrailerError!void {
        return response.call.add_trailer(name, value);
    }
};

/// A request of one message: a unary call's, or a server stream's.
pub fn Request(comptime T: type) type {
    return struct {
        /// The message. Its strings and bytes point into the request body, which lasts until
        /// the callback returns.
        message: T,
        any: AnyRequest,

        pub fn header(request: *const @This(), name: []const u8) ?[]const u8 {
            return request.any.header(name);
        }

        pub fn headers(request: *const @This()) []const connect.Header {
            return request.any.headers();
        }

        pub fn query(request: *const @This()) []const u8 {
            return request.any.query();
        }
    };
}

/// A request of a stream of messages, which a function handler of a client or bidirectional
/// stream reads whole. A message that does not decode ends the stream, and the call then fails
/// with `failure`.
pub fn RequestStream(comptime T: type) type {
    return struct {
        messages: *connect.server.Messages,
        any: AnyRequest,
        failure: ?connect.RpcError = null,

        /// The next message, or null at the stream's end.
        pub fn next(stream: *@This()) ?T {
            const message = stream.messages.next(T) catch |failure| {
                stream.failure = connect.server.failure_of(failure);
                return null;
            };
            if (message != null) stream.any.call.received += 1;
            return message;
        }

        pub fn header(stream: *const @This(), name: []const u8) ?[]const u8 {
            return stream.any.header(name);
        }

        pub fn headers(stream: *const @This()) []const connect.Header {
            return stream.any.headers();
        }

        pub fn query(stream: *const @This()) []const u8 {
            return stream.any.query();
        }
    };
}

/// A response of one message, which the handler fills: a unary call's, a client stream's, or
/// one message of a stream a handler with `next` gives.
pub fn Response(comptime T: type) type {
    return struct {
        message: T = .{},
        any: AnyResponse,

        pub fn add_header(response: *@This(), name: []const u8, value: []const u8) HeaderError!void {
            return response.any.add_header(name, value);
        }

        pub fn add_trailer(response: *@This(), name: []const u8, value: []const u8) TrailerError!void {
            return response.any.add_trailer(name, value);
        }
    };
}

/// A response of a stream of messages: each message goes out as it is sent, so a client reads
/// it before the stream ends.
pub fn ResponseStream(comptime T: type) type {
    return struct {
        any: AnyResponse,

        pub fn send(stream: *@This(), message: *const T) !void {
            return call_file.send_message(T, stream.any.call, message);
        }

        pub fn add_header(stream: *@This(), name: []const u8, value: []const u8) HeaderError!void {
            return stream.any.add_header(name, value);
        }

        pub fn add_trailer(stream: *@This(), name: []const u8, value: []const u8) TrailerError!void {
            return stream.any.add_trailer(name, value);
        }
    };
}

comptime {
    // A view holds the call alone, so a callback's views cost a pointer each.
    assert(@sizeOf(Context) == @sizeOf(*Call));
}
