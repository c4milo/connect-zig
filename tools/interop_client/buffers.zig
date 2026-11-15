//! The memory of the interop client's one call at a time: its request, its response and the
//! reading of it. The client runs one call to its end before it starts the next, so every call
//! reuses it.
const connect = @import("connect");
const rpc = @import("connect_colibri");
const constants = @import("constants.zig");

/// The buffers of every call. `main` keeps them in its `State` (decision 42).
pub const Buffers = struct {
    request_body: [constants.body_bytes]u8,
    request_message: [constants.message_bytes]u8,
    request_work: [constants.body_bytes]u8,
    request_values: [constants.field_bytes]u8,
    response_headers: [constants.field_bytes]u8,
    response_trailers: [constants.field_bytes]u8,
    response_body: [constants.body_bytes]u8,
    response_piece: [constants.piece_bytes]u8,
    read_message: [constants.message_bytes]u8,
    read_work: [constants.body_bytes]u8,
    read_tokens: [constants.token_bytes]u8,
    read_octets: [constants.error_bytes]u8,
    details: [constants.details_max]connect.Detail,
    metadata: [constants.metadata_max]connect.Header,

    /// The buffers of a call: with pieces of the response for a streamed one.
    pub fn call(buffers: *Buffers, streamed: bool) rpc.ClientCallBuffers {
        return .{
            .request = .{
                .body = &buffers.request_body,
                .scratch = .{ .message = &buffers.request_message, .work = &buffers.request_work, .tokens = &.{} },
                .values = &buffers.request_values,
            },
            .headers = &buffers.response_headers,
            .trailers = &buffers.response_trailers,
            .body = &buffers.response_body,
            .piece = if (streamed) &buffers.response_piece else &.{},
        };
    }

    /// The storage a response is read with.
    pub fn storage(buffers: *Buffers) connect.client.Storage {
        return .{
            .scratch = .{ .message = &buffers.read_message, .work = &buffers.read_work, .tokens = &buffers.read_tokens },
            .octets = &buffers.read_octets,
            .details = &buffers.details,
            .metadata = &buffers.metadata,
        };
    }
};
