//! Example: every kind of stream, over Connect and gRPC-Web, on h2, h11 and h3.
//!
//! - Chat is a bidirectional stream, which an empty message fails. Its handler in the service is
//!   a type whose `on_message` answers each message the moment it arrives, so over h2 and h3 the
//!   server writes answers while the client still sends. The calls here send their messages in
//!   one body. The streamed calls of `duplex.zig` send each one with a `Sender`, and over h2 and
//!   h3 read each answer before they send the next line.
//! - Sum is a client stream, whose type handler adds each number as it arrives and answers once
//!   the client ends.
//! - Countdown is a server stream, which also fails when asked to count from too far.
//!
//! Both sides run in one process over the in-memory links of the harness. Anything other than
//! the expected answers exits with an error, which is how `zig build test` and CI know the
//! example works. Run it with `zig build run`.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const harness = @import("harness");
const streaming = @import("streaming");
const service = @import("streaming_service");
const constants = @import("constants.zig");
const duplex = @import("duplex.zig");
const app_file = @import("app.zig");
const App = app_file.App;
const Router = app_file.Router;
const StreamingService = streaming.StreamingService;

comptime {
    _ = harness.hooks;
}

pub const Error = error{CallWrong};

pub const Rounds = harness.Rounds(App, Router);

/// The lines each Chat call sends, and the answers the service gives them.
pub const lines = [_]streaming.ChatMessage{ .{ .text = "hello" }, .{ .text = "how are you" }, .{ .text = "goodbye" } };
pub const echoes = [_][]const u8{ "echo: hello", "echo: how are you", "echo: goodbye", "bye after 3" };
/// The messages each Sum call sends: one for each number of `constants.sum_numbers`.
pub const numbers = sum_requests();

fn sum_requests() [constants.sum_numbers.len]streaming.SumRequest {
    var requests: [constants.sum_numbers.len]streaming.SumRequest = @splat(.{});
    for (&requests, constants.sum_numbers) |*request, number| request.number = number;
    return requests;
}

const ChatCall = harness.Call(StreamingService.chat, .{});
const SumCall = harness.Call(StreamingService.sum, .{});
const CountdownCall = harness.Call(StreamingService.countdown, .{});

/// All the program holds, which `main` allocates once (decision 42). colibri reads and writes
/// each call until its round ends, so the calls live here.
const State = struct {
    app: App,
    rounds: Rounds,
    chat: ChatCall,
    chat_silent: ChatCall,
    chat_refused: ChatCall,
    chat_cut: ChatCall,
    sum: SumCall,
    sum_web: SumCall,
    countdown: CountdownCall,
    countdown_far: CountdownCall,
    streamed: duplex.Streamed,
};

pub fn main(init: std.process.Init) !void {
    const state = try init.arena.allocator().create(State);
    state.app = .{};
    try state.rounds.init(&state.app);
    defer state.rounds.deinit();
    try round(state, .{ .h11 = false, .h3 = false }, .h2);
    try round(state, .{ .h2 = false, .h3 = false }, .h11);
    try round(state, .{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("streaming: every stream answered as expected over h2, h11 and h3\n", .{});
}

fn round(state: *State, protocols: client.Protocols, expected: client.Protocol) !void {
    const rounds = &state.rounds;
    try rounds.begin(protocols);
    try state.chat.init(&.{ .codec = .json }, &lines);
    try state.chat_silent.init(&.{ .protocol = .grpc_web }, &.{});
    try state.chat_refused.init(&.{}, &.{ .{ .text = "x" }, .{ .text = "" }, .{ .text = "never read" } });
    // A body that stops inside an envelope fails the call, after the answers already sent.
    try state.chat_cut.init(&.{}, &lines);
    const cut = &state.chat_cut.call.request;
    cut.body = cut.body[0 .. cut.body.len - 1];
    try state.sum.init(&.{}, &numbers);
    try state.sum_web.init(&.{ .protocol = .grpc_web, .codec = .json }, &numbers);
    try state.countdown.init(&.{}, &.{.{ .from = constants.countdown_from }});
    try state.countdown_far.init(&.{ .protocol = .grpc_web }, &.{.{ .from = service.countdown_max + 1 }});
    inline for (.{ "chat", "chat_silent", "chat_refused", "chat_cut", "sum", "sum_web", "countdown", "countdown_far" }) |field| {
        const call = &@field(state, field).call;
        try rounds.request(&call.request, &call.response);
    }
    try rounds.finish(expected);
    try check_chat(state);
    try check_cut(state);
    try check_sum(state, &state.sum);
    try check_sum(state, &state.sum_web);
    try check_countdown(state);
    std.debug.print("streaming: round over {s} answered\n", .{@tagName(expected)});
    // The server's router holds `constants.requests` calls at once, so the streamed calls take a
    // round of their own.
    try rounds.begin(protocols);
    try state.streamed.begin(rounds, expected);
    try rounds.finish(expected);
    try state.streamed.check();
    const mode = if (rpc.full_duplex(expected)) "full-duplex" else "half-duplex";
    std.debug.print("streaming: streamed round over {s} answered, {s}\n", .{ @tagName(expected), mode });
}

/// Reads one message of a response, and checks its text.
fn expect_text(response: *connect.client.Response, text: []const u8) !void {
    const message = try response.next(streaming.ChatMessage) orelse return error.CallWrong;
    if (!std.mem.eql(u8, message.text, text)) return error.CallWrong;
}

fn check_chat(state: *State) !void {
    const storage = state.rounds.storage();
    var chatted = state.chat.call.read(storage);
    for (echoes) |echo| try expect_text(&chatted, echo);
    try harness.expect_end(&chatted, streaming.ChatMessage);
    // Chat's `on_end` adds a trailer, and `Counting` two more, which the Connect end-stream
    // message carries.
    try harness.expect_trailer(chatted.metadata, service.turns_trailer, "some");
    try harness.expect_trailer(chatted.metadata, service.received_trailer, "3");
    try harness.expect_trailer(chatted.metadata, service.sent_trailer, "4");

    var silent = state.chat_silent.call.read(storage);
    try expect_text(&silent, "bye after 0");
    try harness.expect_end(&silent, streaming.ChatMessage);
    // gRPC-Web carries the call's trailers in its trailers frame.
    try harness.expect_trailer(silent.metadata, service.received_trailer, "0");
    try harness.expect_trailer(silent.metadata, service.sent_trailer, "1");

    // The empty message fails the call: its answer to "x" arrived, and no message after.
    var refused = state.chat_refused.call.read(storage);
    try expect_text(&refused, "echo: x");
    if (try refused.next(streaming.ChatMessage) != null) return error.CallWrong;
    const failure = refused.failure orelse return error.CallWrong;
    if (failure.code != .invalid_argument) return error.CallWrong;
    try harness.expect_trailer(refused.metadata, service.received_trailer, "2");
    try harness.expect_trailer(refused.metadata, service.sent_trailer, "1");
}

fn check_cut(state: *State) !void {
    var cut = state.chat_cut.call.read(state.rounds.storage());
    for (echoes[0 .. lines.len - 1]) |echo| try expect_text(&cut, echo);
    if (try cut.next(streaming.ChatMessage) != null) return error.CallWrong;
    const failure = cut.failure orelse return error.CallWrong;
    if (failure.code != .invalid_argument) return error.CallWrong;
    // The call ended through the interceptors, so `Counting` still reports it.
    try harness.expect_trailer(cut.metadata, service.received_trailer, "2");
}

fn check_sum(state: *State, sum: *const SumCall) !void {
    var summed = sum.call.read(state.rounds.storage());
    const answer = try summed.next(streaming.SumResponse) orelse return error.CallWrong;
    if (answer.sum != constants.numbers_sum or answer.count != numbers.len) return error.CallWrong;
    try harness.expect_end(&summed, streaming.SumResponse);
}

fn check_countdown(state: *State) !void {
    const storage = state.rounds.storage();
    var counted = state.countdown.call.read(storage);
    for (0..constants.countdown_from) |index| {
        const message = try counted.next(streaming.CountdownResponse) orelse return error.CallWrong;
        if (message.number != constants.countdown_from - index) return error.CallWrong;
    }
    try harness.expect_end(&counted, streaming.CountdownResponse);

    var far = state.countdown_far.call.read(storage);
    if (try far.next(streaming.CountdownResponse) != null) return error.CallWrong;
    const failure = far.failure orelse return error.CallWrong;
    if (failure.code != .out_of_range) return error.CallWrong;
}
