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
/// A check program decodes and encodes with the build target's CPU features: it runs on the
/// machine it was built for, and a library takes the features its program detected.
const protobuf_decoder: proto.Decoder = .init(.target());
const protobuf_encoder: proto.Encoder = .init(.target());
const pb = @import("conformance_pb");
const proto3 = @import("test_messages_proto3");
const proto2 = @import("test_messages_proto2");
const edition2023 = @import("test_messages_edition2023");
const proto3_editions = @import("test_messages_proto3_editions");
const proto2_editions = @import("test_messages_proto2_editions");
const constants = @import("constants.zig");

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

/// All the program holds, which `main` allocates once before the first request (decision 42).
const State = struct {
    request_bytes: [constants.testee_message_len_max]u8,
    response_bytes: [constants.testee_message_len_max + constants.testee_response_overhead_len]u8,
    /// The test message, written back in the encoding a request names.
    output: [constants.testee_message_len_max]u8,
    /// The binary encoding the JSON decoder writes a JSON payload into, and the octets of one
    /// token at a time.
    transcoded: [constants.testee_message_len_max]u8,
    tokens: [constants.testee_token_len_max]u8,
    in_buffer: [constants.testee_io_buffer_len]u8,
    out_buffer: [constants.testee_io_buffer_len]u8,
    /// The length before a request as the runner wrote it, or before a response.
    prefix: [constants.testee_frame_prefix_len]u8,
};

const Result = @typeInfo(@FieldType(pb.ConformanceResponse, "result")).optional.child;
/// What a JSON payload's read gives beside a message: the decoder's refusal, or the mark of a
/// test this program skips.
const JsonReadError = proto.JsonDecodeError || error{IgnoreUnknownAsked};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    var stdin = std.Io.File.stdin().reader(init.io, &state.in_buffer);
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &state.out_buffer);
    for (0..constants.testee_requests_max) |_| {
        const bytes = try read_request(state, &stdin.interface) orelse return;
        const response: pb.ConformanceResponse = .{ .result = respond(state, bytes) };
        const encoded = try proto.encode(pb.ConformanceResponse, &response, &state.response_bytes);
        std.mem.writeInt(u32, &state.prefix, @intCast(encoded.len), .little);
        try stdout.interface.writeAll(&state.prefix);
        try stdout.interface.writeAll(encoded);
        try stdout.interface.flush();
    }
    return error.TooManyRequests;
}

/// The next request's octets, or null when the runner closed stdin.
fn read_request(state: *State, reader: *std.Io.Reader) !?[]const u8 {
    const prefix_len = try reader.readSliceShort(&state.prefix);
    if (prefix_len == 0) return null;
    if (prefix_len != state.prefix.len) return error.FrameTruncated;
    const len = std.mem.readInt(u32, &state.prefix, .little);
    if (len > state.request_bytes.len) return error.RequestTooLarge;
    try reader.readSliceAll(state.request_bytes[0..len]);
    return state.request_bytes[0..len];
}

fn respond(state: *State, bytes: []const u8) Result {
    const request = protobuf_decoder.decode(pb.ConformanceRequest, bytes) catch |failure| return .{ .runtime_error = @errorName(failure) };
    // The failure list file holds the tests expected to fail, so the set here is empty.
    if (std.mem.eql(u8, request.message_type, failure_set_name)) return .{ .protobuf_payload = "" };
    inline for (messages) |T| {
        if (std.mem.eql(u8, request.message_type, T.protobuf.full_name)) return convert(T, state, &request);
    }
    return .{ .skipped = "the program does not hold this message type" };
}

/// Reads the request's payload as a `T` and writes it in the encoding the request names.
fn convert(comptime T: type, state: *State, request: *const pb.ConformanceRequest) Result {
    const payload = request.payload orelse return .{ .runtime_error = "the request holds no payload" };
    const message = switch (payload) {
        .protobuf_payload => |binary| protobuf_decoder.decode(T, binary) catch |failure| return .{ .parse_error = @errorName(failure) },
        .json_payload => |text| read_json(T, state, request, text) catch |failure| return failure_of(failure),
        .jspb_payload, .text_payload => return .{ .skipped = "the program reads binary and JSON alone" },
    };
    return switch (request.requested_output_format) {
        .protobuf_ => .{ .protobuf_payload = proto.encode(T, &message, &state.output) catch |failure| return .{ .serialize_error = @errorName(failure) } },
        .json => .{ .json_payload = protobuf_encoder.encode_json(T, &message, &state.output) catch |failure| return .{ .serialize_error = @errorName(failure) } },
        else => .{ .skipped = "the program writes binary and JSON alone" },
    };
}

fn read_json(comptime T: type, state: *State, request: *const pb.ConformanceRequest, text: []const u8) JsonReadError!T {
    // connect-zig's JSON decoder refuses a member the message does not name, and has no option
    // to pass over it.
    if (request.test_category == .json_ignore_unknown_parsing_test) return error.IgnoreUnknownAsked;
    return protobuf_decoder.decode_json(T, text, &state.transcoded, &state.tokens);
}

fn failure_of(failure: JsonReadError) Result {
    if (failure == error.IgnoreUnknownAsked) return .{ .skipped = "the JSON decoder has no option to ignore an unknown member" };
    return .{ .parse_error = @errorName(failure) };
}
