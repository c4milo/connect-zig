//! A client's reading of a response: its messages, then its outcome, in the protocol the call
//! spoke (Connect protocol, "Unary-Response", "Streaming-Response" and "HTTP to Error Code";
//! PROTOCOL-HTTP2.md, "Responses"; PROTOCOL-WEB.md).
//!
//! gRPC carries its status in HTTP trailers, which colibri's client does not expose yet, so a gRPC
//! response is readable here only when the caller passes its trailers, or when the server
//! answered Trailers-Only (decision 11).
const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");
const compression = @import("compression.zig");
const envelope = @import("envelope.zig");
const error_json = @import("error_json.zig");
const end_stream = @import("end_stream.zig");
const trailers = @import("trailers.zig");
const message_codec = @import("message_codec.zig");
const server_head = @import("server_head.zig");
const rpc_error = @import("rpc_error.zig");
const Code = @import("code.zig").Code;
const Header = rpc_error.Header;
const RpcError = rpc_error.RpcError;
const Lookup = server_head.Lookup;

pub const Incoming = struct {
    status: u16,
    headers: Lookup,
    body: []const u8,
    /// The HTTP trailers, when the HTTP library exposes them.
    trailers: ?Lookup = null,
};

pub const Storage = struct {
    scratch: message_codec.Scratch,
    /// The error's message and details, and the end-stream metadata.
    octets: []u8,
    details: []rpc_error.Detail,
    metadata: []Header,
};

pub const Error = message_codec.DecodeError || compression.Error || envelope.Error || error{
    /// An envelope the protocol does not allow where it stands, or a message after the end.
    InvalidEnvelope,
};

pub const Response = struct {
    speaks: protocol.Speaks,
    incoming: Incoming,
    storage: Storage,
    decoders: compression.Decoders,
    coding: compression.Coding,
    reader: envelope.Reader,
    /// The outcome, once it is known: null while messages may follow, and after a success.
    failure: ?RpcError = null,
    metadata: []const Header = &.{},
    done: bool = false,

    /// The next message, or null once the response holds no more. `failure` is then set when
    /// the call failed.
    pub fn next(response: *Response, comptime T: type) Error!?T {
        if (response.done) return null;
        const octets = try response.next_octets() orelse return null;
        return try message_codec.decode(T, response.speaks.codec, octets, response.storage.scratch);
    }

    fn next_octets(response: *Response) Error!?[]const u8 {
        if (!response.speaks.enveloped) {
            response.done = true;
            return try compression.decompress(response.coding, response.decoders, response.incoming.body, response.storage.scratch.message);
        }
        const next_one = try response.reader.next() orelse return response.end_without_status();
        if (next_one.flags.end_stream or next_one.flags.trailers) {
            try response.read_end(next_one);
            return null;
        }
        if (!next_one.flags.compressed) return next_one.payload;
        if (response.coding == .identity) return error.InvalidEnvelope;
        return try compression.decompress(response.coding, response.decoders, next_one.payload, response.storage.scratch.message);
    }

    fn read_end(response: *Response, last: envelope.Envelope) Error!void {
        response.done = true;
        if (!response.reader.at_end()) return error.InvalidEnvelope;
        switch (response.speaks.protocol) {
            .connect => {
                if (!last.flags.end_stream) return error.InvalidEnvelope;
                const end = end_stream.decode(last.payload, .{
                    .tokens = response.storage.scratch.tokens,
                    .octets = response.storage.octets,
                    .details = response.storage.details,
                    .metadata = response.storage.metadata,
                }) catch {
                    response.failure = .{ .code = .internal, .message = "malformed end-stream message" };
                    return;
                };
                response.failure = end.failure;
                response.metadata = end.metadata;
            },
            .grpc_web => {
                if (!last.flags.trailers) return error.InvalidEnvelope;
                const lines = trailers.read_web_frame(last.payload, response.storage.metadata) catch {
                    response.failure = .{ .code = .internal, .message = "malformed trailers frame" };
                    return;
                };
                response.metadata = lines;
                response.failure = trailers.read(lines, find_in, status_storage(response.storage));
            },
            .grpc => return error.InvalidEnvelope,
        }
    }

    fn end_without_status(response: *Response) ?[]const u8 {
        response.done = true;
        response.failure = switch (response.speaks.protocol) {
            // Connect protocol, "Streaming-Response": the end-stream message is mandatory.
            .connect => .{ .code = .internal, .message = "missing end-stream message" },
            .grpc_web => .{ .code = .internal, .message = "missing trailers frame" },
            .grpc => if (response.incoming.trailers) |lookup|
                trailers.read(lookup, find_lookup, status_storage(response.storage))
            else
                .{ .code = .unimplemented, .message = "the HTTP client exposes no gRPC trailers" },
        };
        return null;
    }
};

fn status_storage(storage: Storage) trailers.Storage {
    const half = storage.octets.len / 2;
    return .{ .message = storage.octets[0..half], .status = storage.octets[half..], .details = storage.details };
}

fn find_in(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn find_lookup(lookup: Lookup, name: []const u8) ?[]const u8 {
    return lookup.find(name);
}

/// Starts reading the response of a call that spoke `speaks`.
pub fn read(speaks: protocol.Speaks, incoming: Incoming, storage: Storage, decoders: compression.Decoders) Response {
    var response: Response = .{
        .speaks = speaks,
        .incoming = incoming,
        .storage = storage,
        .decoders = decoders,
        .coding = .identity,
        .reader = .{ .body = incoming.body, .payload_len_max = storage.scratch.message.len },
    };
    if (incoming.status != 200) {
        response.done = true;
        response.failure = http_failure(speaks, incoming, storage);
        return response;
    }
    const coding_name = coding_header(speaks);
    if (incoming.headers.find(coding_name)) |name| {
        response.coding = compression.Coding.from_name(name) orelse {
            response.done = true;
            response.failure = .{ .code = .internal, .message = "unknown response compression" };
            return response;
        };
    }
    // PROTOCOL-HTTP2.md, "Responses": Trailers-Only puts the status in the head.
    if (speaks.protocol != .connect and incoming.headers.find("grpc-status") != null) {
        response.done = true;
        response.failure = trailers.read(incoming.headers, find_lookup, status_storage(storage));
    }
    return response;
}

fn coding_header(speaks: protocol.Speaks) []const u8 {
    return switch (speaks.protocol) {
        .connect => if (speaks.enveloped) "connect-content-encoding" else "content-encoding",
        .grpc, .grpc_web => "grpc-encoding",
    };
}

/// The error of a response whose HTTP status is not 200: a Connect error body when there is one,
/// else the code the status maps to (Connect protocol, "HTTP to Error Code").
fn http_failure(speaks: protocol.Speaks, incoming: Incoming, storage: Storage) RpcError {
    const fallback: RpcError = .{ .code = Code.from_http_status(incoming.status) };
    if (speaks.protocol != .connect) return fallback;
    const content_type = incoming.headers.find("content-type") orelse return fallback;
    if (!std.mem.startsWith(u8, content_type, "application/json")) return fallback;
    const failure = error_json.decode(incoming.body, .{ .tokens = storage.scratch.tokens, .octets = storage.octets, .details = storage.details }) catch return fallback;
    return failure;
}

/// The error a client gives a response it could not read.
pub fn failure_of(failure: Error) RpcError {
    _ = failure;
    return .{ .code = .internal, .message = "malformed response" };
}

test "a non-200 Connect response without a JSON body maps its status to a code" {
    const Empty = struct {
        fn find(_: *const anyopaque, _: []const u8) ?[]const u8 {
            return null;
        }
    };
    var buffers: [4][64]u8 = undefined;
    var details: [1]rpc_error.Detail = undefined;
    var metadata: [1]Header = undefined;
    const storage: Storage = .{
        .scratch = .{ .message = &buffers[0], .work = &buffers[1], .tokens = &buffers[2] },
        .octets = &buffers[3],
        .details = &details,
        .metadata = &metadata,
    };
    const lookup: Lookup = .{ .context = &buffers, .find_fn = Empty.find };
    const response = read(.{ .protocol = .connect, .codec = .proto, .enveloped = false }, .{ .status = 503, .headers = lookup, .body = "busy" }, storage, .{});
    try std.testing.expectEqual(Code.unavailable, response.failure.?.code);
    try std.testing.expect(response.done);
}
