//! The Connect error body: `{"code": ..., "message": ..., "details": [{"type": ..., "value": ...}]}`
//! (Connect protocol, "Error End-Stream" and "Unary-Response"). A detail's value is its binary
//! encoding in standard base64, written without padding.
const std = @import("std");
const json = @import("json");
const codec = @import("codec");
const rpc_error = @import("rpc_error.zig");
const json_read = @import("json_read.zig");
const Code = @import("code.zig").Code;
const RpcError = rpc_error.RpcError;
const Detail = rpc_error.Detail;

pub const EncodeError = json.EncodeError || error{NoSpaceLeft};

pub fn encode(failure: *const RpcError, buffer: []u8) EncodeError![]const u8 {
    var text = json.TextWriter.init(buffer, .text, codec.Features.target());
    try write(failure, &text);
    return text.written();
}

pub fn write(failure: *const RpcError, text: *json.TextWriter) EncodeError!void {
    std.debug.assert(failure.code != .ok);
    try text.begin_object();
    try text.name("code");
    try text.string(failure.code.name());
    if (failure.message.len != 0) {
        try text.name("message");
        try text.string(failure.message);
    }
    if (failure.details.len != 0) {
        try text.name("details");
        try text.begin_array();
        for (failure.details) |detail| {
            try text.begin_object();
            try text.name("type");
            try text.string(detail.type_name);
            try text.name("value");
            try json_read.write_base64(detail.value, text);
            try text.end_object();
        }
        try text.end_array();
    }
    try text.end_object();
}

/// Where a decoded error's strings and details go.
pub const Storage = struct {
    /// One token's octets at a time.
    tokens: []u8,
    /// The message, each detail's type and each detail's decoded value.
    octets: []u8,
    details: []Detail,
};

/// Reads an error body. A code the body does not name, or names wrongly, reads as `unknown`
/// (Connect protocol, "Error Codes").
/// What `decode` and `read_object` return on a body they cannot read.
pub const DecodeError = json_read.Error;

pub fn decode(body: []const u8, storage: *const Storage) DecodeError!RpcError {
    var tokens = json_read.Tokens.init(body, storage.tokens, storage.octets);
    try tokens.start();
    try tokens.expect(.begin_object);
    const failure = try read_object(&tokens, storage.details);
    try tokens.finish();
    return failure;
}

/// Reads the members of an error object whose `{` was read.
pub fn read_object(tokens: *json_read.Tokens, details: []Detail) DecodeError!RpcError {
    var failure: RpcError = .{ .code = .unknown };
    for (0..tokens.reader.input.len + 1) |_| {
        const member = switch (try tokens.next()) {
            .end_object => return failure,
            .name => |name| member_of(name),
            else => return error.UnexpectedToken,
        };
        switch (member) {
            .code => failure.code = code_of(try tokens.keep_string()),
            .message => failure.message = try tokens.keep_string(),
            .details => failure.details = try read_details(tokens, details),
            .other => try tokens.skip_value(),
        }
    }
    unreachable;
}

const Member = enum { code, message, details, other };

fn member_of(name: []const u8) Member {
    return std.meta.stringToEnum(Member, name) orelse .other;
}

fn code_of(name: []const u8) Code {
    const code = Code.from_name(name) orelse return .unknown;
    return if (code == .ok) .unknown else code;
}

fn read_details(tokens: *json_read.Tokens, details: []Detail) json_read.Error![]const Detail {
    try tokens.expect(.begin_array);
    var count: usize = 0;
    for (0..tokens.reader.input.len + 1) |_| {
        switch (try tokens.next()) {
            .end_array => return details[0..count],
            .begin_object => {},
            else => return error.UnexpectedToken,
        }
        if (count == details.len) return error.TooManyDetails;
        details[count] = try read_detail(tokens);
        count += 1;
    }
    unreachable;
}

fn read_detail(tokens: *json_read.Tokens) json_read.Error!Detail {
    var detail: Detail = .{ .type_name = "", .value = "" };
    for (0..tokens.reader.input.len + 1) |_| {
        const name = switch (try tokens.next()) {
            .end_object => return detail,
            .name => |name| name,
            else => return error.UnexpectedToken,
        };
        if (std.mem.eql(u8, name, "type")) {
            detail.type_name = try tokens.keep_string();
        } else if (std.mem.eql(u8, name, "value")) {
            detail.value = try tokens.keep_base64();
        } else try tokens.skip_value();
    }
    unreachable;
}

const testing = std.testing;

test "an error body is written with its code's name and unpadded details" {
    var buffer: [256]u8 = undefined;
    const failure: RpcError = .{ .code = .unavailable, .message = "busy", .details = &.{.{ .type_name = "a.B", .value = &.{0xff} }} };
    try testing.expectEqualStrings(
        "{\"code\":\"unavailable\",\"message\":\"busy\",\"details\":[{\"type\":\"a.B\",\"value\":\"/w\"}]}",
        try encode(&failure, &buffer),
    );
}

test "an error body reads back, with padding, unknown members and an unknown code" {
    var tokens: [64]u8 = undefined;
    var octets: [64]u8 = undefined;
    var details: [2]Detail = undefined;
    const storage: Storage = .{ .tokens = &tokens, .octets = &octets, .details = &details };
    const body = "{\"code\":\"not_found\",\"debug\":{\"x\":[1]},\"details\":[{\"type\":\"a.B\",\"value\":\"/w==\",\"debug\":1}]}";
    const failure = try decode(body, &storage);
    try testing.expectEqual(Code.not_found, failure.code);
    try testing.expectEqualSlices(u8, &.{0xff}, failure.details[0].value);
    try testing.expectEqual(Code.unknown, (try decode("{\"code\":\"teapot\"}", &storage)).code);
    try testing.expectEqual(Code.unknown, (try decode("{\"code\":\"ok\"}", &storage)).code);
    try testing.expectError(error.TooManyDetails, decode("{\"details\":[{},{},{}]}", &storage));
}
