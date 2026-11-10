//! A unary request sent as a GET, for a method with no side effects (Connect protocol,
//! "Unary-Get-Request"). The query carries the message and how to read it:
//!
//! - `message`: the encoded message, in URL-safe base64 when `base64=1`, else percent-encoded;
//! - `encoding`: the codec's name, "proto" or "json";
//! - `compression`: the coding, when the message is compressed;
//! - `connect=v1`: the protocol version.
const std = @import("std");
const base64 = @import("base64");
const Features = @import("codec").Features;
const json_read = @import("json_read.zig");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");
const compression = @import("compression.zig");
const constants = @import("constants.zig");
const Codec = protocol.Codec;
const Coding = compression.Coding;

/// Base64 pads with at most two "=", which a query may percent-encode.
const base64_padding_max = 2;
const escaped_padding = "%3D";

pub const Error = error{
    /// The query holds no `message` or no `encoding`, or names one this module does not read.
    InvalidQuery,
    /// `connect` names a version other than v1.
    UnsupportedVersion,
    InvalidBase64,
    NoSpaceLeft,
};

/// Writes the query of a GET for an encoded message, without the "?".
pub fn write_query(codec: Codec, coding: Coding, message: []const u8, buffer: []u8) error{NoSpaceLeft}![]const u8 {
    const head = if (coding == .identity)
        std.fmt.bufPrint(buffer, "connect=v1&encoding={s}&base64=1&message=", .{codec.name()})
    else
        std.fmt.bufPrint(buffer, "connect=v1&encoding={s}&compression={s}&base64=1&message=", .{ codec.name(), coding.name() });
    const written = head catch return error.NoSpaceLeft;
    // Connect protocol, "Unary-Get-Request": the URL-safe alphabet, padding omitted.
    var encoder: base64.Encoder = undefined;
    encoder.init(.{ .alphabet = .url_safe, .padding = false }, Features.target());
    const len = try encoder.encode_all(message, buffer[written.len..]);
    return buffer[0 .. written.len + len];
}

pub const Query = struct {
    codec: Codec,
    coding: Coding = .identity,
    /// The message as the query holds it, still encoded.
    message: []const u8,
    base64: bool = false,
};

pub fn read_query(query: []const u8) Error!Query {
    var state: QueryState = .{};
    var pairs = std.mem.splitScalar(u8, query, '&');
    for (0..constants.limits.query_pairs_max) |_| {
        const pair = pairs.next() orelse break;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const value = if (equals < pair.len) pair[equals + 1 ..] else "";
        try state.apply(pair[0..equals], value);
    }
    return .{
        .codec = state.codec orelse return error.InvalidQuery,
        .message = state.message orelse return error.InvalidQuery,
        .coding = state.coding,
        .base64 = state.base64,
    };
}

const QueryState = struct {
    codec: ?Codec = null,
    message: ?[]const u8 = null,
    coding: Coding = .identity,
    base64: bool = false,

    fn apply(state: *QueryState, name: []const u8, value: []const u8) Error!void {
        const Name = enum { message, encoding, compression, base64, connect };
        const known = std.meta.stringToEnum(Name, name) orelse return;
        switch (known) {
            .message => state.message = value,
            .encoding => state.codec = Codec.from_name(value) orelse return error.InvalidQuery,
            .compression => state.coding = Coding.from_name(value) orelse return error.InvalidQuery,
            .base64 => state.base64 = std.mem.eql(u8, value, "1"),
            // Connect protocol, "Unary-Get-Request": connect=v1 names the version.
            .connect => if (!std.mem.eql(u8, value, "v1")) return error.UnsupportedVersion,
        }
    }
};

/// The message's octets, decoded from the query into `buffer`.
pub fn message_octets(query: Query, buffer: []u8) Error![]const u8 {
    if (!query.base64) return percent_decode(query.message, buffer);
    // Padding arrives as "=" or as "%3D", and either alphabet is read.
    var text = query.message;
    // Base64 pads with at most two "=".
    for (0..base64_padding_max) |_| {
        if (std.mem.endsWith(u8, text, escaped_padding)) text = text[0 .. text.len - escaped_padding.len];
        if (std.mem.endsWith(u8, text, "=")) text = text[0 .. text.len - 1];
    }
    return json_read.decode_base64(.either, text, buffer);
}

fn percent_decode(text: []const u8, buffer: []u8) Error![]const u8 {
    var len: usize = 0;
    var index: usize = 0;
    for (0..text.len) |_| {
        if (index == text.len) break;
        if (len == buffer.len) return error.NoSpaceLeft;
        const decoded = try decode_one(text[index..]);
        buffer[len] = decoded.octet;
        index += decoded.len;
        len += 1;
    }
    return buffer[0..len];
}

/// The octet `text` starts with, unescaped, and the octets it took.
fn decode_one(text: []const u8) Error!struct { octet: u8, len: usize } {
    assert(text.len > 0);
    // WHATWG URL, application/x-www-form-urlencoded: "+" stands for a space.
    if (text[0] == '+') return .{ .octet = ' ', .len = 1 };
    if (text[0] != '%') return .{ .octet = text[0], .len = 1 };
    const escape_len = constants.protocol.percent_escape_len;
    if (text.len < escape_len) return error.InvalidQuery;
    const octet = std.fmt.parseInt(u8, text[1..escape_len], constants.protocol.hex_base) catch return error.InvalidQuery;
    return .{ .octet = octet, .len = escape_len };
}

const testing = std.testing;

test "a GET query carries the message in URL-safe base64 and reads back" {
    var buffer: [128]u8 = undefined;
    const query = try write_query(.proto, .gzip, &.{ 0xfb, 0xff }, &buffer);
    try testing.expectEqualStrings("connect=v1&encoding=proto&compression=gzip&base64=1&message=-_8", query);
    const read = try read_query(query);
    try testing.expectEqual(Codec.proto, read.codec);
    try testing.expectEqual(Coding.gzip, read.coding);
    var octets: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, try message_octets(read, &octets));
}

test "a JSON message may be percent-encoded, and a bad query is refused" {
    const read = try read_query("encoding=json&message=%7B%22a%22%3A1%7D");
    var octets: [16]u8 = undefined;
    try testing.expectEqualStrings("{\"a\":1}", try message_octets(read, &octets));
    try testing.expectError(error.InvalidQuery, read_query("message=e30"));
    try testing.expectError(error.UnsupportedVersion, read_query("connect=v2&encoding=json&message=e30"));
    const padded = try read_query("encoding=proto&base64=1&message=-w%3D%3D");
    try testing.expectEqualSlices(u8, &.{0xfb}, try message_octets(padded, &octets));
}
