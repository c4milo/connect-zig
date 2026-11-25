//! The streamed calls of `main.zig`: a client that writes each request message with its
//! `Sender` and reads each answer as its piece arrives (decision 18 as amended).
//!
//! - Chat, over Connect, gRPC and gRPC-Web. Over h2 and h3 it is full-duplex: the client sends
//!   one line, reads its answer, and only then sends the next, so each answer arrives before the
//!   next line goes. Over h11 it is half-duplex: the client sends every line and ends its stream
//!   before it reads any answer (decision 18; `rpc.full_duplex`).
//! - Sum, over gRPC. The client hands each number as a piece of its own, once the pool took the
//!   one before, and reads the sum and the status from the trailers.
const std = @import("std");
const connect = @import("connect_zig").connect;
const client = @import("connect_zig").colibri.client;
const rpc = @import("connect_zig").connect_colibri;
const harness = @import("harness");
const streaming = @import("streaming");
const service = @import("streaming_service");
const constants = @import("constants.zig");
const program = @import("main.zig");
const StreamingService = streaming.StreamingService;
const lines = program.lines;
const echoes = program.echoes;
const numbers = program.numbers;

const ChatCall = harness.Call(StreamingService.chat, .{});
const ChatSender = rpc.ClientCall(StreamingService.chat, .{}).Sender;
const SumCall = harness.Call(StreamingService.sum, .{});

/// One Chat call and what it saw: the lines it sent, the answers it read, and how many answers
/// it had read when each line went.
const Chat = struct {
    call: ChatCall,
    reading: harness.ReadBuffers,
    duplex: bool,
    sent: u32,
    answered: u32,
    answered_at_send: [lines.len]u32,
    closed: bool,
    ended: bool,

    fn begin(chat: *Chat, shared: *const connect.Client, rounds: *program.Rounds, protocol: client.Protocol, rpc_protocol: connect.Protocol) !void {
        chat.duplex = rpc.full_duplex(protocol);
        chat.sent = 0;
        chat.answered = 0;
        chat.closed = false;
        chat.ended = false;
        const call = &chat.call.call;
        try chat.call.init_stream(shared, {}, &.{ .protocol = rpc_protocol });
        try call.start(rounds.pool());
        try rounds.listen(.{ .id = call.id, .context = chat, .on_event = on_event });
        var sender = call.sender();
        if (chat.duplex) return chat.send_next(&sender);
        // Half-duplex: the whole request goes before any answer is read.
        for (&lines) |*line| try chat.send(&sender, line);
        try sender.close_send();
        chat.closed = true;
    }

    fn send(chat: *Chat, sender: *ChatSender, line: *const streaming.ChatMessage) !void {
        try sender.send(line);
        chat.answered_at_send[chat.sent] = chat.answered;
        chat.sent += 1;
    }

    /// Sends the next line, or ends the stream once every line went.
    fn send_next(chat: *Chat, sender: *ChatSender) !void {
        if (chat.sent == lines.len) {
            try sender.close_send();
            chat.closed = true;
            return;
        }
        try chat.send(sender, &lines[chat.sent]);
    }

    fn on_event(context: *anyopaque, event: client.Event) anyerror!void {
        const chat: *Chat = @ptrCast(@alignCast(context));
        const call = &chat.call.call;
        switch (event) {
            .headers => call.on_headers(chat.reading.storage()),
            .body_taken => try call.on_body_taken(),
            .body => |piece| {
                call.on_body(piece.len);
                try chat.read_answers();
            },
            .finished => chat.ended = true,
            else => return error.CallWrong,
        }
    }

    /// Reads each answer that arrived whole. Over h2 and h3 each one lets the next line go.
    fn read_answers(chat: *Chat) !void {
        const call = &chat.call.call;
        for (0..echoes.len + 1) |_| {
            const answer = try call.reader.next(streaming.ChatMessage) orelse return;
            if (chat.answered == echoes.len) return error.CallWrong;
            if (!std.mem.eql(u8, answer.text, echoes[chat.answered])) return error.CallWrong;
            chat.answered += 1;
            var sender = call.sender();
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
        var response = chat.call.call.read(chat.reading.storage());
        try harness.expect_end(&response, streaming.ChatMessage);
        try chat.expect_trailer(&response, service.received_trailer, "3");
        try chat.expect_trailer(&response, service.sent_trailer, "4");
    }

    /// Checks a trailer of the call: gRPC's come in HTTP trailers (PROTOCOL-HTTP2.md,
    /// "Responses"), and Connect's and gRPC-Web's in the body, which `metadata` holds.
    fn expect_trailer(chat: *const Chat, response: *const connect.client.Response, name: []const u8, value: []const u8) !void {
        if (response.speaks.protocol != .grpc) return harness.expect_trailer(response.metadata, name, value);
        const held = chat.call.call.response.trailers.get(name) orelse return error.CallWrong;
        if (!std.mem.eql(u8, held, value)) return error.CallWrong;
    }
};

/// One Sum call, which hands each number once the pool took the one before.
const Sum = struct {
    call: SumCall,
    reading: harness.ReadBuffers,
    sent: u32,
    taken: u32,
    ended: bool,

    fn begin(sum: *Sum, shared: *const connect.Client, rounds: *program.Rounds) !void {
        sum.sent = 0;
        sum.taken = 0;
        sum.ended = false;
        const call = &sum.call.call;
        try sum.call.init_stream(shared, {}, &.{ .protocol = .grpc });
        try call.start(rounds.pool());
        try rounds.listen(.{ .id = call.id, .context = sum, .on_event = on_event });
        try sum.send_next();
    }

    fn send_next(sum: *Sum) !void {
        var sender = sum.call.call.sender();
        if (sum.sent == numbers.len) return sender.close_send();
        try sender.send(&numbers[sum.sent]);
        sum.sent += 1;
    }

    fn on_event(context: *anyopaque, event: client.Event) anyerror!void {
        const sum: *Sum = @ptrCast(@alignCast(context));
        const call = &sum.call.call;
        switch (event) {
            .headers => call.on_headers(sum.reading.storage()),
            // Each number is a piece of its own: the next goes once the pool took this one.
            .body_taken => {
                sum.taken += 1;
                try call.on_body_taken();
                if (sum.taken <= numbers.len) try sum.send_next();
            },
            .body => |piece| call.on_body(piece.len),
            .finished => sum.ended = true,
            else => return error.CallWrong,
        }
    }

    fn check(sum: *Sum) !void {
        // Each number, then the empty piece that ends the stream, went alone.
        if (!sum.ended or sum.taken != numbers.len + 1) return error.CallWrong;
        var response = sum.call.call.read(sum.reading.storage());
        const answer = try response.next(streaming.SumResponse) orelse return error.CallWrong;
        if (answer.sum != constants.numbers_sum or answer.count != numbers.len) return error.CallWrong;
        try harness.expect_end(&response, streaming.SumResponse);
    }
};

/// The protocols each round's Chat calls speak, one call each.
const chat_protocols = [_]connect.Protocol{ .connect, .grpc, .grpc_web };

/// The streamed calls of one round: a Chat in each protocol of `chat_protocols`, and a Sum.
/// The program keeps them in its state, so they stay in place until the round ends.
pub const Streamed = struct {
    chats: [chat_protocols.len]Chat,
    sum: Sum,

    /// Starts the streamed calls of a round over `protocol`, with `shared`, the program's client.
    pub fn begin(streamed: *Streamed, shared: *const connect.Client, rounds: *program.Rounds, protocol: client.Protocol) !void {
        for (&streamed.chats, chat_protocols) |*chat, rpc_protocol| try chat.begin(shared, rounds, protocol, rpc_protocol);
        try streamed.sum.begin(shared, rounds);
    }

    /// Checks what the streamed calls read, once the round finished.
    pub fn check(streamed: *Streamed) !void {
        for (&streamed.chats) |*chat| try chat.check();
        try streamed.sum.check();
    }
};
