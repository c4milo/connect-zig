//! The memory of the interop client's one call at a time: its request, its response and the
//! reading of it. The client runs one call to its end before it starts the next, so every call
//! reuses it.
const connect = @import("connect");
const rpc = @import("connect_colibri");

/// Octets of a message the client writes or reads: the largest coverage case, in JSON, with room.
pub const message_bytes = 256 * 1024;
/// Octets of a request body and of a response body: Collect sends every case, and Chat's answers
/// gather here until the client reads them.
pub const body_bytes = 1024 * 1024;
/// Octets of each piece of a streamed response that colibri hands the client.
const piece_bytes = 64 * 1024;
/// Octets of a response's header section and trailer section, and of the request's header values.
const field_bytes = 16 * 1024;
/// Octets of the JSON tokens the client reads at once: a bytes field in base64.
const token_bytes = 256 * 1024;
/// Octets of an error's message and details, and of the end-stream metadata.
const error_bytes = 64 * 1024;
/// The details of an error, and the metadata lines of an end-stream message or a gRPC-Web
/// trailers frame, the client reads at most.
const details_max = 8;
const metadata_max = 32;

var request_body: [body_bytes]u8 = undefined;
var request_message: [message_bytes]u8 = undefined;
var request_work: [body_bytes]u8 = undefined;
var request_values: [field_bytes]u8 = undefined;
var response_headers: [field_bytes]u8 = undefined;
var response_trailers: [field_bytes]u8 = undefined;
var response_body: [body_bytes]u8 = undefined;
var response_piece: [piece_bytes]u8 = undefined;
var read_message: [message_bytes]u8 = undefined;
var read_work: [body_bytes]u8 = undefined;
var read_tokens: [token_bytes]u8 = undefined;
var read_octets: [error_bytes]u8 = undefined;
var details: [details_max]connect.Detail align(@alignOf(connect.Detail)) = undefined;
var metadata: [metadata_max]connect.Header align(@alignOf(connect.Header)) = undefined;

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

/// The storage a response is read with.
pub fn storage() connect.client.Storage {
    return .{
        .scratch = .{ .message = &read_message, .work = &read_work, .tokens = &read_tokens },
        .octets = &read_octets,
        .details = &details,
        .metadata = &metadata,
    };
}
