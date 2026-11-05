//! Which protocol and codec a request speaks, read from its method and Content-Type, and the
//! Content-Type each protocol writes (Connect protocol, "Unary-Content-Type" and
//! "Streaming-Content-Type"; PROTOCOL-HTTP2.md, "Content-Type"; PROTOCOL-WEB.md).
const std = @import("std");
const assert = std.debug.assert;

pub const Protocol = enum { connect, grpc, grpc_web };

/// How a message is serialized.
pub const Codec = enum {
    proto,
    json,

    pub fn name(codec: Codec) []const u8 {
        return @tagName(codec);
    }

    pub fn from_name(text: []const u8) ?Codec {
        return std.meta.stringToEnum(Codec, text);
    }
};

/// What a request's head says about the protocol it speaks.
pub const Speaks = struct {
    protocol: Protocol,
    codec: Codec,
    /// Whether the body holds envelopes: every protocol's streams, and every gRPC call.
    enveloped: bool,
};

pub const Error = error{
    /// A Content-Type no protocol here reads: the server answers 415 (Connect protocol,
    /// "Unary-Request"; PROTOCOL-HTTP2.md, "Content-Type").
    UnsupportedMediaType,
};

/// Reads the protocol of a POST from its Content-Type. Parameters after ";" are ignored, as are
/// case differences in the type (RFC 9110 §8.3.1).
pub fn of_content_type(value: []const u8) Error!Speaks {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media = std.mem.trim(u8, value[0..end], " \t");
    var lower: [media_len_max]u8 = undefined;
    if (media.len > lower.len) return error.UnsupportedMediaType;
    const folded = std.ascii.lowerString(&lower, media);
    const application = "application/";
    if (!std.mem.startsWith(u8, folded, application)) return error.UnsupportedMediaType;
    return of_subtype(folded[application.len..]);
}

/// The longest media type `of_content_type` reads.
const media_len_max = 64;

fn of_subtype(subtype: []const u8) Error!Speaks {
    // gRPC: "application/grpc" alone means proto (PROTOCOL-HTTP2.md, "Content-Type").
    if (std.mem.eql(u8, subtype, "grpc")) return .{ .protocol = .grpc, .codec = .proto, .enveloped = true };
    if (std.mem.eql(u8, subtype, "grpc-web")) return .{ .protocol = .grpc_web, .codec = .proto, .enveloped = true };
    if (suffixed(subtype, "grpc-web+")) |codec| return .{ .protocol = .grpc_web, .codec = codec, .enveloped = true };
    if (suffixed(subtype, "grpc+")) |codec| return .{ .protocol = .grpc, .codec = codec, .enveloped = true };
    if (suffixed(subtype, "connect+")) |codec| return .{ .protocol = .connect, .codec = codec, .enveloped = true };
    const codec = Codec.from_name(subtype) orelse return error.UnsupportedMediaType;
    return .{ .protocol = .connect, .codec = codec, .enveloped = false };
}

fn suffixed(subtype: []const u8, prefix: []const u8) ?Codec {
    if (!std.mem.startsWith(u8, subtype, prefix)) return null;
    return Codec.from_name(subtype[prefix.len..]);
}

const Written = struct { protocol: Protocol, codec: Codec, enveloped: bool, value: []const u8 };

/// The Content-Type each protocol writes, for each codec.
const written = [_]Written{
    .{ .protocol = .connect, .codec = .proto, .enveloped = false, .value = "application/proto" },
    .{ .protocol = .connect, .codec = .json, .enveloped = false, .value = "application/json" },
    .{ .protocol = .connect, .codec = .proto, .enveloped = true, .value = "application/connect+proto" },
    .{ .protocol = .connect, .codec = .json, .enveloped = true, .value = "application/connect+json" },
    .{ .protocol = .grpc, .codec = .proto, .enveloped = true, .value = "application/grpc" },
    .{ .protocol = .grpc, .codec = .json, .enveloped = true, .value = "application/grpc+json" },
    .{ .protocol = .grpc_web, .codec = .proto, .enveloped = true, .value = "application/grpc-web+proto" },
    .{ .protocol = .grpc_web, .codec = .json, .enveloped = true, .value = "application/grpc-web+json" },
};

/// The Content-Type a protocol writes for a codec.
pub fn content_type(speaks: Speaks) []const u8 {
    for (written) |entry| {
        const same = entry.protocol == speaks.protocol and entry.codec == speaks.codec and entry.enveloped == speaks.enveloped;
        if (same) return entry.value;
    }
    unreachable;
}

const testing = std.testing;

test "each protocol's content types are read, with parameters and case ignored" {
    const cases = [_]struct { []const u8, Protocol, Codec, bool }{
        .{ "application/proto", .connect, .proto, false },
        .{ "application/json; charset=utf-8", .connect, .json, false },
        .{ "application/connect+json", .connect, .json, true },
        .{ "application/grpc", .grpc, .proto, true },
        .{ "Application/GRPC+json", .grpc, .json, true },
        .{ "application/grpc-web", .grpc_web, .proto, true },
        .{ "application/grpc-web+proto", .grpc_web, .proto, true },
    };
    for (cases) |case| {
        const speaks = try of_content_type(case[0]);
        try testing.expectEqual(case[1], speaks.protocol);
        try testing.expectEqual(case[2], speaks.codec);
        try testing.expectEqual(case[3], speaks.enveloped);
    }
    try testing.expectError(error.UnsupportedMediaType, of_content_type("application/grpc-web-text"));
    try testing.expectError(error.UnsupportedMediaType, of_content_type("text/plain"));
    try testing.expectError(error.UnsupportedMediaType, of_content_type("application/xml"));
}

test "a protocol writes the content type it reads" {
    const speaks: Speaks = .{ .protocol = .grpc_web, .codec = .json, .enveloped = true };
    try testing.expectEqual(speaks, try of_content_type(content_type(speaks)));
    const unary: Speaks = .{ .protocol = .connect, .codec = .proto, .enveloped = false };
    try testing.expectEqual(unary, try of_content_type(content_type(unary)));
}
