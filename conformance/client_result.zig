//! What the conformance client reports of one call: a ClientResponseResult, built as it goes, and
//! the ClientCompatResponse it ends in (docs/testing_clients.md in the conformance suite,
//! "Interacting with the test runner").
//!
//! Each payload is encoded as the call reads it, since the call's next message reuses the octets
//! it points into. The result is a run of ClientResponseResult encodings, which decode as their
//! merge: the repeated fields of each are appended ("Last One Wins", encoding guide).
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const proto = @import("protobuf");
const service = @import("connectrpc_conformance_v1_service");
const client_compat = @import("connectrpc_conformance_v1_client_compat");
const constants = @import("constants.zig");
const echo = @import("echo.zig");

/// A metadata section's groups and values, and an error's details as Anys with their type URLs,
/// which one case at a time writes.
var groups: [constants.client_fields_max]Header align(@alignOf(Header)) = undefined;
var values: [constants.client_fields_max][]const u8 align(@alignOf([]const u8)) = undefined;
var anys: [constants.client_details_max]Any align(@alignOf(Any)) = undefined;
var urls: [constants.client_details_max * constants.client_type_url_bytes]u8 = undefined;

const ResponseResult = client_compat.ClientResponseResult;
const Header = service.Header;
const Any = proto.wkt.Any;

/// The prefix of an Any's type URL (google/protobuf/any.proto).
const type_url_prefix = "type.googleapis.com/";

/// ClientCompatResponse's field `response`, and the parts of a tag (encoding guide, "Message
/// Structure"): the wire type takes the low three bits, and LEN is type 2.
const response_number: u64 = @intFromEnum(client_compat.ClientCompatResponse.FieldNumber.response);
const wire_type_bits = 3;
const wire_type_len: u64 = @intFromEnum(proto.WireType.len);
/// Encoding guide, "Base 128 Varints": seven bits of payload in each octet, and the high bit
/// says another follows.
const varint_payload_bits = 7;
const varint_continue: u8 = 0x80;
const varint_payload_mask: u64 = 0x7f;
const varint_len_max = 10;

fn write_varint(value: u64, room: []u8) proto.EncodeError!usize {
    var rest = value;
    for (0..varint_len_max) |index| {
        if (index == room.len) return error.NoSpaceLeft;
        const low: u8 = @intCast(rest & varint_payload_mask);
        rest >>= varint_payload_bits;
        if (rest == 0) {
            room[index] = low;
            return index + 1;
        }
        room[index] = low | varint_continue;
    }
    unreachable;
}

pub const Result = struct {
    bytes: []u8,
    len: usize = 0,
    /// The payloads written, which a cancel after a number of responses counts.
    payloads: u32 = 0,
    /// The error the call ended with, once it is known.
    failure: ?connect.RpcError = null,
    /// The requests a stream did not send, because the call ended first.
    unsent: i32 = 0,

    /// Appends `value` as one more ClientResponseResult encoding.
    fn append(result: *Result, value: *const ResponseResult) proto.EncodeError!void {
        const written = try proto.encode(ResponseResult, value, result.bytes[result.len..]);
        result.len += written.len;
    }

    /// Where the result stands, which `rewind` returns to.
    pub const Mark = struct { len: usize, payloads: u32 };

    pub fn mark(result: *const Result) Mark {
        return .{ .len = result.len, .payloads = result.payloads };
    }

    /// Drops what was recorded since `kept`.
    pub fn rewind(result: *Result, kept: Mark) void {
        assert(kept.len <= result.len and kept.payloads <= result.payloads);
        result.len = kept.len;
        result.payloads = kept.payloads;
    }

    /// Records one response message's payload. An empty response stands for an empty payload
    /// (docs/testing_clients.md, "Unary": "use an empty ConformancePayload").
    pub fn add_payload(result: *Result, payload: ?service.ConformancePayload) proto.EncodeError!void {
        const one = [1]service.ConformancePayload{payload orelse .{}};
        try result.append(&.{ .payloads = .of(&one) });
        result.payloads += 1;
    }

    /// Records a section of response metadata, grouped by name with each value in order.
    pub fn add_metadata(result: *Result, section: Section, lines: []const connect.Header) proto.EncodeError!void {
        if (lines.len == 0) return;
        const count = @min(lines.len, groups.len);
        const grouped = echo.group(lines[0..count], groups[0..count], values[0..count]);
        switch (section) {
            .headers => try result.append(&.{ .response_headers = .of(grouped) }),
            .trailers => try result.append(&.{ .response_trailers = .of(grouped) }),
        }
    }

    /// Writes the ClientCompatResponse of the call named `test_name` into `output`: its name, then
    /// the result as field `response`, whose octets are the run of encodings as they are. A
    /// header value need not be UTF-8, so the run is not decoded again.
    pub fn finish(result: *Result, test_name: []const u8, output: []u8) proto.EncodeError![]const u8 {
        try result.append_failure();
        if (result.unsent != 0) try result.append(&.{ .num_unsent_requests = result.unsent });
        const named: client_compat.ClientCompatResponse = .{ .test_name = test_name };
        const head = try proto.encode(client_compat.ClientCompatResponse, &named, output);
        var len = head.len;
        // Encoding guide, "Message Structure": a tag is the field number shifted left by three,
        // with the wire type; "Length-Delimited Records": a varint length, then the octets.
        len += try write_varint(response_number << wire_type_bits | wire_type_len, output[len..]);
        len += try write_varint(result.len, output[len..]);
        if (output.len - len < result.len) return error.NoSpaceLeft;
        @memcpy(output[len..][0..result.len], result.bytes[0..result.len]);
        return output[0 .. len + result.len];
    }

    /// The error as the conformance suite's Error: its code, its message, and each detail as an
    /// Any named by its full name.
    fn append_failure(result: *Result) proto.EncodeError!void {
        const failure = result.failure orelse return;
        const count = @min(failure.details.len, anys.len);
        for (failure.details[0..count], 0..) |detail, index| {
            const url = urls[index * constants.client_type_url_bytes ..][0..constants.client_type_url_bytes];
            anys[index] = .{ .type_url = type_url_of(detail.type_name, url), .value = detail.value };
        }
        // The suite's codes are gRPC's, number for number (config.proto, `Code`).
        const wanted: service.Error = .{ .code = @enumFromInt(@intFromEnum(failure.code)), .message = failure.message, .details = .of(anys[0..count]) };
        try result.append(&.{ .@"error" = wanted });
    }
};

pub const Section = enum { headers, trailers };

/// The type URL of the message `type_name` names, written into `room`; cut short when it does
/// not fit.
fn type_url_of(type_name: []const u8, room: []u8) []const u8 {
    assert(room.len > type_url_prefix.len);
    @memcpy(room[0..type_url_prefix.len], type_url_prefix);
    const name_len = @min(type_name.len, room.len - type_url_prefix.len);
    @memcpy(room[type_url_prefix.len..][0..name_len], type_name[0..name_len]);
    return room[0 .. type_url_prefix.len + name_len];
}

/// The ClientCompatResponse of a call the client could not make, named `test_name`, with the
/// reason (docs/testing_clients.md: "error ... is only used if something prevents your client
/// from invoking the RPC").
pub fn refusal(test_name: []const u8, reason: []const u8, output: []u8) proto.EncodeError![]const u8 {
    const response: client_compat.ClientCompatResponse = .{ .test_name = test_name, .result = .{ .@"error" = .{ .message = reason } } };
    return proto.encode(client_compat.ClientCompatResponse, &response, output);
}

const testing = std.testing;

test "payloads, metadata and an error merge into one result, with the test's name" {
    var room: [1024]u8 = undefined;
    var output: [1024]u8 = undefined;
    var result: Result = .{ .bytes = &room };
    try result.add_payload(.{ .data = "a" });
    try result.add_payload(null);
    try result.add_metadata(.trailers, &.{ .{ .name = "x-t", .value = "1" }, .{ .name = "X-T", .value = "2" } });
    result.failure = .{ .code = .canceled, .message = "stop", .details = &.{.{ .type_name = "a.B", .value = "v" }} };
    result.unsent = 2;
    const bytes = try result.finish("case", &output);
    const back = try proto.decode(client_compat.ClientCompatResponse, bytes);
    try testing.expectEqualStrings("case", back.test_name);
    const merged = back.result.?.response;
    try testing.expectEqual(@as(usize, 2), try merged.payloads.count());
    var payloads = merged.payloads.iterator();
    try testing.expectEqualStrings("a", (try payloads.next()).?.data);
    try testing.expectEqual(@as(usize, 1), try merged.response_trailers.count());
    try testing.expectEqual(@as(i32, 2), merged.num_unsent_requests);
    const failure = merged.@"error".?;
    try testing.expectEqual(@as(i32, 1), @intFromEnum(failure.code));
    var details = failure.details.iterator();
    try testing.expectEqualStrings("type.googleapis.com/a.B", (try details.next()).?.type_url);
}

test "a call the client cannot make reports its reason" {
    var output: [256]u8 = undefined;
    const back = try proto.decode(client_compat.ClientCompatResponse, try refusal("case", "no such method", &output));
    try testing.expectEqualStrings("no such method", back.result.?.@"error".message);
}

test "a varint takes seven bits an octet, low first, with the high bit on each but the last" {
    var room: [varint_len_max]u8 = undefined;
    // Encoding guide, "Base 128 Varints": 150 is 0x96 0x01.
    const one_fifty = 150;
    try testing.expectEqualSlices(u8, &.{ 0x96, 0x01 }, room[0..try write_varint(one_fifty, &room)]);
    try testing.expectEqualSlices(u8, &.{0x01}, room[0..try write_varint(1, &room)]);
    try testing.expectError(error.NoSpaceLeft, write_varint(one_fifty, room[0..1]));
}
