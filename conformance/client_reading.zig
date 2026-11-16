//! How a conformance call reads its response: each message's payload, the outcome, and the
//! headers and trailers (docs/testing_clients.md in the conformance suite, "Interacting with the
//! test runner"). `self` is a call of `client_invoke.zig`'s `Invocation`.
const std = @import("std");
const connect = @import("connect");
const constants = @import("constants.zig");
const invoke = @import("client_invoke.zig");

const out_of_room: connect.RpcError = .{ .code = .internal, .message = "the client's result ran out of room" };

/// Reads each message of a streamed response that arrived whole. A unary-response call reads
/// none until it ended.
pub fn read_arrived(self: anytype) void {
    const Self = @TypeOf(self.*);
    if (Self.single_response) return;
    for (0..constants.client_responses_max) |_| {
        if (self.stopped) return;
        const message = self.call.reader.next(Self.rpc_method.Response) catch |failure| {
            return invoke.stop(self, connect.client.failure_of(failure));
        } orelse return;
        if (record(self, &message)) |failure| return invoke.stop(self, failure);
    }
}

/// Records a message's payload. It returns the failure the call stops with: a cancel after this
/// many responses, or a result out of room.
fn record(self: anytype, message: anytype) ?connect.RpcError {
    const Response = @TypeOf(message.*);
    const payload = if (@hasField(Response, "payload")) message.payload else null;
    self.result.add_payload(payload) catch return out_of_room;
    return switch (self.plan.cancel) {
        .after_responses => |count| if (self.result.payloads == count) invoke.canceled else null,
        else => null,
    };
}

/// Reads the messages of a finished call that its reader holds, then its outcome. A cancel after
/// a number of responses ends the reading there. A unary-response call that failed keeps no
/// payload.
pub fn read_rest(self: anytype, response: *connect.client.Response) void {
    const Self = @TypeOf(self.*);
    const kept = self.result.mark();
    self.result.failure = read_messages(self, response);
    if (Self.single_response and self.result.failure != null) self.result.rewind(kept);
    self.metadata = response.metadata;
}

/// Reads each message `response` holds, and returns the outcome.
fn read_messages(self: anytype, response: *connect.client.Response) ?connect.RpcError {
    const Self = @TypeOf(self.*);
    for (0..constants.client_responses_max) |_| {
        const message = response.next(Self.rpc_method.Response) catch |failure| {
            return connect.client.failure_of(failure);
        } orelse return response.failure;
        if (record(self, &message)) |failure| return failure;
    }
    return out_of_room;
}

/// Records the response's headers and trailers, when its head arrived. Their lines go into the
/// call's buffers.
pub fn record_metadata(self: anytype) void {
    const Self = @TypeOf(self.*);
    const arrived = if (Self.streamed) self.headers_seen else self.call.response.result == .response;
    if (!arrived) return;
    const headers = lines_of(&self.call.response.headers, &self.buffers.header_lines);
    self.result.add_metadata(.headers, headers) catch {};
    if (self.stopped) return;
    const http_trailers = lines_of(&self.call.response.trailers, &self.buffers.trailer_lines);
    const trailers = trailers_of(&self.call.call.speaks, .{ .headers = headers, .http_trailers = http_trailers, .body = self.metadata }, &self.buffers.trailer_lines);
    self.result.add_metadata(.trailers, trailers) catch {};
}

/// Where a response may carry its trailers: its head, its HTTP trailers, and its body's
/// end-stream message or trailers frame.
const Sources = struct {
    headers: []const connect.Header,
    http_trailers: []const connect.Header,
    body: []const connect.Header,
};

/// The trailers of a response, from where its protocol puts them. `lines` holds a Connect unary
/// response's trailers, which no other source holds apart.
fn trailers_of(speaks: *const connect.Speaks, sources: Sources, lines: []connect.Header) []const connect.Header {
    return switch (speaks.protocol) {
        // PROTOCOL-HTTP2.md, "Responses": gRPC's trailers are HTTP trailers.
        .grpc => sources.http_trailers,
        // Connect protocol, "Unary-Response": a unary call's trailers are headers whose names
        // start with "trailer-". A stream's are in its end-stream message.
        .connect => if (speaks.enveloped) sources.body else unary_trailers(sources.headers, lines),
        // PROTOCOL-WEB.md: gRPC-Web's are in its trailers frame, or in the head of a Trailers-Only
        // response.
        .grpc_web => web_trailers(sources.headers, sources.body),
    };
}

/// The lines of a colibri header or trailer section, in order.
fn lines_of(section: anytype, lines: []connect.Header) []const connect.Header {
    var each = section.iterator();
    for (lines, 0..) |*line, index| {
        const field = each.next() orelse return lines[0..index];
        line.* = .{ .name = field.name, .value = field.value };
    }
    return lines;
}

/// Connect protocol, "Unary-Response": the trailers of a unary response are its headers named
/// "Trailer-" and the trailer's name, without the prefix.
pub fn unary_trailers(headers: []const connect.Header, lines: []connect.Header) []const connect.Header {
    const prefix = "trailer-";
    var count: usize = 0;
    for (headers) |header| {
        if (header.name.len <= prefix.len or !std.ascii.startsWithIgnoreCase(header.name, prefix)) continue;
        if (count == lines.len) break;
        lines[count] = .{ .name = header.name[prefix.len..], .value = header.value };
        count += 1;
    }
    return lines[0..count];
}

/// PROTOCOL-HTTP2.md, "Responses": a Trailers-Only response holds no body, and its one header
/// section holds the status and the trailers. gRPC-Web keeps that shape (PROTOCOL-WEB.md). So a
/// response with no trailers frame, whose head names a status, has its head for trailers.
pub fn web_trailers(headers: []const connect.Header, frame: []const connect.Header) []const connect.Header {
    if (frame.len != 0) return frame;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "grpc-status")) return headers;
    }
    return frame;
}

test "a gRPC-Web response's trailers are its frame's, or its head's when Trailers-Only" {
    const frame = [_]connect.Header{.{ .name = "x-custom-trailer", .value = "in the frame" }};
    const head = [_]connect.Header{
        .{ .name = "content-type", .value = "application/grpc-web+proto" },
        .{ .name = "Grpc-Status", .value = "9" },
        .{ .name = "x-custom-trailer", .value = "in the head" },
    };
    try std.testing.expectEqualStrings("in the frame", web_trailers(&head, &frame)[0].value);
    // Trailers-Only: the head is the trailers.
    const from_head = web_trailers(&head, &.{});
    try std.testing.expectEqual(head.len, from_head.len);
    try std.testing.expectEqualStrings("in the head", from_head[head.len - 1].value);
    // A head with no status, as a response cut before its trailers frame has, gives none.
    try std.testing.expectEqual(@as(usize, 0), web_trailers(head[0..1], &.{}).len);
}

test "a response's trailers come from where its protocol puts them" {
    const testing = std.testing;
    const head = [_]connect.Header{
        .{ .name = "grpc-status", .value = "9" },
        .{ .name = "trailer-x-custom", .value = "in the head" },
    };
    const sources: Sources = .{
        .headers = &head,
        .http_trailers = &.{.{ .name = "x-custom", .value = "in the HTTP trailers" }},
        .body = &.{.{ .name = "x-custom", .value = "in the body" }},
    };
    var lines: [head.len]connect.Header = undefined;
    const stream: connect.Speaks = .{ .protocol = .connect, .codec = .proto, .enveloped = true };
    const unary: connect.Speaks = .{ .protocol = .connect, .codec = .proto, .enveloped = false };
    const grpc: connect.Speaks = .{ .protocol = .grpc, .codec = .proto, .enveloped = true };
    const web: connect.Speaks = .{ .protocol = .grpc_web, .codec = .proto, .enveloped = true };
    try testing.expectEqualStrings("in the HTTP trailers", trailers_of(&grpc, sources, &lines)[0].value);
    try testing.expectEqualStrings("in the body", trailers_of(&stream, sources, &lines)[0].value);
    try testing.expectEqualStrings("in the body", trailers_of(&web, sources, &lines)[0].value);
    try testing.expectEqualStrings("in the head", trailers_of(&unary, sources, &lines)[0].value);
    // gRPC-Web's Trailers-Only: no trailers frame, so the head is the trailers.
    var trailers_only = sources;
    trailers_only.body = &.{};
    try testing.expectEqual(head.len, trailers_of(&web, trailers_only, &lines).len);
    // A Connect stream has no such case: its head never holds its trailers.
    try testing.expectEqual(@as(usize, 0), trailers_of(&stream, trailers_only, &lines).len);
}

test "a unary response's trailers are its headers named trailer-, without the prefix" {
    const headers = [_]connect.Header{
        .{ .name = "content-type", .value = "application/proto" },
        .{ .name = "Trailer-X-Custom", .value = "a" },
        .{ .name = "trailer-", .value = "none" },
    };
    var lines: [constants.client_details_max]connect.Header = undefined;
    const trailers = unary_trailers(&headers, &lines);
    try std.testing.expectEqual(@as(usize, 1), trailers.len);
    try std.testing.expectEqualStrings("X-Custom", trailers[0].name);
    try std.testing.expectEqualStrings("a", trailers[0].value);
}
