//! The program Google's protobuf conformance runner tests (decision 38). The runner writes a
//! `ConformanceRequest` on stdin behind its length, 4 octets in little-endian order, and reads a
//! `ConformanceResponse` on stdout in the same frame ("conformance/conformance.proto"). A
//! request holds a test message in one encoding and names the encoding to write it back in.
//!
//! This program reads and writes binary and JSON. It answers `skipped` for the text format, for
//! JSPB and for a JSON test that asks to ignore unknown members: connect-zig has none of the
//! three. A refusal to read is a `parse_error`, and a refusal to write a `serialize_error`.
const std = @import("std");
const proto = @import("protobuf");
const pb = @import("conformance_pb");
const proto3 = @import("test_messages_proto3");
const proto2 = @import("test_messages_proto2");
const edition2023 = @import("test_messages_edition2023");
const proto3_editions = @import("test_messages_proto3_editions");
const proto2_editions = @import("test_messages_proto2_editions");

/// The test messages a request can name, up to edition 2023.
const messages = [_]type{
    proto3.TestAllTypesProto3,
    proto2.TestAllTypesProto2,
    edition2023.TestAllTypesEdition2023,
    proto3_editions.TestAllTypesProto3,
    proto2_editions.TestAllTypesProto2,
};

/// An Any in a test names a test message or a well-known type (decision 21).
pub const protobuf_any_types: []const type = &messages;

pub const Error = error{ FrameTruncated, RequestTooLarge, TooManyRequests };

/// The name the runner asks first, for the tests the program expects to fail.
const failure_set_name = "conformance.FailureSet";
/// The length before each request and each response: 4 octets, little-endian.
const frame_prefix_len = 4;
/// The largest test message, in either encoding, and the room a response takes beside it.
const message_len_max = 1 << 20;
const response_overhead_len = 64;
/// The longest JSON token: a string's octets.
const token_len_max = 1 << 16;
const io_buffer_len = 1 << 12;
/// The requests one run of the runner sends stay far below this bound.
const requests_max = 1 << 24;

var request_bytes: [message_len_max]u8 = undefined;
var response_bytes: [message_len_max + response_overhead_len]u8 = undefined;
var output: [message_len_max]u8 = undefined;
var transcoded: [message_len_max]u8 = undefined;
var tokens: [token_len_max]u8 = undefined;
var in_buffer: [io_buffer_len]u8 = undefined;
var out_buffer: [io_buffer_len]u8 = undefined;

const Result = @typeInfo(@FieldType(pb.ConformanceResponse, "result")).optional.child;
/// What a JSON payload's read gives beside a message: the decoder's refusal, or the mark of a
/// test this program skips.
const JsonReadError = proto.JsonDecodeError || error{IgnoreUnknownAsked};

pub fn main(init: std.process.Init) !void {
    var stdin = std.Io.File.stdin().reader(init.io, &in_buffer);
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);
    for (0..requests_max) |_| {
        const bytes = try read_request(&stdin.interface) orelse return;
        const response: pb.ConformanceResponse = .{ .result = respond(bytes) };
        const encoded = try proto.encode(pb.ConformanceResponse, &response, &response_bytes);
        var prefix: [frame_prefix_len]u8 = undefined;
        std.mem.writeInt(u32, &prefix, @intCast(encoded.len), .little);
        try stdout.interface.writeAll(&prefix);
        try stdout.interface.writeAll(encoded);
        try stdout.interface.flush();
    }
    return error.TooManyRequests;
}

/// The next request's octets, or null when the runner closed stdin.
fn read_request(reader: *std.Io.Reader) !?[]const u8 {
    var prefix: [frame_prefix_len]u8 = undefined;
    const prefix_len = try reader.readSliceShort(&prefix);
    if (prefix_len == 0) return null;
    if (prefix_len != prefix.len) return error.FrameTruncated;
    const len = std.mem.readInt(u32, &prefix, .little);
    if (len > request_bytes.len) return error.RequestTooLarge;
    try reader.readSliceAll(request_bytes[0..len]);
    return request_bytes[0..len];
}

fn respond(bytes: []const u8) Result {
    const request = proto.decode(pb.ConformanceRequest, bytes) catch |failure| return .{ .runtime_error = @errorName(failure) };
    // The failure list file holds the tests expected to fail, so the set here is empty.
    if (std.mem.eql(u8, request.message_type, failure_set_name)) return .{ .protobuf_payload = "" };
    inline for (messages) |T| {
        if (std.mem.eql(u8, request.message_type, T.protobuf.full_name)) return convert(T, &request);
    }
    return .{ .skipped = "the program does not hold this message type" };
}

/// Reads the request's payload as a `T` and writes it in the encoding the request names.
fn convert(comptime T: type, request: *const pb.ConformanceRequest) Result {
    const payload = request.payload orelse return .{ .runtime_error = "the request holds no payload" };
    const message = switch (payload) {
        .protobuf_payload => |binary| proto.decode(T, binary) catch |failure| return .{ .parse_error = @errorName(failure) },
        .json_payload => |text| read_json(T, request, text) catch |failure| return failure_of(failure),
        .jspb_payload, .text_payload => return .{ .skipped = "the program reads binary and JSON alone" },
    };
    return switch (request.requested_output_format) {
        .protobuf_ => .{ .protobuf_payload = proto.encode(T, &message, &output) catch |failure| return .{ .serialize_error = @errorName(failure) } },
        .json => .{ .json_payload = proto.encode_json(T, &message, &output) catch |failure| return .{ .serialize_error = @errorName(failure) } },
        else => .{ .skipped = "the program writes binary and JSON alone" },
    };
}

fn read_json(comptime T: type, request: *const pb.ConformanceRequest, text: []const u8) JsonReadError!T {
    // connect-zig's JSON decoder refuses a member the message does not name, and has no option
    // to pass over it.
    if (request.test_category == .json_ignore_unknown_parsing_test) return error.IgnoreUnknownAsked;
    return proto.decode_json(T, text, &transcoded, &tokens);
}

fn failure_of(failure: JsonReadError) Result {
    if (failure == error.IgnoreUnknownAsked) return .{ .skipped = "the JSON decoder has no option to ignore an unknown member" };
    return .{ .parse_error = @errorName(failure) };
}
