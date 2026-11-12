//! One call a route serves: what it read of the request, what it wrote of the reply, and the
//! writing of the reply through colibri's `server.ResponseWriter`. A handler and an interceptor
//! see it through the views of `context.zig` (decision 36).
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const server = @import("server");
const http = @import("http");
const constants = @import("constants.zig");

/// The request's headers, copied at its head into the request's entry of the router pool, so the
/// handler and its interceptors read them for the whole call.
pub const RequestHeaders = struct {
    octets: [constants.request_header_bytes]u8 = undefined,
    entries: [constants.request_headers_max]connect.Header = undefined,
    count: usize = 0,

    /// Copies every header, or fails when they do not fit.
    pub fn copy(headers: *RequestHeaders, from: server.Headers) error{HeadersTooLarge}!void {
        headers.count = 0;
        var used: usize = 0;
        var lines = from.iterator();
        for (0..constants.request_headers_max + 1) |_| {
            const line = lines.next() orelse return;
            if (headers.count == constants.request_headers_max) return error.HeadersTooLarge;
            const len = line.name.len + line.value.len;
            if (len > headers.octets.len - used) return error.HeadersTooLarge;
            const name = headers.octets[used..][0..line.name.len];
            @memcpy(name, line.name);
            const value = headers.octets[used + name.len ..][0..line.value.len];
            @memcpy(value, line.value);
            used += len;
            headers.entries[headers.count] = .{ .name = name, .value = value };
            headers.count += 1;
        }
        return error.HeadersTooLarge;
    }

    pub fn find(headers: *const RequestHeaders, name: []const u8) ?[]const u8 {
        for (headers.entries[0..headers.count]) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    fn find_erased(context: *const anyopaque, name: []const u8) ?[]const u8 {
        const headers: *const RequestHeaders = @ptrCast(@alignCast(context));
        return headers.find(name);
    }

    pub fn lookup(headers: *const RequestHeaders) connect.Lookup {
        return .{ .context = headers, .find_fn = find_erased };
    }
};

/// A GET's query, copied at its head into the request's entry of the router pool. colibri holds
/// the head's octets only while the head's event lasts, and a GET's route reads its message once
/// the request ends, which over h3 is a later event.
pub const RequestQuery = struct {
    octets: [constants.request_query_bytes]u8 = undefined,

    /// Copies `from` and returns the copy, or null for a request with no query. A query longer
    /// than the storage fails.
    pub fn copy(query: *RequestQuery, from: ?[]const u8) error{QueryTooLong}!?[]const u8 {
        const held = from orelse return null;
        if (held.len > query.octets.len) return error.QueryTooLong;
        const copied = query.octets[0..held.len];
        @memcpy(copied, held);
        return copied;
    }
};

/// What a call writes into while it answers: the response headers and trailers its handler adds,
/// their octets, and the lists of them that connect and colibri each take. A route keeps one in
/// each request's entry of the router pool.
pub const Room = struct {
    storage: [constants.trailer_bytes]u8 = undefined,
    /// The status trailers, then the call's own, which gRPC-Web's trailers frame holds together.
    headers: [connect.trailers.trailers_max + constants.fields_max]connect.Header = undefined,
    fields: [connect.trailers.trailers_max + constants.fields_max]http.Field = undefined,
    response_headers: [constants.fields_max]connect.Header = undefined,
    response_header_count: usize = 0,
    metadata: [constants.fields_max]connect.Header = undefined,
    metadata_count: usize = 0,
    /// The names "trailer-<name>" a Connect unary reply sends its trailers under.
    prefixed: [constants.trailer_bytes]u8 = undefined,
};

pub const Call = struct {
    reply: connect.server.Reply,
    response: *server.ResponseWriter,
    room: *Room,
    headers: *const RequestHeaders,
    /// The path that names the method: "/connectrpc.eliza.v1.ElizaService/Say".
    path: []const u8,
    /// The request's query, after the path's "?", copied at the head, or empty.
    query: []const u8 = "",
    head_written: bool = false,
    /// Messages the call read and wrote, which an interceptor may report.
    received: u32 = 0,
    sent: u32 = 0,
    /// One envelope the response memory had no room for, which goes out before anything else the
    /// call writes (`write_held`). It points into the reply's scratch storage, and is empty when
    /// the call holds none. Only a route with `next` holds one (`pull.zig`).
    held: []const u8 = "",
    /// The program's values for the call in the route's state, and the name of their type
    /// (decision 35).
    values_pointer: ?*anyopaque = null,
    values_name: []const u8 = "",

    /// The program's values for the call, of the type `RouteOptions.Values` names (decision 35).
    pub fn values(call: *const Call, comptime Values: type) *Values {
        // A read with another type than the route's is a programmer error.
        assert(std.mem.eql(u8, call.values_name, @typeName(Values)));
        return @ptrCast(@alignCast(call.values_pointer.?));
    }

    /// The protocol the request spoke.
    pub fn protocol(call: *const Call) connect.Protocol {
        return call.reply.accepted.speaks.protocol;
    }

    /// The codec the request spoke.
    pub fn codec(call: *const Call) connect.Codec {
        return call.reply.accepted.speaks.codec;
    }

    /// The timeout the client asked for, in nanoseconds. The program turns it into a deadline
    /// with its own clock (decision 3).
    pub fn timeout_ns(call: *const Call) ?u64 {
        return call.reply.accepted.timeout_ns;
    }

    /// The request's headers, every line in the order it arrived. A name may repeat.
    pub fn request_headers(call: *const Call) []const connect.Header {
        return call.headers.entries[0..call.headers.count];
    }

    /// The request's query, after the path's "?", or empty: a unary GET's parameters (Connect
    /// protocol, "Unary-Get-Request").
    pub fn request_query(call: *const Call) []const u8 {
        return call.query;
    }

    /// A request header's value, by a name in any case, or null.
    pub fn request_header(call: *const Call, name: []const u8) ?[]const u8 {
        return call.headers.find(name);
    }

    /// Adds a response header. It goes out with the reply's head, so a handler adds it before it
    /// sends its first message.
    pub fn add_header(call: *Call, name: []const u8, value: []const u8) error{ TooManyHeaders, HeadSent, InvalidField }!void {
        if (call.head_written) return error.HeadSent;
        // A name that is not a token, or a value with CR, LF or NUL, would forge header lines.
        if (!connect.trailers.valid_field(.{ .name = name, .value = value })) return error.InvalidField;
        if (call.room.response_header_count == constants.fields_max) return error.TooManyHeaders;
        call.room.response_headers[call.room.response_header_count] = .{ .name = name, .value = value };
        call.room.response_header_count += 1;
    }

    /// Whether a gRPC error keeps its head apart from its trailers. A Trailers-Only reply is one
    /// header section, which a client reads as trailers alone (gRPC PROTOCOL-HTTP2.md,
    /// "Responses"), so a call that set response headers sends them in a head of their own.
    fn headers_kept(call: *const Call) bool {
        return call.reply.accepted.speaks.protocol == .grpc and call.room.response_header_count != 0;
    }

    /// Adds a trailer the reply carries: in the end-stream message, gRPC's trailers or
    /// gRPC-Web's trailers frame, and for a Connect unary reply in a header "trailer-<name>"
    /// (Connect protocol, "Unary-Response").
    pub fn add_trailer(call: *Call, name: []const u8, value: []const u8) error{ TooManyTrailers, InvalidField }!void {
        // gRPC-Web writes trailers into the body, where no HTTP layer checks them (RFC 9110 §5.5).
        if (!connect.trailers.valid_field(.{ .name = name, .value = value })) return error.InvalidField;
        if (call.room.metadata_count == constants.fields_max) return error.TooManyTrailers;
        call.room.metadata[call.room.metadata_count] = .{ .name = name, .value = value };
        call.room.metadata_count += 1;
    }
};

/// Sends one message of a server or bidirectional stream, as `ResponseStream.send` does: at once,
/// so a client reads it before the stream ends.
pub fn send_message(comptime T: type, call: *Call, message: *const T) !void {
    try write_head_once(call, .plain);
    // A message the call holds was written first, so it goes out first.
    if (!write_held(call)) return error.WriteFailed;
    const body = call.response.body();
    try write_message(T, call, message, body);
    call.sent += 1;
    // The writer hands what it holds to the endpoint now, rather than at the end. A flush that
    // fails keeps its octets in the writer, which sends them later (colibri's usage guide), so
    // the message went all the same.
    body.flush() catch {};
}

fn apply_head(call: *Call, head: *const connect.server.Head) !void {
    call.response.status = @enumFromInt(head.status);
    for (head.headers()) |header| try call.response.header(header.name, header.value);
    for (call.room.response_headers[0..call.room.response_header_count]) |header| try call.response.header(header.name, header.value);
}

/// Writes the message the call holds into the response memory, and returns whether the call
/// then holds none. colibri's `ResponseWriter.body` takes one slice whole or not at all, so a
/// message that still finds no room stays held, whole.
pub fn write_held(call: *Call) bool {
    if (call.held.len == 0) return true;
    assert(call.head_written);
    call.response.body().writeAll(call.held) catch return false;
    call.held = "";
    call.sent += 1;
    return true;
}

pub fn write_head_once(call: *Call, body: connect.server.Body) !void {
    if (call.head_written) return;
    const head = call.reply.head(body);
    try apply_head(call, &head);
    call.head_written = true;
}

/// A Connect unary reply has no trailer section, so its trailers go out as headers named
/// "trailer-<name>" (Connect protocol, "Unary-Response").
fn write_prefixed_trailers(call: *Call) !void {
    const prefix = "trailer-";
    var used: usize = 0;
    for (call.room.metadata[0..call.room.metadata_count]) |trailer| {
        const len = prefix.len + trailer.name.len;
        if (len > call.room.prefixed.len - used) return error.NoSpaceLeft;
        const name = call.room.prefixed[used..][0..len];
        @memcpy(name[0..prefix.len], prefix);
        @memcpy(name[prefix.len..], trailer.name);
        used += len;
        try call.response.header(name, trailer.value);
    }
}

/// Ends the call: with the error when it is set, else with success.
pub fn finish(call: *Call, failure: ?connect.RpcError) !void {
    if (failure) |rpc_failure| {
        if (call.reply.error_only() and !call.head_written and !call.headers_kept()) {
            const head = try call.reply.error_head(&rpc_failure, &call.room.storage);
            try apply_head(call, &head);
            call.head_written = true;
            switch (call.reply.accepted.speaks.protocol) {
                .connect => try write_prefixed_trailers(call),
                // A Trailers-Only reply is one header section, which holds the trailers too
                // (gRPC PROTOCOL-HTTP2.md, "Responses").
                .grpc => for (call.room.metadata[0..call.room.metadata_count]) |trailer| try call.response.header(trailer.name, trailer.value),
                .grpc_web => {},
            }
            try call.reply.write_error_body(rpc_failure, call.response.body());
            return call.response.end();
        }
    }
    // A Connect unary reply wrote its head and its one message already.
    if (!call.reply.accepted.speaks.enveloped) return call.response.end();
    try write_head_once(call, .plain);
    const metadata = call.room.metadata[0..call.room.metadata_count];
    const trailers = try call.reply.finish(failure, metadata, call.response.body(), &call.room.storage, &call.room.headers);
    if (trailers.len == 0) return call.response.end();
    return call.response.trailers(trailer_fields(call, trailers));
}

/// The trailer section of a gRPC response as colibri takes it: the status trailers, then the
/// call's own. The fields are in the call's `Room`.
pub fn trailer_fields(call: *Call, trailers: []const connect.Header) []const http.Field {
    const metadata = call.room.metadata[0..call.room.metadata_count];
    const fields = &call.room.fields;
    assert(trailers.len + metadata.len <= fields.len);
    for (trailers, 0..) |trailer, index| fields[index] = .{ .name = trailer.name, .value = trailer.value };
    for (metadata, trailers.len..) |trailer, index| fields[index] = .{ .name = trailer.name, .value = trailer.value };
    return fields[0 .. trailers.len + metadata.len];
}

/// Writes a reply's one message: for Connect unary, with its head and its trailers as headers.
/// Writes a message into the body's buffer directly, or, when it has no room, through scratch
/// storage in pieces.
fn write_message(comptime T: type, call: *Call, message: *const T, body: *std.Io.Writer) !void {
    if (try call.reply.write_direct(T, message, body)) return;
    try call.reply.write_message(try call.reply.prepare(T, message), body);
}

pub fn send_one(comptime T: type, call: *Call, message: *const T) !void {
    if (call.reply.writes_direct()) {
        // The head does not depend on the message, so it goes first and the message after it.
        if (!call.reply.accepted.speaks.enveloped) {
            const head = call.reply.head(.plain);
            try apply_head(call, &head);
            call.head_written = true;
            try write_prefixed_trailers(call);
        } else try write_head_once(call, .plain);
        try write_message(T, call, message, call.response.body());
        call.sent += 1;
        return;
    }
    const prepared = try call.reply.prepare(T, message);
    if (!call.reply.accepted.speaks.enveloped) {
        const head = call.reply.head(prepared.body());
        try apply_head(call, &head);
        call.head_written = true;
        try write_prefixed_trailers(call);
    } else try write_head_once(call, prepared.body());
    try call.reply.write_message(prepared, call.response.body());
    call.sent += 1;
}

pub const One = union(enum) { message: void, failure: connect.RpcError };

/// Reads the one message of a unary or server-stream request into `out`.
pub fn read_one(comptime T: type, call: *Call, messages: *connect.server.Messages, out: *T) One {
    const message = messages.next(T) catch |failure| return .{ .failure = connect.server.failure_of(failure) };
    // A unary request with no message breaks the method's cardinality, as one with two does:
    // connect-go and grpc-go answer both `unimplemented`, and the conformance suite asks it
    // (connect_server_unexpected.yaml and grpc_server_unexpected.yaml, "no-request").
    out.* = message orelse return .{ .failure = .{ .code = .unimplemented, .message = "unary request with no message" } };
    call.received += 1;
    // Connect protocol and PROTOCOL-HTTP2.md: a unary request holds exactly one message.
    const extra = messages.next(T) catch return .{ .failure = .{ .code = .invalid_argument, .message = "malformed request" } };
    if (extra != null) return .{ .failure = .{ .code = .unimplemented, .message = "unary request with more than one message" } };
    return .{ .message = {} };
}

/// Answers a request the route refused before it read the body.
pub fn answer_refusal(refused: connect.server.Refused, scratch: connect.Scratch, room: *Room, headers: *const RequestHeaders, response: *server.ResponseWriter) !void {
    const reply = connect.server.refusal_reply(&refused, &scratch) orelse {
        response.status = @enumFromInt(refused.http_status);
        return response.end();
    };
    var call: Call = .{ .reply = reply, .response = response, .room = room, .headers = headers, .path = "" };
    return finish(&call, refused.failure.?);
}

const testing = std.testing;

/// A section the tests fill; it is too large for a test's stack.
threadlocal var test_section: http.FieldSection align(@alignOf(http.FieldSection)) = undefined;

test "request headers copy every line, and find them by a name in any case (RFC 9110 §5.1)" {
    test_section.init();
    try test_section.append("authorization", "Bearer Ada");
    try test_section.append("x-trace", "7");
    var headers: RequestHeaders = .{};
    try headers.copy(.of(&test_section));
    try testing.expectEqual(@as(usize, 2), headers.count);
    try testing.expectEqualStrings("Bearer Ada", headers.find("Authorization").?);
    try testing.expectEqualStrings("7", headers.lookup().find("X-TRACE").?);
    try testing.expectEqual(@as(?[]const u8, null), headers.find("cookie"));
}

test "a call lists its request headers in order, repeats included, and its query" {
    test_section.init();
    try test_section.append("x-a", "1");
    try test_section.append("x-a", "2");
    var headers: RequestHeaders = .{};
    try headers.copy(.of(&test_section));
    const call: Call = .{ .reply = undefined, .response = undefined, .room = undefined, .headers = &headers, .path = "", .query = "encoding=proto&connect=v1" };
    try testing.expectEqualStrings("encoding=proto&connect=v1", call.request_query());
    try testing.expectEqual(@as(usize, 2), call.request_headers().len);
    try testing.expectEqualStrings("2", call.request_headers()[1].value);
}

test "request headers refuse one line more than they hold" {
    test_section.init();
    for (0..constants.request_headers_max) |_| try test_section.append("a", "b");
    var headers: RequestHeaders = .{};
    try headers.copy(.of(&test_section));
    try test_section.append("a", "b");
    try testing.expectError(error.HeadersTooLarge, headers.copy(.of(&test_section)));
}

test "request headers refuse octets beyond their storage" {
    test_section.init();
    const value_len = constants.request_header_bytes / 2;
    const value = [_]u8{'v'} ** value_len;
    try test_section.append("a", &value);
    var headers: RequestHeaders = .{};
    try headers.copy(.of(&test_section));
    try test_section.append("b", &value);
    try testing.expectError(error.HeadersTooLarge, headers.copy(.of(&test_section)));
}

test "a request's query is copied, so it outlives the octets it came from" {
    var source = "connect=v1&message=e30".*;
    var query: RequestQuery = .{};
    const copied = (try query.copy(&source)).?;
    @memset(&source, 'x');
    try testing.expectEqualStrings("connect=v1&message=e30", copied);
    try testing.expectEqual(@as(?[]const u8, null), try query.copy(null));
}

test "a request's query longer than its storage is refused" {
    const fits = [_]u8{'q'} ** constants.request_query_bytes;
    var query: RequestQuery = .{};
    try testing.expectEqual(fits.len, (try query.copy(&fits)).?.len);
    const longer = fits ++ "q";
    try testing.expectError(error.QueryTooLong, query.copy(longer));
}

test "a response header is refused once the head went out, or once the room is full" {
    var room: Room = .{};
    const headers: RequestHeaders = .{};
    var call: Call = .{ .reply = undefined, .response = undefined, .room = &room, .headers = &headers, .path = "" };
    for (0..constants.fields_max) |_| try call.add_header("a", "b");
    try testing.expectError(error.TooManyHeaders, call.add_header("a", "b"));
    call.head_written = true;
    try testing.expectError(error.HeadSent, call.add_header("a", "b"));
    call.head_written = false;
    call.room.response_header_count = 0;
    try testing.expectError(error.InvalidField, call.add_header("a", "b\r\nset-cookie: x"));
    try testing.expectError(error.InvalidField, call.add_trailer("a:b", "c"));
    for (0..constants.fields_max) |_| try call.add_trailer("t", "v");
    try testing.expectError(error.TooManyTrailers, call.add_trailer("t", "v"));
}
