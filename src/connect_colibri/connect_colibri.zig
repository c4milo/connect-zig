//! connect_colibri: Connect, gRPC and gRPC-Web servers and clients over colibri's h11, h2 and h3
//! (design §7). A server serves each `connect.Method` as a route of `server.Router`; a client
//! writes each call as a `client.Request` for its `client.ConnectionPool`.
const std = @import("std");

pub const constants = @import("constants.zig");

const files = struct {
    pub const route = @import("route.zig");
    pub const route_app = @import("route_app.zig");
    pub const refusal = @import("refusal.zig");
    pub const call = @import("call.zig");
    pub const context = @import("context.zig");
    pub const client_call = @import("client_call.zig");
    pub const client_stream = @import("client_stream.zig");
    pub const dispatch = @import("dispatch.zig");
    pub const pull = @import("pull.zig");
};

/// The struct route that serves a method, and its router entries.
pub const Route = files.route.Route;
pub const RouteOptions = files.route.Options;
pub const Codings = files.route_app.Codings;
pub const post = files.route.post;
pub const get = files.route.get;
/// The router entries that answer 405 for the HTTP methods Connect does not serve.
pub const Refusals = files.refusal.Refusals;
/// What a handler and an interceptor read and write of a call: the call's context, its request
/// and its response (decision 36).
pub const Context = files.context.Context;
pub const Request = files.context.Request;
pub const RequestStream = files.context.RequestStream;
pub const Response = files.context.Response;
pub const ResponseStream = files.context.ResponseStream;
pub const AnyRequest = files.context.AnyRequest;
pub const AnyResponse = files.context.AnyResponse;
/// What a type handler's `next` answers when its route asks for the stream's next message.
pub const Next = files.pull.Next;
/// A client call over colibri's pool.
pub const ClientCall = files.client_call.ClientCall;
pub const ClientCallOptions = files.client_call.Options;
pub const ClientCallBuffers = files.client_call.Buffers;
pub const failure_of = files.client_call.failure_of;
/// What a streamed call's `Sender` returns, and whether a stream over a protocol is full-duplex.
pub const ClientSendError = files.client_call.SendError;
pub const full_duplex = files.client_stream.full_duplex;

test "the root exports the names a program calls" {
    try @import("public_names").expect(@This(), &.{
        "constants",       "Route",       "RouteOptions", "Codings",           "post",              "get",
        "Refusals",        "Context",     "Request",      "RequestStream",     "Response",          "ResponseStream",
        "AnyRequest",      "AnyResponse", "ClientCall",   "ClientCallOptions", "ClientCallBuffers", "failure_of",
        "ClientSendError", "full_duplex", "Next",
    });
}

test {
    std.testing.refAllDecls(files);
    _ = @import("connect_colibri_test.zig");
    _ = @import("client_stream_test.zig");
    _ = @import("pull_test.zig");
    _ = @import("values_test.zig");
    _ = @import("context_test.zig");
    _ = @import("message_hook_test.zig");
    _ = @import("route_app_test.zig");
}
