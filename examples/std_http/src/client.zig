//! The client half: connect's sans-I/O client builds each request and reads each response, and
//! `std.http.Client` sends the one and receives the other over HTTP/1.1.
const std = @import("std");
const connect = @import("connect_zig").connect;
const constants = @import("constants.zig");
const Copied = @import("headers.zig").Copied;

/// The client's memory, which `main` allocates once (decision 42).
pub const Storage = struct {
    request_body: [constants.buffer_len]u8,
    request_message: [constants.buffer_len]u8,
    request_work: [constants.buffer_len]u8,
    request_values: [constants.buffer_len]u8,
    /// A copy of the request body, since `std.http.Client` takes the body as mutable octets.
    send_body: [constants.buffer_len]u8,
    extra_headers: [connect.client.request_headers_max]std.http.Header,
    url: [constants.buffer_len]u8,
    transfer: [constants.buffer_len]u8,
    response_headers: Copied,
    response_body: [constants.buffer_len]u8,
    message: [constants.buffer_len]u8,
    work: [constants.buffer_len]u8,
    tokens: [constants.buffer_len]u8,
    octets: [constants.buffer_len]u8,
    details: [constants.entries_max]connect.Detail,
    metadata: [constants.entries_max]connect.Header,
};

pub fn request_buffers(storage: *Storage) connect.client.Buffers {
    return .{
        .body = &storage.request_body,
        .scratch = .{ .message = &storage.request_message, .work = &storage.request_work, .tokens = &.{} },
        .values = &storage.request_values,
    };
}

/// Sends `request` to the server on `port` and starts the read of its response, in `speaks`.
pub fn exchange(
    connect_client: *const connect.Client,
    http_client: *std.http.Client,
    port: u16,
    request: *const connect.client.Request,
    speaks: connect.Speaks,
    storage: *Storage,
) !connect.client.Response {
    const url = try std.fmt.bufPrint(&storage.url, "http://{s}:{d}{s}", .{ constants.address, port, request.target });
    const headers = request.headers();
    if (headers.len > storage.extra_headers.len) return error.TooManyHeaders;
    for (headers, storage.extra_headers[0..headers.len]) |header, *out| out.* = .{ .name = header.name, .value = header.value };
    const method = std.meta.stringToEnum(std.http.Method, request.http_method) orelse return error.UnknownMethod;
    var http_request = try http_client.request(method, try std.Uri.parse(url), .{
        .redirect_behavior = .not_allowed,
        // connect's request names its own content type, and asks for no coding of the response.
        .headers = .{ .content_type = .omit, .accept_encoding = .omit },
        .extra_headers = storage.extra_headers[0..headers.len],
    });
    defer http_request.deinit();
    const body = storage.send_body[0..request.body.len];
    @memcpy(body, request.body);
    try http_request.sendBodyComplete(body);
    var response = try http_request.receiveHead(&.{});
    try storage.response_headers.copy(response.head.iterateHeaders());
    const status: u16 = @intFromEnum(response.head.status);
    const length = try response.reader(&storage.transfer).readSliceShort(&storage.response_body);
    if (length == storage.response_body.len) return error.ResponseTooLarge;
    const incoming: connect.client.Incoming = .{ .status = status, .headers = storage.response_headers.lookup(), .body = storage.response_body[0..length] };
    const reading: connect.client.Storage = .{
        .scratch = .{ .message = &storage.message, .work = &storage.work, .tokens = &storage.tokens },
        .octets = &storage.octets,
        .details = &storage.details,
        .metadata = &storage.metadata,
    };
    return connect_client.response(speaks, &incoming, &reading);
}
