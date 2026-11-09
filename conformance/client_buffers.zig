//! The memory of the conformance client's one call at a time: its request, its response and the
//! reading of it. Each case runs alone, so every call reuses it.
const connect = @import("connect");
const rpc = @import("connect_colibri");
const constants = @import("constants.zig");

var request_body: [constants.client_body_bytes]u8 = undefined;
var request_message: [constants.client_message_bytes]u8 = undefined;
var request_work: [constants.client_message_bytes]u8 = undefined;
var request_values: [constants.client_field_bytes]u8 = undefined;
var response_headers: [constants.client_field_bytes]u8 = undefined;
var response_trailers: [constants.client_field_bytes]u8 = undefined;
var response_body: [constants.client_body_bytes]u8 = undefined;
var response_piece: [constants.client_piece_bytes]u8 = undefined;
var read_message: [constants.client_message_bytes]u8 = undefined;
var read_work: [constants.client_message_bytes]u8 = undefined;
var read_tokens: [constants.client_token_bytes]u8 = undefined;
var read_octets: [constants.client_error_bytes]u8 = undefined;
var details: [constants.client_details_max]connect.Detail align(@alignOf(connect.Detail)) = undefined;
var metadata: [constants.client_metadata_max]connect.Header align(@alignOf(connect.Header)) = undefined;

/// The buffers of a call: with pieces of the response for a streamed one.
pub fn call(streamed: bool) rpc.ClientCallBuffers {
    return .{
        .request = .{
            .body = &request_body,
            .scratch = .{ .message = &request_message, .work = &request_work, .tokens = &.{} },
            .values = &request_values,
        },
        .headers = &response_headers,
        .trailers = &response_trailers,
        .body = &response_body,
        .piece = if (streamed) &response_piece else &.{},
    };
}

/// The storage the response is read with. A receive limit bounds each message the client reads:
/// a longer one fails the call `resource_exhausted` (statuscodes.md, RESOURCE_EXHAUSTED).
pub fn storage(receive_limit: u32) connect.client.Storage {
    const message_len = if (receive_limit == 0) read_message.len else @min(read_message.len, receive_limit);
    return .{
        .scratch = .{ .message = read_message[0..message_len], .work = &read_work, .tokens = &read_tokens },
        .octets = &read_octets,
        .details = &details,
        .metadata = &metadata,
    };
}

test "a receive limit bounds the message a response is read into, and 0 leaves the buffer's" {
    const testing = @import("std").testing;
    const limit = 1024;
    try testing.expectEqual(@as(usize, limit), storage(limit).scratch.message.len);
    try testing.expectEqual(read_message.len, storage(0).scratch.message.len);
}
