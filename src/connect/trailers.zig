//! gRPC's status trailers, and gRPC-Web's trailers frame (PROTOCOL-HTTP2.md, "Responses";
//! PROTOCOL-WEB.md, "Protocol differences vs gRPC over HTTP2").
//!
//! - `grpc-status` is the code's decimal number.
//! - `grpc-message` is percent-encoded: octets outside 0x20 to 0x7E, and "%", become "%XX".
//! - `grpc-status-details-bin` is the base64 of a google.rpc.Status; a reader accepts it padded or
//!   not, as every "-bin" header (PROTOCOL-HTTP2.md, "Custom-Metadata").
//! - gRPC-Web carries the same trailers in a body frame flagged 0x80, as HTTP/1.1 header lines.
const std = @import("std");
const assert = std.debug.assert;
const rpc_error = @import("rpc_error.zig");
const json_read = @import("json_read.zig");
const envelope = @import("envelope.zig");
const constants = @import("constants.zig");
const protocol = constants.protocol;
const Code = @import("code.zig").Code;
const RpcError = rpc_error.RpcError;
const Header = rpc_error.Header;

/// The trailers `write` returns at most: status, message and details.
pub const trailers_max = 3;

pub const Error = error{ NoSpaceLeft, TooManyDetails } || @import("protobuf").EncodeError;

/// Writes the status trailers of `failure`, or of success when null, into `buffer`.
/// `out` holds at least `trailers_max` headers.
pub fn write(failure: ?RpcError, buffer: []u8, out: []Header) Error![]const Header {
    assert(out.len >= trailers_max);
    const status = failure orelse {
        out[0] = .{ .name = "grpc-status", .value = "0" };
        return out[0..1];
    };
    assert(status.code != .ok);
    var used: usize = 0;
    var count: usize = 0;
    const number = std.fmt.bufPrint(buffer, "{d}", .{@intFromEnum(status.code)}) catch return error.NoSpaceLeft;
    used += number.len;
    count = add(out, count, "grpc-status", number);
    const message = try percent_encode(status.message, buffer[used..]);
    used += message.len;
    count = add(out, count, "grpc-message", message);
    if (status.details.len == 0) return out[0..count];
    // The Status's octets go in the second half of the room, and their base64 in the first.
    const half = (buffer.len - used) / constants.storage_halves;
    const status_bytes = try rpc_error.encode_status(status, buffer[used + half ..], buffer[used..][0..half]);
    const encoder = std.base64.standard_no_pad.Encoder;
    if (encoder.calcSize(status_bytes.len) > half) return error.NoSpaceLeft;
    const details = encoder.encode(buffer[used..][0..half], status_bytes);
    count = add(out, count, "grpc-status-details-bin", details);
    return out[0..count];
}

fn add(out: []Header, count: usize, name: []const u8, value: []const u8) usize {
    assert(count < trailers_max);
    out[count] = .{ .name = name, .value = value };
    return count + 1;
}

/// Percent-encodes a grpc-message value (PROTOCOL-HTTP2.md, "Responses": Status-Message).
pub fn percent_encode(message: []const u8, buffer: []u8) error{NoSpaceLeft}![]const u8 {
    var len: usize = 0;
    for (message) |octet| {
        const plain = octet >= protocol.printable_first and octet <= protocol.printable_last and octet != '%';
        const width: usize = if (plain) 1 else protocol.percent_escape_len;
        if (len + width > buffer.len) return error.NoSpaceLeft;
        if (plain) {
            buffer[len] = octet;
        } else {
            _ = std.fmt.bufPrint(buffer[len..][0..protocol.percent_escape_len], "%{X:0>2}", .{octet}) catch unreachable;
        }
        len += width;
    }
    return buffer[0..len];
}

/// Decodes a grpc-message value. A "%" that two hex digits do not follow is kept as it is: the
/// reader must not fail on a malformed value (PROTOCOL-HTTP2.md, "Responses").
pub fn percent_decode(value: []const u8, buffer: []u8) []const u8 {
    assert(buffer.len >= value.len);
    var len: usize = 0;
    var index: usize = 0;
    for (0..value.len) |_| {
        if (index >= value.len) break;
        const escape_len = protocol.percent_escape_len;
        const decoded = if (value[index] == '%' and index + escape_len <= value.len)
            std.fmt.parseInt(u8, value[index + 1 .. index + escape_len], protocol.hex_base) catch null
        else
            null;
        if (decoded) |octet| {
            buffer[len] = octet;
            index += escape_len;
        } else {
            buffer[len] = value[index];
            index += 1;
        }
        len += 1;
    }
    return buffer[0..len];
}

/// What a client reads from the trailers: success, or an error.
pub const Storage = struct {
    message: []u8,
    status: []u8,
    details: []rpc_error.Detail,
};

/// Reads the status trailers through `find`, which returns a trailer's value by name. Null means
/// success. A missing or malformed grpc-status reads as `unknown`.
pub fn read(context: anytype, comptime find: fn (@TypeOf(context), []const u8) ?[]const u8, storage: Storage) ?RpcError {
    const status_text = find(context, "grpc-status") orelse return .{ .code = .unknown, .message = "missing grpc-status" };
    const number = std.fmt.parseInt(u32, status_text, protocol.decimal_base) catch return .{ .code = .unknown, .message = "malformed grpc-status" };
    const code = Code.from_number(number);
    if (code == .ok) return null;
    var failure: RpcError = .{ .code = code };
    if (find(context, "grpc-message")) |message| {
        failure.message = percent_decode(message, storage.message[0..@min(storage.message.len, message.len)]);
    }
    const details_text = find(context, "grpc-status-details-bin") orelse return failure;
    const bytes = decode_bin(details_text, storage.status) orelse return failure;
    const status = rpc_error.decode_status(bytes, storage.details) catch return failure;
    failure.details = status.details;
    return failure;
}

fn decode_bin(text: []const u8, buffer: []u8) ?[]const u8 {
    return json_read.decode_base64(std.base64.standard_no_pad.Decoder, text, buffer) catch null;
}

/// Writes gRPC-Web's trailers frame: the 0x80 envelope of the trailers as header lines.
pub fn write_web_frame(trailers: []const Header, buffer: []u8) error{NoSpaceLeft}![]const u8 {
    const prefix_len = constants.protocol.envelope_prefix_len;
    if (buffer.len < prefix_len) return error.NoSpaceLeft;
    var len: usize = prefix_len;
    for (trailers) |trailer| {
        // PROTOCOL-WEB.md: the frame holds HTTP/1.1 header lines with lowercase names.
        const line = std.fmt.bufPrint(buffer[len..], "{s}: {s}\r\n", .{ trailer.name, trailer.value }) catch return error.NoSpaceLeft;
        for (line[0..trailer.name.len]) |*octet| octet.* = std.ascii.toLower(octet.*);
        len += line.len;
    }
    envelope.write_prefix(.{ .trailers = true }, len - prefix_len, buffer[0..prefix_len]);
    return buffer[0..len];
}

/// Reads the header lines of a trailers frame's payload.
pub fn read_web_frame(payload: []const u8, out: []Header) error{ MalformedTrailers, TooManyMetadata }![]const Header {
    var lines = std.mem.splitSequence(u8, payload, "\r\n");
    var count: usize = 0;
    for (0..constants.limits.metadata_max + 1) |_| {
        const line = lines.next() orelse return out[0..count];
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedTrailers;
        if (count == out.len) return error.TooManyMetadata;
        out[count] = .{ .name = line[0..colon], .value = std.mem.trim(u8, line[colon + 1 ..], " \t") };
        count += 1;
    }
    return error.TooManyMetadata;
}

const testing = std.testing;

test "grpc-message is percent-encoded, and malformed escapes are kept" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("50%25 d%C3%A9j%C3%A0", try percent_encode("50% déjà", &buffer));
    var decoded: [64]u8 = undefined;
    try testing.expectEqualStrings("50% déjà", percent_decode("50%25 d%C3%A9j%C3%A0", &decoded));
    try testing.expectEqualStrings("%zz%4", percent_decode("%zz%4", &decoded));
}

test "status trailers round-trip, details included" {
    var buffer: [256]u8 = undefined;
    var out: [trailers_max]Header = undefined;
    const failure: RpcError = .{ .code = .permission_denied, .message = "no", .details = &.{.{ .type_name = "a.B", .value = "x" }} };
    const written = try write(failure, &buffer, &out);
    try testing.expectEqualStrings("7", written[0].value);
    var message: [16]u8 = undefined;
    var status: [64]u8 = undefined;
    var details: [2]rpc_error.Detail = undefined;
    const back = read(written, rpc_error.find_header, .{ .message = &message, .status = &status, .details = &details }).?;
    try testing.expectEqual(Code.permission_denied, back.code);
    try testing.expectEqualStrings("no", back.message);
    try testing.expectEqualStrings("a.B", back.details[0].type_name);
    const ok = try write(null, &buffer, &out);
    try testing.expectEqual(@as(?RpcError, null), read(ok, rpc_error.find_header, .{ .message = &message, .status = &status, .details = &details }));
}

test "a gRPC-Web trailers frame is an 0x80 envelope of lowercase header lines" {
    var buffer: [64]u8 = undefined;
    const frame = try write_web_frame(&.{.{ .name = "Grpc-Status", .value = "0" }}, &buffer);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0, 0, 0, 16 }, frame[0..5]);
    try testing.expectEqualStrings("grpc-status: 0\r\n", frame[5..]);
    var out: [4]Header = undefined;
    const read_back = try read_web_frame(frame[5..], &out);
    try testing.expectEqualStrings("0", read_back[0].value);
}
