//! Connect's end-stream message: the last envelope of a streaming response, flagged 0x02, holding
//! `{"error": {...}, "metadata": {"name": ["value", ...]}}` (Connect protocol,
//! "Streaming-Response" and "Error End-Stream"). Both members are optional.
const std = @import("std");
const json = @import("json");
const codec = @import("codec");
const rpc_error = @import("rpc_error.zig");
const error_json = @import("error_json.zig");
const json_read = @import("json_read.zig");
const constants = @import("constants.zig");
const RpcError = rpc_error.RpcError;
const Header = rpc_error.Header;

pub const EndStream = struct {
    failure: ?RpcError = null,
    metadata: []const Header = &.{},
};

pub fn encode(end: EndStream, buffer: []u8) error_json.EncodeError![]const u8 {
    std.debug.assert(end.metadata.len <= constants.limits.metadata_max);
    var text = json.TextWriter.init(buffer, .text, codec.Features.target());
    try text.begin_object();
    if (end.failure) |failure| {
        try text.name("error");
        try error_json.write(failure, &text);
    }
    if (end.metadata.len != 0) {
        try text.name("metadata");
        try write_metadata(end.metadata, &text);
    }
    try text.end_object();
    return text.written();
}

/// Writes each name once, with every value of that name in order.
fn write_metadata(metadata: []const Header, text: *json.TextWriter) error_json.EncodeError!void {
    try text.begin_object();
    for (metadata, 0..) |header, index| {
        if (seen_before(metadata[0..index], header.name)) continue;
        try text.name(header.name);
        try text.begin_array();
        for (metadata[index..]) |later| {
            if (std.ascii.eqlIgnoreCase(later.name, header.name)) try text.string(later.value);
        }
        try text.end_array();
    }
    try text.end_object();
}

fn seen_before(earlier: []const Header, name: []const u8) bool {
    for (earlier) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
    }
    return false;
}

pub const Storage = struct {
    tokens: []u8,
    octets: []u8,
    details: []rpc_error.Detail,
    metadata: []Header,
};

pub fn decode(payload: []const u8, storage: Storage) json_read.Error!EndStream {
    var tokens = json_read.Tokens.init(payload, storage.tokens, storage.octets);
    try tokens.start();
    try tokens.expect(.begin_object);
    var end: EndStream = .{};
    for (0..payload.len + 1) |_| {
        const name = switch (try tokens.next()) {
            .end_object => break,
            .name => |name| name,
            else => return error.UnexpectedToken,
        };
        if (std.mem.eql(u8, name, "error")) {
            try tokens.expect(.begin_object);
            end.failure = try error_json.read_object(&tokens, storage.details);
        } else if (std.mem.eql(u8, name, "metadata")) {
            end.metadata = try read_metadata(&tokens, storage.metadata);
        } else try tokens.skip_value();
    }
    try tokens.finish();
    return end;
}

fn read_metadata(tokens: *json_read.Tokens, metadata: []Header) json_read.Error![]const Header {
    try tokens.expect(.begin_object);
    var count: usize = 0;
    for (0..tokens.reader.input.len + 1) |_| {
        const name = switch (try tokens.next()) {
            .end_object => return metadata[0..count],
            .name => |name| try tokens.keep(name),
            else => return error.UnexpectedToken,
        };
        try tokens.expect(.begin_array);
        for (0..tokens.reader.input.len + 1) |_| {
            const value = switch (try tokens.next()) {
                .end_array => break,
                .string => |octets| try tokens.keep(octets),
                else => return error.UnexpectedToken,
            };
            if (count == metadata.len) return error.TooManyMetadata;
            metadata[count] = .{ .name = name, .value = value };
            count += 1;
        }
    }
    unreachable;
}

const testing = std.testing;

test "an end-stream message holds the error and the trailers, grouped by name" {
    var buffer: [256]u8 = undefined;
    const end: EndStream = .{
        .failure = .{ .code = .aborted },
        .metadata = &.{ .{ .name = "x-a", .value = "1" }, .{ .name = "x-b", .value = "2" }, .{ .name = "x-a", .value = "3" } },
    };
    const text = try encode(end, &buffer);
    try testing.expectEqualStrings("{\"error\":{\"code\":\"aborted\"},\"metadata\":{\"x-a\":[\"1\",\"3\"],\"x-b\":[\"2\"]}}", text);
    var tokens: [32]u8 = undefined;
    var octets: [64]u8 = undefined;
    var details: [1]rpc_error.Detail = undefined;
    var metadata: [4]Header = undefined;
    const back = try decode(text, .{ .tokens = &tokens, .octets = &octets, .details = &details, .metadata = &metadata });
    try testing.expectEqual(@import("code.zig").Code.aborted, back.failure.?.code);
    try testing.expectEqual(@as(usize, 3), back.metadata.len);
    try testing.expectEqualStrings("3", back.metadata[1].value);
    try testing.expectEqualStrings("{}", try encode(.{}, &buffer));
}
