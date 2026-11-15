//! The memory of the conformance client's one call at a time: its request, its response and the
//! reading of it. Each case runs alone, so every call reuses it. The client holds one `Buffers`
//! in its `State` (decision 42).
const connect = @import("connect");
const rpc = @import("connect_colibri");
const constants = @import("constants.zig");

pub const Buffers = struct {
    const Self = @This();

    request_body: [constants.client_body_bytes]u8,
    request_message: [constants.client_message_bytes]u8,
    request_work: [constants.client_message_bytes]u8,
    request_values: [constants.client_field_bytes]u8,
    response_headers: [constants.client_field_bytes]u8,
    response_trailers: [constants.client_field_bytes]u8,
    response_body: [constants.client_body_bytes]u8,
    response_piece: [constants.client_piece_bytes]u8,
    read_message: [constants.client_message_bytes]u8,
    read_work: [constants.client_message_bytes]u8,
    read_tokens: [constants.client_token_bytes]u8,
    read_octets: [constants.client_error_bytes]u8,
    details: [constants.client_details_max]connect.Detail,
    metadata: [constants.client_metadata_max]connect.Header,
    /// The response's header lines and trailer lines, which `client_reading.zig` records.
    header_lines: [constants.client_fields_max]connect.Header,
    trailer_lines: [constants.client_fields_max]connect.Header,

    /// The buffers of a call: with pieces of the response for a streamed one.
    pub fn call(self: *Self, streamed: bool) rpc.ClientCallBuffers {
        return .{
            .request = .{
                .body = &self.request_body,
                .scratch = .{ .message = &self.request_message, .work = &self.request_work, .tokens = &.{} },
                .values = &self.request_values,
            },
            .headers = &self.response_headers,
            .trailers = &self.response_trailers,
            .body = &self.response_body,
            .piece = if (streamed) &self.response_piece else &.{},
        };
    }

    /// The storage the response is read with. A receive limit bounds each message the client
    /// reads: a longer one fails the call `resource_exhausted` (statuscodes.md,
    /// RESOURCE_EXHAUSTED).
    pub fn storage(self: *Self, receive_limit: u32) connect.client.Storage {
        const message_len = if (receive_limit == 0) self.read_message.len else @min(self.read_message.len, receive_limit);
        return .{
            .scratch = .{ .message = self.read_message[0..message_len], .work = &self.read_work, .tokens = &self.read_tokens },
            .octets = &self.read_octets,
            .details = &self.details,
            .metadata = &self.metadata,
        };
    }
};

test "a receive limit bounds the message a response is read into, and 0 leaves the buffer's" {
    const std = @import("std");
    const testing = std.testing;
    const buffers = try testing.allocator.create(Buffers);
    defer testing.allocator.destroy(buffers);
    const limit = 1024;
    try testing.expectEqual(@as(usize, limit), buffers.storage(limit).scratch.message.len);
    try testing.expectEqual(buffers.read_message.len, buffers.storage(0).scratch.message.len);
}
