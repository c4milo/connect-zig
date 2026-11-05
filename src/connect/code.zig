//! The error codes Connect and gRPC share, their names, and their HTTP statuses (Connect
//! protocol, "Error Codes"; gRPC's statuscodes.md). `ok` is gRPC's code 0, which no Connect error
//! carries.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const status = constants.protocol.status;

/// Each tag is the code's Connect name, and each value its gRPC number.
pub const Code = enum(u8) {
    ok = 0,
    canceled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,

    /// The name a Connect error body carries.
    pub fn name(code: Code) []const u8 {
        return @tagName(code);
    }

    /// The code a Connect error body names, or null for a name no code has. A client reads an
    /// unknown name as `unknown` (Connect protocol, "Error Codes").
    pub fn from_name(text: []const u8) ?Code {
        return std.meta.stringToEnum(Code, text);
    }

    /// The code a gRPC number names. gRPC's statuscodes.md defines 0 to 16; a client reads any
    /// other as UNKNOWN.
    pub fn from_number(number: u64) Code {
        if (number > @intFromEnum(Code.unauthenticated)) return .unknown;
        return @enumFromInt(number);
    }

    /// The HTTP status of a Connect unary error (Connect protocol, "Error Codes" table).
    pub fn http_status(code: Code) u16 {
        assert(code != .ok);
        return switch (code) {
            .ok => unreachable,
            .canceled => constants.protocol.status_client_closed_request,
            .unknown, .internal, .data_loss => status.internal_server_error,
            .invalid_argument, .failed_precondition, .out_of_range => status.bad_request,
            .deadline_exceeded => status.gateway_timeout,
            .not_found => status.not_found,
            .already_exists, .aborted => status.conflict,
            .permission_denied => status.forbidden,
            .resource_exhausted => status.too_many_requests,
            .unimplemented => status.not_implemented,
            .unavailable => status.service_unavailable,
            .unauthenticated => status.unauthorized,
        };
    }

    /// The code a client gives a response whose HTTP status is not 200 and whose body is not a
    /// Connect error (Connect protocol, "HTTP to Error Code"; gRPC's http-grpc-status-mapping.md).
    pub fn from_http_status(http: u16) Code {
        assert(http != status.ok);
        return switch (http) {
            status.bad_request => .internal,
            status.unauthorized => .unauthenticated,
            status.forbidden => .permission_denied,
            status.not_found => .unimplemented,
            status.too_many_requests, status.bad_gateway, status.service_unavailable, status.gateway_timeout => .unavailable,
            else => .unknown,
        };
    }
};

const testing = std.testing;

test "the codes have gRPC's numbers and Connect's names" {
    try testing.expectEqual(@as(u8, 16), @intFromEnum(Code.unauthenticated));
    try testing.expectEqualStrings("invalid_argument", Code.invalid_argument.name());
    try testing.expectEqual(@as(?Code, .resource_exhausted), Code.from_name("resource_exhausted"));
    try testing.expectEqual(@as(?Code, null), Code.from_name("RESOURCE_EXHAUSTED"));
    try testing.expectEqual(Code.unknown, Code.from_number(17));
    try testing.expectEqual(Code.data_loss, Code.from_number(15));
}

test "each code has the HTTP status of the Connect table, and statuses map back" {
    const statuses = [_]u16{ 499, 500, 400, 504, 404, 409, 403, 429, 400, 409, 400, 501, 500, 503, 500, 401 };
    for (statuses, 1..) |expected, number| {
        try testing.expectEqual(expected, Code.from_number(number).http_status());
    }
    try testing.expectEqual(Code.internal, Code.from_http_status(400));
    try testing.expectEqual(Code.unimplemented, Code.from_http_status(404));
    try testing.expectEqual(Code.unavailable, Code.from_http_status(502));
    try testing.expectEqual(Code.unknown, Code.from_http_status(418));
}
