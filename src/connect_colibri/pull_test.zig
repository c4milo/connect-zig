//! The tests of a stream that its route asks for one message at a time (decision 33): a server
//! stream and a bidirectional stream whose handlers declare `next`, through colibri's router and
//! an engine each test controls (`pull_test_support.zig`). The engine takes as many octets as a
//! test lets it, so the response memory fills, and each test reads back every octet it took.
const std = @import("std");
const testing = std.testing;
const connect = @import("connect");
const server = @import("server");
const rpc = @import("connect_colibri.zig");
const support = @import("pull_test_support.zig");

const App = support.App;
const Note = support.Note;
const Fixture = support.Fixture;

/// The notes of a long stream: with their envelopes, about 37 times the response memory.
const notes_long = 200;
/// Octets the engine takes for each `writable` a test reports: less than the response memory.
const window = 100;
/// Octets that take a chat's first echo and little more, so the notes after it fill the memory.
const window_echo = 16;
/// The notes a chat echoes one by one: more than the runs an h3 response holds.
const echoes = 20;
/// The longest stream of the sweep: its notes fill the response memory several times, so the
/// end of some stream finds the memory full, whatever octets the head took.
const sweep_max = 40;

test "decision 33: a gRPC server stream many times response_bytes goes out whole and in order" {
    var fixture: Fixture = .{ .engine = .{} };
    fixture.call("/test.Svc/Count", "application/grpc+proto", notes_long, true);
    // The engine took nothing yet, so the memory is full and the route waits.
    try testing.expectEqual(@as(usize, 0), fixture.engine.taken);
    try testing.expect(fixture.app.next_calls < notes_long);
    try fixture.drain(window);
    try testing.expect(fixture.engine.taken > support.response_bytes * 30);
    var notes = fixture.notes();
    try notes.expect_count(notes_long);
    try testing.expect(notes.at_end());
    // gRPC PROTOCOL-HTTP2.md, "Responses": the status goes in the trailers.
    try testing.expectEqualStrings("0", fixture.engine.status());
    // The handler gave each note once, and then the end: the route held what did not fit.
    try testing.expectEqual(@as(usize, notes_long + 1), fixture.app.next_calls);
    try testing.expectEqual(@as(usize, 1), fixture.engine.heads);
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
}

test "decision 33: a Connect stream ends with its end-stream envelope after the last note" {
    var fixture: Fixture = .{ .engine = .{} };
    fixture.call("/test.Svc/Count", "application/connect+proto", notes_long, true);
    try fixture.drain(window);
    var notes = fixture.notes();
    try notes.expect_count(notes_long);
    // Connect protocol, "Streaming-Response": the last envelope has the end-stream flag.
    const end = (try notes.reader.next()).?;
    try testing.expect(end.flags.end_stream);
    try testing.expectEqualStrings("{}", end.payload);
    try testing.expect(notes.at_end());
    try testing.expectEqual(@as(usize, notes_long + 1), fixture.app.next_calls);
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
}

test "decision 33: a gRPC-Web stream ends with its trailers frame, written when it has room" {
    var fixture: Fixture = .{ .engine = .{} };
    fixture.call("/test.Svc/Count", "application/grpc-web+proto", notes_long, true);
    // One octet for each `writable`: every write but the first finds the memory full.
    try fixture.drain(1);
    var notes = fixture.notes();
    try notes.expect_count(notes_long);
    // PROTOCOL-WEB.md, "Message framing": the trailers are the body's last frame.
    const end = (try notes.reader.next()).?;
    try testing.expect(end.flags.trailers);
    try testing.expectEqualStrings("grpc-status: 0\r\n", end.payload);
    try testing.expect(notes.at_end());
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
}

test "decision 33: over an engine that holds each run, the stream waits for acknowledgments" {
    // An uncoded h3 response keeps each run in place until the peer acknowledged it (RFC 9000
    // §3.1), so the memory frees only then.
    var fixture: Fixture = .{ .engine = .{ .holds = true } };
    fixture.call("/test.Svc/Count", "application/grpc+proto", notes_long, true);
    try testing.expect(fixture.engine.taken <= support.response_bytes);
    try fixture.acknowledge_late();
    var notes = fixture.notes();
    try notes.expect_count(notes_long);
    try testing.expect(notes.at_end());
    try testing.expectEqualStrings("0", fixture.engine.status());
    try testing.expectEqual(@as(usize, notes_long + 1), fixture.app.next_calls);
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
}

test "decision 33: an error from next ends the stream after the notes before it" {
    var fixture: Fixture = .{ .engine = .{}, .app = .{ .fail_after = 50 } };
    fixture.call("/test.Svc/Count", "application/grpc+proto", notes_long, true);
    try fixture.drain(window);
    var notes = fixture.notes();
    try notes.expect_count(50);
    try testing.expect(notes.at_end());
    // statuscodes.md: ABORTED is 10.
    try testing.expectEqualStrings("10", fixture.engine.status());
    try testing.expectEqualStrings("gave up", fixture.engine.message());
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
}

test "decision 33: an error from on_request is the whole response, and next never runs" {
    var fixture: Fixture = .{ .engine = .{ .window = support.response_bytes }, .app = .{ .refuse_request = true } };
    fixture.call("/test.Svc/Count", "application/grpc+proto", notes_long, true);
    try testing.expect(fixture.engine.ended);
    // gRPC PROTOCOL-HTTP2.md, "Responses": Trailers-Only is one header section.
    try testing.expectEqual(@as(usize, 1), fixture.engine.heads);
    try testing.expectEqual(@as(usize, 0), fixture.engine.taken);
    // statuscodes.md: PERMISSION_DENIED is 7.
    try testing.expectEqualStrings("7", fixture.engine.status());
    try testing.expectEqual(@as(usize, 0), fixture.app.next_calls);
}

test "decision 33: a stream with no note ends at once, with success" {
    var fixture: Fixture = .{ .engine = .{ .window = support.response_bytes } };
    fixture.call("/test.Svc/Count", "application/grpc+proto", 0, true);
    try testing.expect(fixture.engine.ended);
    try testing.expectEqualStrings("0", fixture.engine.status());
    try testing.expectEqual(@as(usize, 1), fixture.app.next_calls);
}

test "decision 33: a note longer than message_bytes ends the stream with resource_exhausted" {
    var fixture: Fixture = .{ .engine = .{}, .app = .{ .long_after = 3 } };
    fixture.call("/test.Svc/Count", "application/grpc+proto", notes_long, true);
    try fixture.drain(window);
    var notes = fixture.notes();
    try notes.expect_count(3);
    try testing.expect(notes.at_end());
    // statuscodes.md: RESOURCE_EXHAUSTED is 8.
    try testing.expectEqualStrings("8", fixture.engine.status());
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
}

/// Runs a stream of `total` notes over an engine that holds each run, and requires every note
/// and no cancel. With `fails` the stream ends with an error whose message is long, so its
/// trailers take more octets than some streams leave free.
fn sweep_one(fixture: *Fixture, content_type: []const u8, total: u32, fails: bool) !support.Notes {
    fixture.* = .{ .engine = .{ .holds = true }, .app = .{ .fail_after = if (fails) total else null, .fail_message = support.message_long } };
    fixture.call("/test.Svc/Count", content_type, total, true);
    try fixture.acknowledge_late();
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
    var notes = fixture.notes();
    try notes.expect_count(total);
    return notes;
}

test "decision 33: gRPC's trailers wait for room, whatever the notes before them left" {
    var fixture: Fixture = undefined;
    for (1..sweep_max + 1) |total| {
        var plain = try sweep_one(&fixture, "application/grpc+proto", @intCast(total), false);
        try testing.expect(plain.at_end());
        try testing.expectEqualStrings("0", fixture.engine.status());
        var failed = try sweep_one(&fixture, "application/grpc+proto", @intCast(total), true);
        try testing.expect(failed.at_end());
        // statuscodes.md: ABORTED is 10.
        try testing.expectEqualStrings("10", fixture.engine.status());
        try testing.expectEqualStrings(support.message_long, fixture.engine.message());
    }
}

test "decision 33: the end of a body waits for room, whatever the notes before it left" {
    var fixture: Fixture = undefined;
    for (1..sweep_max + 1) |total| {
        var web = try sweep_one(&fixture, "application/grpc-web+proto", @intCast(total), true);
        // PROTOCOL-WEB.md, "Message framing": the trailers are the body's last frame.
        const frame = (try web.reader.next()) orelse return error.TestExpectedTrailersFrame;
        try testing.expect(frame.flags.trailers);
        try testing.expectEqualStrings("grpc-status: 10\r\ngrpc-message: " ++ support.message_long ++ "\r\n", frame.payload);
        try testing.expect(web.at_end());
    }
}

test "decision 33: a held note of message_bytes octets keeps room for its envelope's prefix" {
    var fixture: Fixture = .{ .engine = .{}, .app = .{ .note_len = support.note_len_exact } };
    fixture.call("/test.Svc/Count", "application/grpc+proto", notes_long, true);
    try fixture.drain(window);
    var notes = fixture.notes();
    notes.note_len = support.note_len_exact;
    try notes.expect_count(notes_long);
    try testing.expect(notes.at_end());
    try testing.expectEqualStrings("0", fixture.engine.status());
}

test "decision 33: a server stream that waits ends with internal, since colibri cannot wake it" {
    var fixture: Fixture = .{ .engine = .{}, .app = .{ .wait_after = 2 } };
    fixture.call("/test.Svc/Count", "application/grpc+proto", notes_long, true);
    try fixture.drain(window);
    var notes = fixture.notes();
    try notes.expect_count(2);
    // statuscodes.md: INTERNAL is 13.
    try testing.expectEqualStrings("13", fixture.engine.status());
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
}

test "decision 33: a bidirectional stream answers each note at once, then streams from next" {
    var fixture: Fixture = .{ .engine = .{ .window = support.response_bytes } };
    // The first request note arrives and the client still sends: the handler echoes it through
    // its Sender, and `next` waits.
    fixture.call("/test.Svc/Chat", "application/grpc+proto", 7, false);
    try testing.expect(!fixture.engine.ended);
    var early = fixture.notes();
    try testing.expectEqualStrings("7", (try early.next()).?.text);
    try testing.expect(early.at_end());
    // A `writable` while the request is open finds nothing to send, and cancels nothing.
    fixture.writable();
    try testing.expect(!fixture.engine.ended);
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
    // The request ends: `next` now gives the seven notes the client asked for, then the end.
    fixture.end_request();
    try fixture.drain(window);
    var notes = fixture.notes();
    try testing.expectEqualStrings("7", (try notes.next()).?.text);
    try notes.expect_count(7);
    try testing.expect(notes.at_end());
    try testing.expectEqualStrings("0", fixture.engine.status());
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
}

test "decision 33: a note from a Sender goes out after the note the call holds" {
    // The engine takes the echo and then blocks, so the first notes fill the memory, and the
    // route holds the note that found no room.
    var fixture: Fixture = .{ .engine = .{ .window = window_echo }, .app = .{ .early = true } };
    fixture.call("/test.Svc/Chat", "application/grpc+proto", 12, false);
    fixture.writable();
    try testing.expectEqual(@as(usize, window_echo), fixture.engine.taken);
    const given = fixture.app.next_calls;
    try testing.expect(given > 1 and given < 12);
    // The engine takes again, and a second request note arrives: its echo follows the held note.
    fixture.engine.window = support.response_bytes * 2;
    fixture.send("12", true);
    try fixture.drain(window);
    var notes = fixture.notes();
    try testing.expectEqualStrings("12", (try notes.next()).?.text);
    try notes.expect_range(0, @intCast(given));
    try testing.expectEqualStrings("12", (try notes.next()).?.text);
    try notes.expect_range(@intCast(given), 12);
    try testing.expect(notes.at_end());
    try testing.expectEqualStrings("0", fixture.engine.status());
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
}

/// Echoes `echoes` notes one by one over an engine that holds each run, and ends the request.
/// Over h3 a response holds 16 runs at most until the client acknowledges them, and each flush
/// cuts a run. So the flush of the seventeenth echo fails, its octets stay in the writer, which
/// sends them later (colibri's usage guide), and the stream's end finds every run held too.
fn echo_held(fixture: *Fixture, content_type: []const u8) !support.Notes {
    fixture.call("/test.Svc/Chat", content_type, 0, false);
    // The call sent the first note, and the last one ends the request.
    for (1..echoes - 1) |_| fixture.send("0", false);
    fixture.send("0", true);
    try fixture.acknowledge_late();
    var notes = fixture.notes();
    for (0..echoes) |_| try testing.expectEqualStrings("0", (try notes.next()).?.text);
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
    try testing.expectEqual(@as(?connect.Code, null), fixture.app.outcome);
    return notes;
}

test "decision 33: a Sender's notes stay sent, and gRPC's trailers wait, while every run is held" {
    var fixture: Fixture = .{ .engine = .{ .holds = true } };
    var notes = try echo_held(&fixture, "application/grpc+proto");
    try testing.expect(notes.at_end());
    try testing.expectEqualStrings("0", fixture.engine.status());
}

test "decision 33: the end of a Connect stream waits while every run is held" {
    var fixture: Fixture = .{ .engine = .{ .holds = true } };
    var notes = try echo_held(&fixture, "application/connect+proto");
    const end = (try notes.reader.next()).?;
    try testing.expect(end.flags.end_stream);
    try testing.expect(notes.at_end());
}

test "decision 33: each call of on_writable hands its notes to the engine, before the stream ends" {
    var fixture: Fixture = .{ .engine = .{ .window = support.response_bytes * 2 }, .app = .{ .early = true } };
    fixture.call("/test.Svc/Chat", "application/grpc+proto", 3, false);
    fixture.writable();
    // The client still sends and the handler waits, and the engine has the echo and three notes.
    try testing.expect(!fixture.engine.ended);
    var notes = fixture.notes();
    try testing.expectEqualStrings("3", (try notes.next()).?.text);
    try notes.expect_range(0, 3);
    try testing.expect(notes.at_end());
}

test "decision 33: an error from on_message ends the stream after the note the call holds" {
    var fixture: Fixture = .{ .engine = .{ .window = window_echo }, .app = .{ .early = true } };
    fixture.call("/test.Svc/Chat", "application/grpc+proto", 12, false);
    fixture.writable();
    const given = fixture.app.next_calls;
    // A note that names no count: the handler answers `invalid_argument` while the route holds
    // a note and the memory is full.
    fixture.send("x", false);
    try fixture.drain(window);
    var notes = fixture.notes();
    try testing.expectEqualStrings("12", (try notes.next()).?.text);
    try notes.expect_range(0, @intCast(given));
    try testing.expect(notes.at_end());
    // statuscodes.md: INVALID_ARGUMENT is 3.
    try testing.expectEqualStrings("3", fixture.engine.status());
    try testing.expectEqual(@as(usize, 0), fixture.engine.cancelled);
    try testing.expectEqual(@as(?connect.Code, .invalid_argument), fixture.app.outcome);
}

test "decision 33: the interceptors run once around a stream with next" {
    var fixture: Fixture = .{ .engine = .{}, .app = .{ .fail_after = 50 } };
    fixture.call("/test.Svc/Count", "application/grpc+proto", notes_long, true);
    try testing.expectEqual(@as(usize, 1), fixture.app.calls);
    try testing.expectEqual(@as(usize, 0), fixture.app.finishes);
    try fixture.drain(window);
    try testing.expectEqual(@as(usize, 1), fixture.app.calls);
    try testing.expectEqual(@as(usize, 1), fixture.app.finishes);
    try testing.expectEqual(@as(?connect.Code, .aborted), fixture.app.outcome);
}

test "decision 33: a call the route refused at its head runs no interceptor at on_writable" {
    const Chat = rpc.Route(App, support.chat, support.Chatter, support.options);
    var app: App = .{};
    var state: Chat.State = .{};
    // What `begin` leaves of a request it refused: no call, and a stream that is done.
    state.done = true;
    state.outgoing.phase = .done;
    try Chat.on_writable(&app, &state, undefined);
    try testing.expectEqual(@as(usize, 0), app.calls);
}

test "decision 33: a route table tells a stream with next from one with a Sender" {
    var parameters: server.PathParameters = undefined;
    try testing.expect(support.Router.match("POST", "/test.Svc/Count", &parameters) == .found);
    try testing.expect(support.Router.match("POST", "/test.Svc/Chat", &parameters) == .found);
    // A route with `next` declares `on_writable`, and a route with a Sender alone declares none.
    try testing.expect(@hasDecl(rpc.Route(App, support.count, support.Counter, support.options), "on_writable"));
    try testing.expect(!@hasDecl(rpc.Route(App, support.count, support.on_count, support.options), "on_writable"));
    try testing.expectEqual(connect.StreamType.server_stream, support.count.stream_type);
}
