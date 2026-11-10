//! What the tests of `pull_test.zig` share: a route table with a server stream and a
//! bidirectional stream whose handlers declare `next`, an engine that takes as many octets as a
//! test lets it, and a reader of the notes the engine took. Test-only.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const connect = @import("connect");
const proto = @import("protobuf");
const server = @import("server");
const http = @import("http");
const rpc = @import("connect_colibri.zig");

pub const Note = struct {
    text: []const u8 = "",
    pub const FieldNumber = enum(u29) { text = 1 };
    pub const protobuf: proto.Descriptor = .{ .full_name = "test.Note", .fields = &.{
        proto.field_of(FieldNumber.text, .string, .{}),
    } };
};

pub const count: connect.Method = .{ .service = "test.Svc", .name = "Count", .Request = Note, .Response = Note, .stream_type = .server_stream, .idempotency = .unknown };
pub const chat: connect.Method = .{ .service = "test.Svc", .name = "Chat", .Request = Note, .Response = Note, .stream_type = .bidi_stream, .idempotency = .unknown };

/// Octets of the router's response memory, and of the longest message a route encodes.
pub const response_bytes = 256;
const message_bytes = 64;
const token_bytes = 64;
/// Octets of a note's text, and of the text of a note that fits neither the response memory nor
/// `message_bytes`.
pub const note_len = 40;
const note_len_long = response_bytes + note_len;
/// Octets of the text of a note that takes `message_bytes` once encoded: a tag and a length
/// come before the text (the protobuf encoding guide, "Length-Delimited Records").
pub const note_len_exact = message_bytes - note_prefix_len;
const note_prefix_len = 2;
/// Octets of every response a test reads back, at most.
const stream_len_max = 16384;
/// The runs an engine that holds them keeps at most, as an h3 response does.
const runs_max = 16;
/// The `writable` events a test reports at most: two for each octet of the longest response.
const rounds_max = rounds_per_octet * stream_len_max;
const rounds_per_octet = 2;
/// The base of the count a request's note names.
const decimal = 10;
/// Octets of a status or a message an engine reads from the trailers.
const field_len_max = 64;
/// An error message as long as a trailer value the engine reads: with its name and the status,
/// it is longer than the octets four notes leave free in the response memory.
pub const message_long = "the stream gave up: " ++ "no more notes follow this one, and none came";

/// What a test asks of the handlers, and what they did.
pub const App = struct {
    next_calls: usize = 0,
    /// `on_request` refuses the call.
    refuse_request: bool = false,
    /// After this many notes, `next` fails, waits, or gives a note too long to encode.
    fail_after: ?u32 = null,
    /// The message of the error `next` fails with.
    fail_message: []const u8 = "gave up",
    wait_after: ?u32 = null,
    long_after: ?u32 = null,
    /// Octets of each note's text.
    note_len: usize = note_len,
    /// The bidirectional stream gives its notes while its client still sends.
    early: bool = false,
    /// What the interceptor saw: the calls it let in, and each call's outcome.
    calls: usize = 0,
    finishes: usize = 0,
    outcome: ?connect.Code = null,
};

/// An interceptor that counts the calls and records how each ended.
pub const Watch = struct {
    pub fn on_call(app: *App, _: *rpc.Call) ?connect.RpcError {
        app.calls += 1;
        return null;
    }

    pub fn on_finish(app: *App, _: *rpc.Call, failure: ?connect.RpcError) ?connect.RpcError {
        app.finishes += 1;
        app.outcome = if (failure) |rpc_failure| rpc_failure.code else null;
        return failure;
    }
};

/// The text of the note at `index`: its number, then a letter that differs from its neighbours'.
pub fn note_text(index: u32, buffer: []u8) []const u8 {
    const letters = 'z' - 'a' + 1;
    @memset(buffer, 'a' + @as(u8, @intCast(index % letters)));
    _ = std.fmt.bufPrint(buffer, "{d}:", .{index}) catch unreachable;
    return buffer;
}

/// A server stream that sends as many notes as its request names.
pub const Counter = struct {
    pub const State = struct {
        total: u32 = 0,
        given: u32 = 0,
        text: [note_len_long]u8 = undefined,
    };

    pub fn on_request(app: *App, _: *rpc.Call, state: *State, request: *const Note) ?connect.RpcError {
        if (app.refuse_request) return .{ .code = .permission_denied };
        state.total = std.fmt.parseInt(u32, request.text, decimal) catch return .{ .code = .invalid_argument };
        return null;
    }

    pub fn next(app: *App, _: *rpc.Call, state: *State, response: *Note) rpc.Next {
        app.next_calls += 1;
        if (app.fail_after == state.given) return .{ .failure = .{ .code = .aborted, .message = app.fail_message } };
        if (app.wait_after == state.given) return .wait;
        if (state.given == state.total) return .end;
        const len: usize = if (app.long_after == state.given) note_len_long else app.note_len;
        response.text = note_text(state.given, state.text[0..len]);
        state.given += 1;
        return .message;
    }
};

/// The same stream as a function, which writes through a `Sender` in one call.
pub fn on_count(_: *App, _: *rpc.Call, request: *const Note, sender: *rpc.Sender(Note)) ?connect.RpcError {
    sender.send(request) catch return .{ .code = .resource_exhausted };
    return null;
}

/// A bidirectional stream that echoes each note at once, and sends as many notes as the last
/// one names once its client ended the request, or at once when `App.early` is set.
pub const Chatter = struct {
    pub const State = struct {
        total: u32 = 0,
        given: u32 = 0,
        ended: bool = false,
        text: [note_len]u8 = undefined,
    };

    pub fn on_message(_: *App, _: *rpc.Call, state: *State, request: *const Note, sender: *rpc.Sender(Note)) ?connect.RpcError {
        state.total = std.fmt.parseInt(u32, request.text, decimal) catch return .{ .code = .invalid_argument };
        sender.send(request) catch return .{ .code = .resource_exhausted };
        return null;
    }

    pub fn on_end(_: *App, _: *rpc.Call, state: *State, _: *rpc.Sender(Note)) ?connect.RpcError {
        state.ended = true;
        return null;
    }

    pub fn next(app: *App, _: *rpc.Call, state: *State, response: *Note) rpc.Next {
        app.next_calls += 1;
        if (!state.ended and !app.early) return .wait;
        if (state.given == state.total) return if (state.ended) .end else .wait;
        response.text = note_text(state.given, &state.text);
        state.given += 1;
        return .message;
    }
};

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

pub const options: rpc.RouteOptions = .{ .message_bytes = message_bytes, .token_bytes = token_bytes, .interceptors = &.{Watch} };

pub const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = .{
        rpc.post(App, count, Counter, options),
        rpc.post(App, chat, Chatter, options),
    },
}, .{ .requests = 1, .response_bytes = response_bytes, .body_bytes = response_bytes });

/// An engine that records each octet it takes. It copies each run, as h11 and h2 do, and takes
/// `window` octets before it blocks; or, with `holds`, it keeps each run until a test
/// acknowledges it, as an uncoded h3 response does (RFC 9000 §3.1).
pub const Engine = struct {
    window: usize = 0,
    holds: bool = false,
    stream: [stream_len_max]u8 = undefined,
    taken: usize = 0,
    acknowledged: usize = 0,
    /// Where each run the engine holds ends in `stream`.
    run_ends: [runs_max]usize = undefined,
    runs_len: usize = 0,
    heads: usize = 0,
    ended: bool = false,
    cancelled: usize = 0,
    /// Whether the engine owes the program a `writable`.
    owed: bool = false,
    user_data: usize = 0,
    status_octets: [field_len_max]u8 = undefined,
    status_len: usize = 0,
    message_octets: [field_len_max]u8 = undefined,
    message_len: usize = 0,

    pub fn respond(engine: *Engine, _: server.RequestId, response: server.Response) server.SendError!void {
        engine.heads += 1;
        engine.ended = response.end;
        for (response.headers) |header| engine.read_field(header.name, header.value);
    }

    pub fn write_body(engine: *Engine, _: server.RequestId, body: server.ResponseBody) server.SendError!usize {
        if (body.bytes.len == 0) {
            engine.ended = engine.ended or body.end;
            return 0;
        }
        const len = if (engine.holds) try engine.room_held(body.bytes.len) else try engine.room_copied(body.bytes.len);
        @memcpy(engine.stream[engine.taken..][0..len], body.bytes[0..len]);
        engine.taken += len;
        engine.ended = body.end and len == body.bytes.len;
        return len;
    }

    /// RFC 9113 §6.9: a closed flow-control window takes no content.
    fn room_copied(engine: *Engine, len: usize) server.SendError!usize {
        const room = @min(engine.window, len);
        engine.owed = room < len;
        if (room == 0) return error.Blocked;
        engine.window -= room;
        return room;
    }

    /// RFC 9000 §3.1: a run leaves only once the peer acknowledged it.
    fn room_held(engine: *Engine, len: usize) server.SendError!usize {
        if (engine.runs_len == runs_max) {
            engine.owed = true;
            return error.Blocked;
        }
        engine.run_ends[engine.runs_len] = engine.taken + len;
        engine.runs_len += 1;
        return len;
    }

    pub fn write_trailers(engine: *Engine, _: server.RequestId, headers: []const http.Field) server.SendError!void {
        for (headers) |header| engine.read_field(header.name, header.value);
        engine.ended = true;
    }

    pub fn set_user_data(engine: *Engine, _: server.RequestId, user_data: usize) error{RequestUnknown}!void {
        engine.user_data = user_data;
    }

    pub fn cancel(engine: *Engine, _: server.RequestId) void {
        engine.cancelled += 1;
    }

    pub fn held_len(engine: *Engine, _: server.RequestId) usize {
        if (!engine.holds) return 0;
        return engine.taken - engine.acknowledged;
    }

    pub fn wait_release(engine: *Engine, _: server.RequestId) void {
        engine.owed = true;
    }

    /// Acknowledges `len` more octets, and drops each run they cover whole.
    pub fn acknowledge(engine: *Engine, len: usize) void {
        assert(engine.acknowledged + len <= engine.taken);
        engine.acknowledged += len;
        var dropped: usize = 0;
        for (engine.run_ends[0..engine.runs_len]) |run_end| {
            if (run_end > engine.acknowledged) break;
            dropped += 1;
        }
        const rest = engine.runs_len - dropped;
        std.mem.copyForwards(usize, engine.run_ends[0..rest], engine.run_ends[dropped..engine.runs_len]);
        engine.runs_len = rest;
    }

    /// The octets of the oldest run the engine holds that no acknowledgment covers yet, or 0.
    pub fn oldest_len(engine: *const Engine) usize {
        if (engine.runs_len == 0) return 0;
        return engine.run_ends[0] - engine.acknowledged;
    }

    /// The value of grpc-status the engine read, in a head or in the trailers.
    pub fn status(engine: *const Engine) []const u8 {
        return engine.status_octets[0..engine.status_len];
    }

    pub fn message(engine: *const Engine) []const u8 {
        return engine.message_octets[0..engine.message_len];
    }

    fn read_field(engine: *Engine, name: []const u8, value: []const u8) void {
        if (std.mem.eql(u8, name, "grpc-status")) {
            @memcpy(engine.status_octets[0..value.len], value);
            engine.status_len = value.len;
        }
        if (std.mem.eql(u8, name, "grpc-message")) {
            @memcpy(engine.message_octets[0..value.len], value);
            engine.message_len = value.len;
        }
    }
};

/// Reads the notes of a response's body, one envelope a call.
pub const Notes = struct {
    reader: connect.EnvelopeReader,
    /// Octets of each note's text.
    note_len: usize = note_len,

    pub fn next(notes: *Notes) !?Note {
        const envelope = (try notes.reader.next()) orelse return null;
        return try proto.decode(Note, envelope.payload);
    }

    /// Requires the next `total` notes to be those `note_text` names, from 0 on.
    pub fn expect_count(notes: *Notes, total: u32) !void {
        return notes.expect_range(0, total);
    }

    /// Requires the next notes to be those `note_text` names from `first` up to `end`.
    pub fn expect_range(notes: *Notes, first: u32, end: u32) !void {
        for (first..end) |index| {
            var text: [note_len_exact]u8 = undefined;
            const note = (try notes.next()) orelse return error.TestExpectedNote;
            try testing.expectEqualStrings(note_text(@intCast(index), text[0..notes.note_len]), note.text);
        }
    }

    pub fn at_end(notes: *const Notes) bool {
        return notes.reader.at_end();
    }
};

/// A request's header section; it is too large for a test's stack.
threadlocal var test_section: http.FieldSection align(@alignOf(http.FieldSection)) = undefined;

const request_id: server.RequestId = @bitCast(@as(u128, 1));
const h2_major = 2;
const h2_version: server.Version = .{ .major = h2_major, .minor = 0 };
/// Octets of a request's note, which names a count, and of its envelope.
const request_note_len = 16;
const request_envelope_len = request_note_len + connect.constants.protocol.envelope_prefix_len;

pub const Fixture = struct {
    app: App = .{},
    engine: Engine,
    pool: Router = .{},

    /// Sends a request to `path` whose first note names `total`, and ends the request when `end`.
    pub fn call(fixture: *Fixture, path: []const u8, content_type: []const u8, total: u32, end: bool) void {
        test_section.init();
        test_section.append("content-type", content_type) catch unreachable;
        fixture.handle(.{ .request = .{
            .id = request_id,
            .method = "POST",
            .version = h2_version,
            .target = path,
            .scheme = "https",
            .authority = "example.com",
            .path = path,
            .query = null,
            .headers = .of(&test_section),
            .end = false,
        } });
        var digits: [request_note_len]u8 = undefined;
        fixture.send(std.fmt.bufPrint(&digits, "{d}", .{total}) catch unreachable, end);
    }

    /// Sends one more note of a request that `call` left open, and ends the request when `end`.
    pub fn send(fixture: *Fixture, text: []const u8, end: bool) void {
        var payload: [request_note_len]u8 = undefined;
        const encoded = proto.encode(Note, &.{ .text = text }, &payload) catch unreachable;
        var envelope: [request_envelope_len]u8 = undefined;
        const bytes = connect.envelope.write(.{}, encoded, &envelope) catch unreachable;
        fixture.handle(.{ .body = .{ .id = request_id, .user_data = fixture.engine.user_data, .bytes = bytes, .end = end } });
    }

    /// Ends a request that `call` left open.
    pub fn end_request(fixture: *Fixture) void {
        fixture.handle(.{ .body = .{ .id = request_id, .user_data = fixture.engine.user_data, .bytes = "", .end = true } });
    }

    /// Reports the `writable` the engine owes, as a program passes it to the router.
    pub fn writable(fixture: *Fixture) void {
        fixture.engine.owed = false;
        fixture.handle(.{ .writable = .{ .id = request_id, .user_data = fixture.engine.user_data } });
    }

    fn handle(fixture: *Fixture, received: server.Event) void {
        const handled = fixture.pool.handle(&fixture.app, &fixture.engine, received);
        assert(handled == .taken);
    }

    /// Opens the engine's window by `window` octets and reports a `writable`, until the response
    /// ends.
    pub fn drain(fixture: *Fixture, window: usize) !void {
        // Bounded: each round takes one octet at least, or the response ended.
        for (0..rounds_max) |_| {
            if (fixture.engine.ended) return;
            if (!fixture.engine.owed) return error.TestExpectedWritable;
            fixture.engine.window = window;
            fixture.writable();
        }
        return error.TestExpectedEnd;
    }

    /// Acknowledges all of the oldest run but its last octet, then that octet, with a `writable`
    /// after each, as an h3 peer's late acknowledgments free runs, until the response ends.
    pub fn acknowledge_late(fixture: *Fixture) !void {
        // Bounded: each round acknowledges one octet at least, or the response ended.
        for (0..rounds_max) |_| {
            if (fixture.engine.ended) return;
            const oldest = fixture.engine.oldest_len();
            if (oldest == 0) return error.TestExpectedHeldRun;
            fixture.engine.acknowledge(oldest - 1);
            if (fixture.engine.owed) fixture.writable();
            fixture.engine.acknowledge(1);
            if (fixture.engine.owed) fixture.writable();
        }
        return error.TestExpectedEnd;
    }

    /// The notes of the body the engine took so far.
    pub fn notes(fixture: *const Fixture) Notes {
        return .{ .reader = .{ .body = fixture.engine.stream[0..fixture.engine.taken], .payload_len_max = stream_len_max } };
    }
};
