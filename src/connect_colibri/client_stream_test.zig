//! A streamed `ClientCall` against a pool that records what the call hands it: each request
//! message goes as a piece, the next waits for `body_taken`, and the response's envelopes are
//! read whole however its pieces split them (colibri decision 153 ruling 7; decision 18 as
//! amended).
const std = @import("std");
const testing = std.testing;
const connect = @import("connect");
const client = @import("client");
const proto = @import("protobuf");
const rpc = @import("connect_colibri.zig");
const write_lines = @import("connect_colibri_test.zig").write_lines;

const Note = struct {
    text: []const u8 = "",
    pub const FieldNumber = enum(u29) { text = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Note", .fields = &.{
        proto.field_of(FieldNumber.text, .string, .{}),
    } };
};

const chat: connect.Method = .{ .service = "test.Svc", .name = "Chat", .Request = Note, .Response = Note, .stream_type = .bidi_stream };

/// The pieces a test pool records, at most, and the octets of all of them.
const pieces_max = 8;
const log_len = 256;
/// The id the test pool gives its one call: any id but 0, which no request has.
const test_id_number = 7;
const test_id: client.RequestId = @enumFromInt(test_id_number);

/// A pool that takes one call, and records each piece and each release.
const RecordingPool = struct {
    streamed: client.Streamed = .{},
    log: [log_len]u8 = undefined,
    log_len: usize = 0,
    ends: [pieces_max]client.PieceEnd = undefined,
    starts: [pieces_max + 1]usize = .{0} ** (pieces_max + 1),
    count: usize = 0,
    released: u32 = 0,

    pub fn request(pool: *RecordingPool, message: *const client.Request, _: *client.Response) client.RequestError!client.RequestId {
        pool.streamed = message.streamed;
        return test_id;
    }

    pub fn write_body(pool: *RecordingPool, id: client.RequestId, piece: []const u8, end: client.PieceEnd) client.WriteBodyError!void {
        if (id != test_id) return error.UnknownRequest;
        @memcpy(pool.log[pool.log_len..][0..piece.len], piece);
        pool.log_len += piece.len;
        pool.ends[pool.count] = end;
        pool.count += 1;
        pool.starts[pool.count] = pool.log_len;
    }

    pub fn release_body(pool: *RecordingPool, id: client.RequestId) void {
        std.debug.assert(id == test_id);
        pool.released += 1;
    }

    fn piece_at(pool: *const RecordingPool, index: usize) []const u8 {
        return pool.log[pool.starts[index]..pool.starts[index + 1]];
    }
};

/// Sees what the interceptors of a streamed call see.
const Seen = struct {
    threadlocal var request_body_len: usize = 1;
    threadlocal var responses: u32 = 0;

    pub fn on_request(request: *connect.client.Request) !void {
        request_body_len = request.body.len;
    }

    pub fn on_response(_: *connect.client.Response) void {
        responses += 1;
    }
};

const Call = rpc.ClientCall(chat, .{ .interceptors = &.{Seen}, .pool = RecordingPool });
/// The octets of a piece of the response, fewer than an envelope, and of the gathered response.
const piece_len = 3;
const gathered_len = 16;

/// The octets of each other buffer of a test call, and the details and metadata it reads.
const buffer_len = 128;
const entries_max = 4;

/// A buffer of a test call.
const Buffer = [buffer_len]u8;

const Fixture = struct {
    call: Call = undefined,
    pool: RecordingPool = .{},
    request_body: Buffer = undefined,
    request_message: Buffer = undefined,
    request_work: Buffer = undefined,
    values: Buffer = undefined,
    headers: Buffer = undefined,
    trailers: Buffer = undefined,
    piece: [piece_len]u8 = undefined,
    gathered: [gathered_len]u8 = undefined,
    message: Buffer = undefined,
    work: Buffer = undefined,
    tokens: Buffer = undefined,
    octets: Buffer = undefined,
    details: [entries_max]connect.Detail = undefined,
    metadata: [entries_max]connect.Header = undefined,

    fn start(fixture: *Fixture, options: *const connect.client.Options) !void {
        try fixture.call.init_stream(options, &.{
            .request = .{
                .body = &fixture.request_body,
                .scratch = .{ .message = &fixture.request_message, .work = &fixture.request_work, .tokens = &.{} },
                .values = &fixture.values,
            },
            .headers = &fixture.headers,
            .trailers = &fixture.trailers,
            .body = &fixture.gathered,
            .piece = &fixture.piece,
        });
        try fixture.call.start(&fixture.pool);
    }

    fn storage(fixture: *Fixture) connect.client.Storage {
        return .{
            .scratch = .{ .message = &fixture.message, .work = &fixture.work, .tokens = &fixture.tokens },
            .octets = &fixture.octets,
            .details = &fixture.details,
            .metadata = &fixture.metadata,
        };
    }

    /// Passes `body` to the call in pieces of `piece_len`, as colibri's `body` events do, and
    /// returns the texts of the messages the reader read meanwhile, one after another.
    fn arrive(fixture: *Fixture, body: []const u8, texts: []u8) ![]const u8 {
        var texts_len: usize = 0;
        var offset: usize = 0;
        for (0..body.len) |_| {
            if (offset == body.len) break;
            const len = @min(piece_len, body.len - offset);
            @memcpy(fixture.call.response.body[0..len], body[offset..][0..len]);
            offset += len;
            fixture.call.on_body(len);
            for (0..pieces_max) |_| {
                const note = try fixture.call.reader.next(Note) orelse break;
                @memcpy(texts[texts_len..][0..note.text.len], note.text);
                texts_len += note.text.len;
            }
        }
        return texts[0..texts_len];
    }
};

test "a streamed call hands each message as a piece, and the next waits for body_taken" {
    var fixture: Fixture = .{};
    try fixture.start(&.{});
    try testing.expect(fixture.pool.streamed.request and fixture.pool.streamed.response);
    // The interceptors saw the request before any message.
    try testing.expectEqual(@as(usize, 0), Seen.request_body_len);
    var sender = fixture.call.sender();
    try sender.send(&.{ .text = "a" });
    try sender.send(&.{ .text = "b" });
    try sender.close_send();
    try testing.expectEqual(@as(usize, 1), fixture.pool.count);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 3, 0x0a, 1, 'a' }, fixture.pool.piece_at(0));
    try testing.expectEqual(client.PieceEnd.more, fixture.pool.ends[0]);
    try fixture.call.on_body_taken();
    try testing.expectEqual(@as(usize, 2), fixture.pool.count);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 3, 0x0a, 1, 'b' }, fixture.pool.piece_at(1));
    try testing.expectEqual(client.PieceEnd.last, fixture.pool.ends[1]);
    try fixture.call.on_body_taken();
    try testing.expectEqual(@as(usize, 2), fixture.pool.count);
    // RFC 9113 §8.1: nothing follows the end of the request's content.
    try testing.expectError(error.BodyEnded, sender.send(&.{ .text = "c" }));
    try testing.expectError(error.BodyEnded, sender.close_send());
}

test "a stream closed with nothing queued ends with an empty last piece" {
    var fixture: Fixture = .{};
    try fixture.start(&.{ .protocol = .grpc });
    var sender = fixture.call.sender();
    try sender.close_send();
    try testing.expectEqual(@as(usize, 1), fixture.pool.count);
    try testing.expectEqual(@as(usize, 0), fixture.pool.piece_at(0).len);
    try testing.expectEqual(client.PieceEnd.last, fixture.pool.ends[0]);
}

test "a message that does not fit after the held piece waits for body_taken" {
    var fixture: Fixture = .{};
    try fixture.start(&.{});
    var sender = fixture.call.sender();
    const long = "x" ** 100;
    try sender.send(&.{ .text = long });
    try testing.expectError(error.PieceHeld, sender.send(&.{ .text = long }));
    try fixture.call.on_body_taken();
    try sender.send(&.{ .text = long });
    try testing.expectEqual(@as(usize, 2), fixture.pool.count);
}

test "a streamed response reads each message as its pieces arrive, and the outcome at the end" {
    var fixture: Fixture = .{};
    try fixture.start(&.{});
    fixture.call.response.status = .ok;
    write_lines(&fixture.call.response.headers, &.{.{ .name = "content-type", .value = "application/connect+proto" }});
    const responses = Seen.responses;
    fixture.call.on_headers(fixture.storage());
    try testing.expectEqual(responses + 1, Seen.responses);
    // "a", then "bc", then the end-stream message "{}", in pieces of three octets.
    const body = [_]u8{ 0, 0, 0, 0, 3, 0x0a, 1, 'a', 0, 0, 0, 0, 4, 0x0a, 2, 'b', 'c', 2, 0, 0, 0, 2, '{', '}' };
    var texts: [8]u8 = undefined;
    try testing.expectEqualStrings("abc", try fixture.arrive(&body, &texts));
    try testing.expectEqual(@as(u32, (body.len + piece_len - 1) / piece_len), fixture.pool.released);
    fixture.call.response.result = .response;
    var response = fixture.call.read(fixture.storage());
    try testing.expectEqual(@as(?Note, null), try response.next(Note));
    try testing.expect(response.done);
    try testing.expectEqual(@as(?connect.RpcError, null), response.failure);
    // `on_response` ran at the head alone.
    try testing.expectEqual(responses + 1, Seen.responses);
}

test "a streamed gRPC response reads its status from the trailers once it finished" {
    var fixture: Fixture = .{};
    try fixture.start(&.{ .protocol = .grpc });
    // PROTOCOL-HTTP2.md, "Requests": the client sends "te: trailers" once. colibri adds none of
    // its own when the request names TE (colibri decision 152).
    var te_count: usize = 0;
    for (fixture.call.request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "te")) te_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), te_count);
    fixture.call.response.status = .ok;
    write_lines(&fixture.call.response.headers, &.{.{ .name = "content-type", .value = "application/grpc+proto" }});
    fixture.call.on_headers(fixture.storage());
    var texts: [8]u8 = undefined;
    try testing.expectEqualStrings("hi", try fixture.arrive(&.{ 0, 0, 0, 0, 4, 0x0a, 2, 'h', 'i' }, &texts));
    try testing.expect(!fixture.call.reader.done);
    write_lines(&fixture.call.response.trailers, &.{.{ .name = "grpc-status", .value = "5" }});
    fixture.call.response.result = .response;
    var response = fixture.call.read(fixture.storage());
    try testing.expectEqual(@as(?Note, null), try response.next(Note));
    try testing.expectEqual(connect.Code.not_found, response.failure.?.code);
}

test "a streamed response cut inside an envelope, or reset, fails" {
    var fixture: Fixture = .{};
    try fixture.start(&.{ .protocol = .grpc });
    fixture.call.response.status = .ok;
    write_lines(&fixture.call.response.headers, &.{.{ .name = "content-type", .value = "application/grpc+proto" }});
    fixture.call.on_headers(fixture.storage());
    var texts: [8]u8 = undefined;
    _ = try fixture.arrive(&.{ 0, 0, 0, 0, 4, 0x0a }, &texts);
    write_lines(&fixture.call.response.trailers, &.{.{ .name = "grpc-status", .value = "0" }});
    fixture.call.response.result = .response;
    var cut = fixture.call.read(fixture.storage());
    try testing.expectEqual(@as(?Note, null), try cut.next(Note));
    try testing.expectEqualStrings("truncated message", cut.failure.?.message);
    fixture.call.response.result = .reset;
    fixture.call.incoming.len = fixture.call.incoming.fed_len;
    try testing.expectEqual(connect.Code.unavailable, fixture.call.read(fixture.storage()).failure.?.code);
}

test "a response envelope longer than the call gathers fails the call resource_exhausted" {
    var fixture: Fixture = .{};
    try fixture.start(&.{});
    fixture.call.response.status = .ok;
    write_lines(&fixture.call.response.headers, &.{.{ .name = "content-type", .value = "application/connect+proto" }});
    fixture.call.on_headers(fixture.storage());
    const long = [_]u8{ 0, 0, 0, 0, gathered_len } ++ [_]u8{0} ** gathered_len;
    var texts: [8]u8 = undefined;
    _ = try fixture.arrive(&long, &texts);
    try testing.expectEqual(connect.Code.resource_exhausted, fixture.call.reader.failure.?.code);
    // Every piece still went back to the pool.
    try testing.expectEqual(@as(u32, (long.len + piece_len - 1) / piece_len), fixture.pool.released);
}
