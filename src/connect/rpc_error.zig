//! An RPC's error as every protocol here carries it: a code, a message and details. A detail is
//! a protobuf message, named by its full name and held encoded (Connect protocol, "Error End-Stream";
//! google/rpc/status.proto).
const std = @import("std");
const proto = @import("protobuf");
const code_file = @import("code.zig");
const constants = @import("constants.zig");
const Code = code_file.Code;

/// One header or trailer: a name and a value, as an HTTP library passes them.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Detail = struct {
    /// The message's full name, "google.rpc.ErrorInfo", without Any's "type.googleapis.com/".
    type_name: []const u8,
    /// The message's binary encoding.
    value: []const u8,
};

pub const RpcError = struct {
    code: Code,
    message: []const u8 = "",
    details: []const Detail = &.{},
};

/// The prefix of an Any's type URL (google/protobuf/any.proto).
pub const type_url_prefix = "type.googleapis.com/";

/// google.rpc.Status, the message grpc-status-details-bin carries (google/rpc/status.proto).
pub const Status = struct {
    code: i32 = 0,
    message: []const u8 = "",
    details: proto.Repeated(proto.wkt.Any, .message) = .{},
    pub const protobuf: proto.Descriptor = .{ .full_name = "google.rpc.Status", .fields = &.{
        .{ .name = "code", .number = 1, .kind = .int32, .json_name = "code", .proto_name = "code" },
        .{ .name = "message", .number = 2, .kind = .string, .json_name = "message", .proto_name = "message" },
        .{ .name = "details", .number = 3, .kind = .message, .json_name = "details", .proto_name = "details" },
    } };
};

/// Encodes an error as a google.rpc.Status into `buffer`. `type_urls` holds each detail's type
/// URL while the encoding runs.
pub fn encode_status(failure: RpcError, buffer: []u8, type_urls: []u8) (proto.EncodeError || error{TooManyDetails})![]u8 {
    if (failure.details.len > constants.limits.details_max) return error.TooManyDetails;
    var anys: [constants.limits.details_max]proto.wkt.Any = undefined;
    var used: usize = 0;
    for (failure.details, 0..) |detail, index| {
        const len = type_url_prefix.len + detail.type_name.len;
        if (used + len > type_urls.len) return error.NoSpaceLeft;
        const url = type_urls[used..][0..len];
        @memcpy(url[0..type_url_prefix.len], type_url_prefix);
        @memcpy(url[type_url_prefix.len..], detail.type_name);
        used += len;
        anys[index] = .{ .type_url = url, .value = detail.value };
    }
    const status: Status = .{
        .code = @intFromEnum(failure.code),
        .message = failure.message,
        .details = .of(anys[0..failure.details.len]),
    };
    return proto.encode(Status, &status, buffer);
}

/// Reads a google.rpc.Status into an error whose details go into `details`. Slices point into
/// `bytes`.
pub fn decode_status(bytes: []const u8, details: []Detail) (proto.Error || error{TooManyDetails})!RpcError {
    const status = try proto.decode(Status, bytes);
    var anys = status.details.iterator();
    var count: usize = 0;
    for (0..constants.limits.details_max + 1) |_| {
        const any = try anys.next() orelse break;
        if (count == details.len) return error.TooManyDetails;
        details[count] = .{ .type_name = strip_type_url(any.type_url), .value = any.value };
        count += 1;
    }
    const code = code_file.Code.from_number(@as(u32, @bitCast(status.code)));
    return .{ .code = code, .message = status.message, .details = details[0..count] };
}

/// The full name an Any's type URL names: what follows its last "/".
pub fn strip_type_url(url: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return url;
    return url[slash + 1 ..];
}

const testing = std.testing;

test "an error round-trips through google.rpc.Status" {
    const failure: RpcError = .{
        .code = .not_found,
        .message = "no such user",
        .details = &.{.{ .type_name = "google.rpc.ErrorInfo", .value = &.{ 0x0a, 0x01, 'x' } }},
    };
    var buffer: [128]u8 = undefined;
    var urls: [64]u8 = undefined;
    const bytes = try encode_status(failure, &buffer, &urls);
    var details: [4]Detail = undefined;
    const back = try decode_status(bytes, &details);
    try testing.expectEqual(Code.not_found, back.code);
    try testing.expectEqualStrings("no such user", back.message);
    try testing.expectEqualStrings("google.rpc.ErrorInfo", back.details[0].type_name);
    try testing.expectEqualSlices(u8, failure.details[0].value, back.details[0].value);
}
