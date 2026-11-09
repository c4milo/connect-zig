//! How a conformance call reads its response: each message's payload, the outcome, and the
//! headers and trailers (docs/testing_clients.md in the conformance suite, "Interacting with the
//! test runner"). `self` is a call of `client_invoke.zig`'s `Invocation`.
const std = @import("std");
const connect = @import("connect");
const constants = @import("constants.zig");
const invoke = @import("client_invoke.zig");

/// The response's header lines and trailer lines, which one case at a time records.
var header_lines: [constants.client_fields_max]connect.Header align(@alignOf(connect.Header)) = undefined;
var trailer_lines: [constants.client_fields_max]connect.Header align(@alignOf(connect.Header)) = undefined;

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

/// Records the response's headers and trailers, when its head arrived.
pub fn record_metadata(self: anytype) void {
    const Self = @TypeOf(self.*);
    const arrived = if (Self.streamed) self.headers_seen else self.call.response.result == .response;
    if (!arrived) return;
    const headers = lines_of(&self.call.response.headers, &header_lines);
    self.result.add_metadata(.headers, headers) catch {};
    if (self.stopped) return;
    const speaks = self.call.call.speaks;
    const trailers = switch (speaks.protocol) {
        // PROTOCOL-HTTP2.md, "Responses": gRPC's trailers are HTTP trailers.
        .grpc => lines_of(&self.call.response.trailers, &trailer_lines),
        // Connect protocol, "Unary-Response": a unary call's trailers are headers whose names
        // start with "trailer-". A stream's are in its end-stream message, and gRPC-Web's in its
        // trailers frame (PROTOCOL-WEB.md).
        .connect => if (speaks.enveloped) self.metadata else unary_trailers(headers, &trailer_lines),
        .grpc_web => self.metadata,
    };
    self.result.add_metadata(.trailers, trailers) catch {};
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
