//! What generated code names for each RPC: its service, its method, its message types, its
//! stream type and its idempotency, and the path a request names it by (Connect protocol,
//! "Unary-Request": the path is "/" Service-Name "/" Method-Name).
const std = @import("std");

pub const StreamType = enum {
    unary,
    client_stream,
    server_stream,
    bidi_stream,

    /// Whether the Connect protocol frames the body in envelopes.
    pub fn enveloped(stream_type: StreamType) bool {
        return stream_type != .unary;
    }
};

/// descriptor.proto's MethodOptions.IdempotencyLevel.
pub const Idempotency = enum {
    unknown,
    /// NO_SIDE_EFFECTS: a Connect client may send it as a GET (Connect protocol, "Unary-Get-Request").
    no_side_effects,
    idempotent,
};

pub const Method = struct {
    /// The service's full name, "connectrpc.eliza.v1.ElizaService".
    service: []const u8,
    /// The method's name, "Say".
    name: []const u8,
    Request: type,
    Response: type,
    stream_type: StreamType,
    idempotency: Idempotency = .unknown,

    /// The path, "/connectrpc.eliza.v1.ElizaService/Say".
    pub fn path(comptime method: Method) []const u8 {
        return "/" ++ method.service ++ "/" ++ method.name;
    }
};

test "a method's path joins its service and its name" {
    const Empty = struct {};
    const say: Method = .{ .service = "a.v1.Svc", .name = "Say", .Request = Empty, .Response = Empty, .stream_type = .unary };
    try std.testing.expectEqualStrings("/a.v1.Svc/Say", comptime say.path());
    try std.testing.expect(StreamType.bidi_stream.enveloped());
}
