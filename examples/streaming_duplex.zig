//! The streamed calls of `streaming.zig`: a client that writes each request message with its
//! `Sender` and reads each answer as its piece arrives (decision 18 as amended).
//!
//! - Chat, over Connect, gRPC and gRPC-Web. Over h2 and h3 it is full-duplex: the client sends one line, reads its
//!   answer, and only then sends the next, so each answer arrives before the next line goes.
//!   Over h11 it is half-duplex: the client sends every line and ends its stream before it reads
//!   any answer (decision 18; `rpc.full_duplex`).
//! - Sum, over gRPC. The client hands each number as a piece of its own, once the pool took the
//!   one before, and reads the sum and the status from the trailers.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const demo = @import("demo");
const service = @import("services/demo.zig");
const harness = @import("services/link_client.zig");
const Service = demo.DemoService;

const lines = [_]demo.ChatMessage{ .{ .text = "hello" }, .{ .text = "how are you" }, .{ .text = "goodbye" } };
const echoes = [_][]const u8{ "echo: hello", "echo: how are you", "echo: goodbye", "bye after 3" };
const numbers = [_]demo.SumRequest{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 }, .{ .number = 4 } };
const numbers_sum = 10;

const ChatCall = rpc.ClientCall(Service.chat, .{});
const SumCall = rpc.ClientCall(Service.sum, .{});

/// One Chat call and what it saw: the lines it sent, the answers it read, and how many answers
/// it had read when each line went.
const Chat = struct {
    call: ChatCall = undefined,
    reading: harness.ReadBuffers = .{},
    duplex: bool = false,
    sent: u32 = 0,
    answered: u32 = 0,
    answered_at_send: [lines.len]u32 = undefined,
    closed: bool = false,
    ended: bool = false,

    fn begin(chat: *Chat, set: *harness.CallBuffers, protocol: client.Protocol, rpc_protocol: connect.Protocol) !void {
        chat.* = .{ .duplex = rpc.full_duplex(protocol) };
        try chat.call.init_stream(&.{ .protocol = rpc_protocol }, &harness.buffers(set));
        try chat.call.start(harness.pool_of());
        try harness.listen(.{ .id = chat.call.id, .context = chat, .on_event = on_event });
        var sender = chat.call.sender();
        if (chat.duplex) return chat.send_next(&sender);
        // Half-duplex: the whole request goes before any answer is read.
        for (&lines) |*line| try chat.send(&sender, line);
        try sender.close_send();
        chat.closed = true;
    }

    fn send(chat: *Chat, sender: *ChatCall.Sender, line: *const demo.ChatMessage) !void {
        try sender.send(line);
        chat.answered_at_send[chat.sent] = chat.answered;
        chat.sent += 1;
    }

    /// Sends the next line, or ends the stream once every line went.
    fn send_next(chat: *Chat, sender: *ChatCall.Sender) !void {
        if (chat.sent == lines.len) {
            try sender.close_send();
            chat.closed = true;
            return;
        }
        try chat.send(sender, &lines[chat.sent]);
    }

    fn on_event(context: *anyopaque, event: client.Event) anyerror!void {
        const chat: *Chat = @ptrCast(@alignCast(context));
        switch (event) {
            .headers => chat.call.on_headers(chat.reading.storage()),
            .body_taken => try chat.call.on_body_taken(),
            .body => |piece| {
                chat.call.on_body(piece.len);
                try chat.read_answers();
            },
            .finished => chat.ended = true,
            else => return error.CallWrong,
        }
    }

    /// Reads each answer that arrived whole. Over h2 and h3 each one lets the next line go.
    fn read_answers(chat: *Chat) !void {
        for (0..echoes.len + 1) |_| {
            const answer = try chat.call.reader.next(demo.ChatMessage) orelse return;
            if (chat.answered == echoes.len) return error.CallWrong;
            if (!std.mem.eql(u8, answer.text, echoes[chat.answered])) return error.CallWrong;
            chat.answered += 1;
            var sender = chat.call.sender();
            if (chat.duplex and !chat.closed) try chat.send_next(&sender);
        }
        return error.CallWrong;
    }

    fn check(chat: *Chat) !void {
        if (!chat.ended or chat.answered != echoes.len) return error.CallWrong;
        for (chat.answered_at_send[0..lines.len], 0..) |answered, index| {
            // Full-duplex: the answer to each line came before the next line went. Half-duplex:
            // every line went before any answer came.
            const expected: u32 = if (chat.duplex) @intCast(index) else 0;
            if (answered != expected) return error.CallWrong;
        }
        var response = chat.call.read(chat.reading.storage());
        try harness.expect_end(&response, demo.ChatMessage);
        try chat.expect_trailer(&response, service.received_trailer, "3");
        try chat.expect_trailer(&response, service.sent_trailer, "4");
    }

    /// Checks a trailer of the call: gRPC's come in HTTP trailers (PROTOCOL-HTTP2.md,
    /// "Responses"), and Connect's and gRPC-Web's in the body, which `metadata` holds.
    fn expect_trailer(chat: *const Chat, response: *const connect.client.Response, name: []const u8, value: []const u8) !void {
        if (response.speaks.protocol != .grpc) return harness.expect_trailer(response.metadata, name, value);
        const held = chat.call.response.trailers.get(name) orelse return error.CallWrong;
        if (!std.mem.eql(u8, held, value)) return error.CallWrong;
    }
};

/// One Sum call, which hands each number once the pool took the one before.
const Sum = struct {
    call: SumCall = undefined,
    reading: harness.ReadBuffers = .{},
    sent: u32 = 0,
    taken: u32 = 0,
    ended: bool = false,

    fn begin(sum: *Sum, set: *harness.CallBuffers) !void {
        sum.* = .{};
        try sum.call.init_stream(&.{ .protocol = .grpc }, &harness.buffers(set));
        try sum.call.start(harness.pool_of());
        try harness.listen(.{ .id = sum.call.id, .context = sum, .on_event = on_event });
        try sum.send_next();
    }

    fn send_next(sum: *Sum) !void {
        var sender = sum.call.sender();
        if (sum.sent == numbers.len) return sender.close_send();
        try sender.send(&numbers[sum.sent]);
        sum.sent += 1;
    }

    fn on_event(context: *anyopaque, event: client.Event) anyerror!void {
        const sum: *Sum = @ptrCast(@alignCast(context));
        switch (event) {
            .headers => sum.call.on_headers(sum.reading.storage()),
            // Each number is a piece of its own: the next goes once the pool took this one.
            .body_taken => {
                sum.taken += 1;
                try sum.call.on_body_taken();
                if (sum.taken <= numbers.len) try sum.send_next();
            },
            .body => |piece| sum.call.on_body(piece.len),
            .finished => sum.ended = true,
            else => return error.CallWrong,
        }
    }

    fn check(sum: *Sum) !void {
        // Each number, then the empty piece that ends the stream, went alone.
        if (!sum.ended or sum.taken != numbers.len + 1) return error.CallWrong;
        var response = sum.call.read(sum.reading.storage());
        const answer = try response.next(demo.SumResponse) orelse return error.CallWrong;
        if (answer.sum != numbers_sum or answer.count != numbers.len) return error.CallWrong;
        try harness.expect_end(&response, demo.SumResponse);
    }
};

/// The protocols each round's Chat calls speak, one call each.
const chat_protocols = [_]connect.Protocol{ .connect, .grpc, .grpc_web };
/// The buffers of a round's streamed calls: each Chat's, then Sum's.
pub const calls_count = chat_protocols.len + 1;

var chat_calls: [chat_protocols.len]Chat align(@alignOf(Chat)) = undefined;
var sum_call: Sum align(@alignOf(Sum)) = .{};

/// Starts the streamed calls of a round over `protocol`.
pub fn begin(sets: *[calls_count]harness.CallBuffers, protocol: client.Protocol) !void {
    for (&chat_calls, chat_protocols, 0..) |*chat, rpc_protocol, index| try chat.begin(&sets[index], protocol, rpc_protocol);
    try sum_call.begin(&sets[chat_protocols.len]);
}

/// Checks what the streamed calls read, once the round finished.
pub fn check() !void {
    for (&chat_calls) |*chat| try chat.check();
    try sum_call.check();
}
