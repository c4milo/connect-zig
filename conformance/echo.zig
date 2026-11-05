//! What a conformance handler echoes and how it answers (docs/testing_servers.md in the
//! conformance suite, "ConformancePayload" and "Error"): the request's headers, timeout, query
//! and messages as a `RequestInfo`; the response headers and trailers a definition asks for; the
//! error it asks for, with the `RequestInfo` as its last detail; and its response delay.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const proto = @import("protobuf");
const rpc = @import("connect_colibri");
const service = @import("connectrpc_conformance_v1_service");
const config = @import("connectrpc_conformance_v1_config");
const constants = @import("constants.zig");

const Header = service.Header;
const RequestInfo = service.ConformancePayload.RequestInfo;
const Any = proto.wkt.Any;
const request_headers_max = rpc.constants.request_headers_max;

/// The prefix of an Any's type URL (google/protobuf/any.proto).
const type_url_prefix = "type.googleapis.com/";

/// The room a handler writes its echo into. A handler fills it and its reply goes out before
/// the next handler runs, so one room in the program's context serves every call.
pub const Echo = struct {
    groups: [request_headers_max]Header = undefined,
    values: [request_headers_max][]const u8 = undefined,
    pairs: [constants.query_pairs_max]connect.Header = undefined,
    query_groups: [constants.query_pairs_max]Header = undefined,
    query_values: [constants.query_pairs_max][]const u8 = undefined,
    query_octets: [constants.query_bytes]u8 = undefined,
    /// A unary or server-stream request, encoded for its Any.
    request_bytes: [constants.message_bytes]u8 = undefined,
    request_any: [1]Any = undefined,
    /// The `RequestInfo` an error carries as a detail, encoded.
    info_bytes: [constants.message_bytes]u8 = undefined,
    details: [connect.constants.limits.details_max]connect.Detail = undefined,

    /// The request's one message as an Any.
    pub fn one_request(echo: *Echo, comptime T: type, request: *const T) ![]const Any {
        echo.request_any[0] = try any_of(T, request, &echo.request_bytes);
        return &echo.request_any;
    }

    /// Everything the server observed: the headers, the timeout, a GET's query and `requests`.
    pub fn request_info(echo: *Echo, call: *const rpc.Call, requests: []const Any) RequestInfo {
        const headers = group(call.request_headers(), &echo.groups, &echo.values);
        return .{
            .request_headers = .of(headers),
            .timeout_ms = timeout_ms_of(call),
            .requests = .of(requests),
            .connect_get_info = echo.get_info(call),
        };
    }

    /// The query parameters of a Connect GET, decoded, or null for a POST.
    fn get_info(echo: *Echo, call: *const rpc.Call) ?service.ConformancePayload.ConnectGetInfo {
        const query = call.request_query();
        if (query.len == 0) return null;
        const pairs = split_query(query, &echo.pairs, &echo.query_octets);
        return .{ .query_params = .of(group(pairs, &echo.query_groups, &echo.query_values)) };
    }

    /// The error a definition asks for. `info`, when set, goes last among its details, so the
    /// client reads what the server observed.
    pub fn failure(echo: *Echo, wanted: *const service.Error, info: ?*const RequestInfo) connect.RpcError {
        var count: usize = 0;
        var details = wanted.details.iterator();
        for (0..echo.details.len) |_| {
            const detail = (details.next() catch return internal) orelse break;
            echo.details[count] = .{ .type_name = type_name_of(detail.type_url), .value = detail.value };
            count += 1;
        }
        if (info) |observed| {
            if (count == echo.details.len) return internal;
            const value = proto.encode(RequestInfo, observed, &echo.info_bytes) catch return internal;
            echo.details[count] = .{ .type_name = RequestInfo.protobuf.full_name, .value = value };
            count += 1;
        }
        return .{ .code = code_of(wanted.code), .message = wanted.message orelse "", .details = echo.details[0..count] };
    }
};

/// The error a handler answers when the server itself fails.
pub const internal: connect.RpcError = .{ .code = .internal, .message = "the conformance server ran out of room" };

/// `message` as an Any: its full name, and its binary encoding in `buffer`.
pub fn any_of(comptime T: type, message: *const T, buffer: []u8) !Any {
    const value = try proto.encode(T, message, buffer);
    return .{ .type_url = type_url_prefix ++ T.protobuf.full_name, .value = value };
}

/// The full name in a type URL: what follows its last "/" (google/protobuf/any.proto).
pub fn type_name_of(type_url: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, type_url, '/') orelse return type_url;
    return type_url[slash + 1 ..];
}

/// The conformance suite's codes are gRPC's, number for number (config.proto, `Code`). An
/// unspecified code is no error a client can read, so it becomes `unknown`.
pub fn code_of(code: config.Code) connect.Code {
    const number = @intFromEnum(code);
    if (number <= @intFromEnum(connect.Code.ok) or number > @intFromEnum(connect.Code.unauthenticated)) return .unknown;
    return @enumFromInt(number);
}

fn timeout_ms_of(call: *const rpc.Call) ?i64 {
    const timeout_ns = call.timeout_ns() orelse return null;
    return @intCast(timeout_ns / constants.nanos_per_milli);
}

/// Groups `entries` by name, compared without case (RFC 9110 §5.1), keeping each name's values
/// in the order they arrived.
pub fn group(entries: []const connect.Header, groups: []Header, values: [][]const u8) []const Header {
    assert(groups.len >= entries.len and values.len >= entries.len);
    var group_count: usize = 0;
    var value_count: usize = 0;
    for (entries, 0..) |entry, index| {
        if (named_before(entries[0..index], entry.name)) continue;
        const start = value_count;
        for (entries[index..]) |other| {
            if (!std.ascii.eqlIgnoreCase(other.name, entry.name)) continue;
            values[value_count] = other.value;
            value_count += 1;
        }
        groups[group_count] = .{ .name = entry.name, .value = .of(values[start..value_count]) };
        group_count += 1;
    }
    return groups[0..group_count];
}

fn named_before(entries: []const connect.Header, name: []const u8) bool {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return true;
    }
    return false;
}

/// The pairs of a query, their values percent-decoded into `octets` (RFC 3986 §2.1). Pairs past
/// `pairs.len`, and values past the room of `octets`, are left out.
pub fn split_query(query: []const u8, pairs: []connect.Header, octets: []u8) []const connect.Header {
    var count: usize = 0;
    var used: usize = 0;
    var parts = std.mem.splitScalar(u8, query, '&');
    for (0..pairs.len) |_| {
        const part = parts.next() orelse break;
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        const raw = if (equals < part.len) part[equals + 1 ..] else "";
        const value = connect.trailers.percent_decode(raw, octets[used..]);
        used += value.len;
        pairs[count] = .{ .name = part[0..equals], .value = value };
        count += 1;
    }
    return pairs[0..count];
}

/// Adds each response header and trailer a definition names, once for each value.
pub fn apply_metadata(call: *rpc.Call, headers: *const proto.Repeated(Header, .message), trailers: *const proto.Repeated(Header, .message)) ?connect.RpcError {
    if (add_each(call, headers, .header)) |failure_found| return failure_found;
    return add_each(call, trailers, .trailer);
}

const Section = enum { header, trailer };

fn add_each(call: *rpc.Call, list: *const proto.Repeated(Header, .message), section: Section) ?connect.RpcError {
    var fields = list.iterator();
    for (0..rpc.constants.fields_max + 1) |_| {
        const field = (fields.next() catch return internal) orelse return null;
        var values = field.value.iterator();
        for (0..rpc.constants.fields_max + 1) |_| {
            const value = (values.next() catch return internal) orelse break;
            switch (section) {
                .header => call.set_header(field.name, value) catch return internal,
                .trailer => call.add_trailer(field.name, value) catch return internal,
            }
        }
    }
    return internal;
}

/// Waits `delay_ms` before a response, as a definition asks. `slept_ms` counts the call's waits
/// so far. When the call's timeout ends first, the wait stops there and the call fails with
/// `deadline_exceeded` (PROTOCOL-HTTP2.md, "Timeout"; Connect protocol, "Timeout").
pub fn pause(io: std.Io, call: *const rpc.Call, delay_ms: u32, slept_ms: *u64) ?connect.RpcError {
    if (delay_ms == 0) return null;
    const timeout_ms: u64 = @intCast(timeout_ms_of(call) orelse return wait(io, delay_ms, slept_ms));
    const left_ms = timeout_ms -| slept_ms.*;
    if (delay_ms < left_ms) return wait(io, delay_ms, slept_ms);
    _ = wait(io, left_ms, slept_ms);
    return .{ .code = .deadline_exceeded, .message = "the response delay outlasts the timeout" };
}

fn wait(io: std.Io, delay_ms: u64, slept_ms: *u64) ?connect.RpcError {
    io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
    slept_ms.* += delay_ms;
    return null;
}

const testing = std.testing;

test "headers group by name in any case, with each value in order" {
    const entries = [_]connect.Header{
        .{ .name = "X-Test", .value = "1" },
        .{ .name = "accept", .value = "a" },
        .{ .name = "x-test", .value = "2" },
    };
    var groups: [entries.len]Header = undefined;
    var values: [entries.len][]const u8 = undefined;
    const grouped = group(&entries, &groups, &values);
    try testing.expectEqual(@as(usize, 2), grouped.len);
    try testing.expectEqualStrings("X-Test", grouped[0].name);
    try testing.expectEqual(@as(usize, 2), grouped[0].value.items.len);
    try testing.expectEqualStrings("2", grouped[0].value.items[1]);
    try testing.expectEqualStrings("a", grouped[1].value.items[0]);
}

test "a query splits into pairs whose values are percent-decoded" {
    var pairs: [4]connect.Header = undefined;
    var octets: [64]u8 = undefined;
    const split = split_query("encoding=proto&message=a%20b&base64", &pairs, &octets);
    try testing.expectEqual(@as(usize, 3), split.len);
    try testing.expectEqualStrings("proto", split[0].value);
    try testing.expectEqualStrings("a b", split[1].value);
    try testing.expectEqualStrings("base64", split[2].name);
    try testing.expectEqualStrings("", split[2].value);
}

test "a type URL names its type after the last slash, and codes keep their numbers" {
    try testing.expectEqualStrings("a.B", type_name_of("type.googleapis.com/a.B"));
    try testing.expectEqualStrings("a.B", type_name_of("a.B"));
    try testing.expectEqual(connect.Code.unauthenticated, code_of(@enumFromInt(16)));
    try testing.expectEqual(connect.Code.canceled, code_of(@enumFromInt(1)));
    try testing.expectEqual(connect.Code.unknown, code_of(@enumFromInt(0)));
    try testing.expectEqual(connect.Code.unknown, code_of(@enumFromInt(17)));
}

/// An echo the tests fill; it is too large for a test's stack.
threadlocal var test_echo: Echo align(@alignOf(Echo)) = undefined;

test "an error carries its details, then the request info last" {
    const echo = &test_echo;
    const detail: [1]Any = .{.{ .type_url = "type.googleapis.com/x.Y", .value = "v" }};
    const wanted: service.Error = .{ .code = @enumFromInt(3), .message = "bad", .details = .of(&detail) };
    const info: RequestInfo = .{ .timeout_ms = 5 };
    const failure = echo.failure(&wanted, &info);
    try testing.expectEqual(connect.Code.invalid_argument, failure.code);
    try testing.expectEqualStrings("bad", failure.message);
    try testing.expectEqual(@as(usize, 2), failure.details.len);
    try testing.expectEqualStrings("x.Y", failure.details[0].type_name);
    try testing.expectEqualStrings(RequestInfo.protobuf.full_name, failure.details[1].type_name);
    const decoded = try proto.decode(RequestInfo, failure.details[1].value);
    try testing.expectEqual(@as(?i64, 5), decoded.timeout_ms);
    try testing.expectEqual(@as(usize, 1), echo.failure(&wanted, null).details.len);
}
