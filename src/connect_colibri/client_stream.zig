//! The two bodies of a streamed client call over colibri's pool (colibri decision 153 ruling 7).
//! The request's messages go out as pieces while the response's pieces arrive. The pool holds one
//! request piece at a time, until its `body_taken` event, so the messages written meanwhile wait
//! after it and go as the next piece. Each response piece is copied after the octets not read
//! yet, so an envelope that two pieces split is read whole (decision 18 as amended).
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const client = @import("client");
const client_call = @import("client_call.zig");

/// Whether a stream over `protocol` is full-duplex: the client reads answers while it still
/// sends. Connect protocol, "Streaming-RPC": a bidirectional stream is full-duplex over HTTP/2
/// alone, and over HTTP/1.1 the whole request goes before the response is read. gRPC runs over
/// HTTP/2 alone (PROTOCOL-HTTP2.md, "Overview"). An h3 request stream carries both directions at
/// once, as an h2 stream does (RFC 9114 §4.1).
pub fn full_duplex(protocol: client.Protocol) bool {
    return switch (protocol) {
        .h2, .h3 => true,
        .h11 => false,
    };
}

/// Writes `message` as the next of `call`'s request stream, and hands it to the pool when the
/// pool holds no piece of the call.
pub fn send(comptime T: type, call: anytype, message: *const T) client_call.SendError!void {
    assert(call.streamed);
    // RFC 9110 §8.6 and RFC 9113 §8.1: nothing follows the end of the content.
    if (call.outgoing.closed) return error.BodyEnded;
    const room = call.outgoing.space();
    const len = connect.client.write_message(T, &call.call, &call.options, message, room, call.work) catch |failure| switch (failure) {
        // The message fits once the pool gives the held piece back.
        error.NoSpaceLeft => return if (call.outgoing.holding) error.PieceHeld else error.NoSpaceLeft,
        else => |other| return other,
    };
    call.outgoing.queue(len);
    try hand(call);
}

/// Ends `call`'s request stream.
pub fn close_send(call: anytype) client_call.SendError!void {
    assert(call.streamed);
    if (call.outgoing.closed) return error.BodyEnded;
    call.outgoing.closed = true;
    try hand(call);
}

/// The pool read `call`'s held piece no more: the next piece goes.
pub fn on_body_taken(call: anytype) client_call.SendError!void {
    assert(call.streamed);
    call.outgoing.taken();
    try hand(call);
}

/// Hands the pool the piece `call` owes it, if any.
fn hand(call: anytype) client_call.SendError!void {
    const piece = call.outgoing.owed() orelse return;
    try call.pool.write_body(call.id, piece.octets, piece.end);
    call.outgoing.handed(piece);
}

/// Copies a piece of `len` octets of `call`'s response after what its reader has not read, and
/// gives the piece back to the pool.
pub fn on_body(call: anytype, len: usize) void {
    assert(call.streamed and call.incoming.headers_seen);
    // The call copied the piece, so the pool reads on at once.
    defer call.pool.release_body(call.id);
    if (call.reader.done) return;
    const unread = call.incoming.gather(call.reader.reader.position, call.response.body[0..len]) orelse {
        call.reader.done = true;
        call.reader.failure = too_large;
        return;
    };
    const whole_len = call.reader.feed(unread) catch |failure| {
        call.reader.done = true;
        call.reader.failure = connect.client.failure_of(failure);
        return;
    };
    call.incoming.fed(whole_len);
}

/// The reader of `call`'s streamed response once the call finished: the messages left, then
/// the outcome.
pub fn read(call: anytype) connect.client.Response {
    assert(call.streamed and call.incoming.headers_seen);
    var response = call.reader;
    response.end_body(call.incoming.rest());
    if (call.response.result != .response and !response.done) {
        response.done = true;
        response.failure = client_call.failure_of(call.response.result);
    }
    return response;
}

/// statuscodes.md, RESOURCE_EXHAUSTED: a response message longer than the client reads.
const too_large: connect.RpcError = .{ .code = .resource_exhausted, .message = "message larger than the client reads" };

/// The next piece the pool takes, and whether it ends the request body.
pub const Piece = struct {
    octets: []const u8,
    end: client.PieceEnd,
};

/// A streamed request's messages, in the call's request buffer: the piece the pool holds, and
/// after it the messages that go as the next piece.
pub const Outgoing = struct {
    room: []u8 = &.{},
    /// The piece the pool holds, `room[held_start..held_end]`, while `holding`.
    held_start: usize = 0,
    held_end: usize = 0,
    holding: bool = false,
    /// The messages written after the held piece: `room[held_end..queued_end]`.
    queued_end: usize = 0,
    /// `close_send` ran, and the piece that ends the body went to the pool.
    closed: bool = false,
    ended: bool = false,

    /// Where the next message goes. With no piece held and none queued, the room starts over.
    pub fn space(outgoing: *Outgoing) []u8 {
        assert(outgoing.held_end <= outgoing.queued_end and outgoing.queued_end <= outgoing.room.len);
        if (!outgoing.holding) {
            // A queued message goes to the pool at once when it holds none.
            assert(outgoing.queued_end == outgoing.held_end);
            outgoing.held_start = 0;
            outgoing.held_end = 0;
            outgoing.queued_end = 0;
        }
        return outgoing.room[outgoing.queued_end..];
    }

    /// The next `len` octets of `space` hold a message.
    pub fn queue(outgoing: *Outgoing, len: usize) void {
        assert(!outgoing.closed);
        assert(len <= outgoing.room.len - outgoing.queued_end);
        outgoing.queued_end += len;
    }

    /// The piece the pool takes now, or null: none while it holds one, and none once the body
    /// ended. A closed body with nothing queued ends with an empty piece.
    pub fn owed(outgoing: *const Outgoing) ?Piece {
        if (outgoing.holding or outgoing.ended) return null;
        const queued = outgoing.room[outgoing.held_end..outgoing.queued_end];
        if (queued.len == 0 and !outgoing.closed) return null;
        return .{ .octets = queued, .end = if (outgoing.closed) .last else .more };
    }

    /// The pool took `piece`, which `owed` gave.
    pub fn handed(outgoing: *Outgoing, piece: Piece) void {
        assert(!outgoing.holding and !outgoing.ended);
        assert(piece.octets.len == outgoing.queued_end - outgoing.held_end);
        outgoing.held_start = outgoing.held_end;
        outgoing.held_end = outgoing.queued_end;
        outgoing.holding = true;
        outgoing.ended = piece.end == .last;
    }

    /// The pool reads the held piece no more: its `body_taken` event.
    pub fn taken(outgoing: *Outgoing) void {
        assert(outgoing.holding);
        outgoing.holding = false;
        outgoing.held_start = outgoing.held_end;
    }
};

/// A streamed response's octets not read yet, in the call's response buffer: the whole envelopes
/// `connect.client.Response.feed` took, then the start of one a later piece ends.
pub const Incoming = struct {
    body: []u8 = &.{},
    len: usize = 0,
    /// The octets of whole envelopes the reader took at the last feed.
    fed_len: usize = 0,
    headers_seen: bool = false,

    /// Moves the octets from `read_position` on to the start, copies `piece` after them, and
    /// returns what the reader reads next. Null when they do not fit: an envelope longer than
    /// the buffer holds.
    pub fn gather(incoming: *Incoming, read_position: usize, piece: []const u8) ?[]const u8 {
        assert(read_position <= incoming.fed_len and incoming.fed_len <= incoming.len);
        const kept = incoming.body[read_position..incoming.len];
        std.mem.copyForwards(u8, incoming.body[0..kept.len], kept);
        incoming.len = kept.len;
        incoming.fed_len = 0;
        if (piece.len > incoming.body.len - incoming.len) return null;
        @memcpy(incoming.body[incoming.len..][0..piece.len], piece);
        incoming.len += piece.len;
        return incoming.body[0..incoming.len];
    }

    /// The reader took `whole_len` octets of what `gather` returned.
    pub fn fed(incoming: *Incoming, whole_len: usize) void {
        assert(whole_len <= incoming.len);
        incoming.fed_len = whole_len;
    }

    /// What the reader left: the start of an envelope, or nothing.
    pub fn rest(incoming: *const Incoming) []const u8 {
        return incoming.body[incoming.fed_len..incoming.len];
    }
};

const testing = std.testing;

test "a stream is full-duplex over h2 and h3, and half-duplex over h11 (Connect, Streaming-RPC)" {
    try testing.expect(full_duplex(.h2));
    try testing.expect(full_duplex(.h3));
    try testing.expect(!full_duplex(.h11));
}

test "messages written while the pool holds a piece go as the next piece, and close ends it" {
    var room: [16]u8 = undefined;
    var outgoing: Outgoing = .{ .room = &room };
    try testing.expectEqual(@as(?Piece, null), outgoing.owed());
    @memcpy(outgoing.space()[0..2], "ab");
    outgoing.queue(2);
    const first = outgoing.owed().?;
    try testing.expectEqualStrings("ab", first.octets);
    try testing.expectEqual(client.PieceEnd.more, first.end);
    outgoing.handed(first);
    // The pool holds "ab": what comes next waits after it.
    @memcpy(outgoing.space()[0..1], "c");
    outgoing.queue(1);
    @memcpy(outgoing.space()[0..1], "d");
    outgoing.queue(1);
    try testing.expectEqual(@as(?Piece, null), outgoing.owed());
    outgoing.closed = true;
    outgoing.taken();
    const last = outgoing.owed().?;
    try testing.expectEqualStrings("cd", last.octets);
    try testing.expectEqual(client.PieceEnd.last, last.end);
    outgoing.handed(last);
    outgoing.taken();
    try testing.expectEqual(@as(?Piece, null), outgoing.owed());
}

test "a body closed with nothing queued ends with an empty piece, and the room starts over" {
    var room: [8]u8 = undefined;
    var outgoing: Outgoing = .{ .room = &room };
    outgoing.queue(3);
    outgoing.handed(outgoing.owed().?);
    outgoing.taken();
    // Nothing held and nothing queued: the next message goes at the start.
    try testing.expectEqual(room.len, outgoing.space().len);
    outgoing.closed = true;
    const last = outgoing.owed().?;
    try testing.expectEqual(@as(usize, 0), last.octets.len);
    try testing.expectEqual(client.PieceEnd.last, last.end);
}

test "a response piece goes after the octets not read, and one that does not fit is refused" {
    var body: [8]u8 = undefined;
    var incoming: Incoming = .{ .body = &body };
    try testing.expectEqualStrings("abcde", incoming.gather(0, "abcde").?);
    incoming.fed(3);
    try testing.expectEqualStrings("de", incoming.rest());
    // The reader read "ab": "c" and "de" stay, and the piece goes after them.
    try testing.expectEqualStrings("cdefg", incoming.gather(2, "fg").?);
    try testing.expectEqual(@as(?[]const u8, null), incoming.gather(0, "hijk"));
}
