//! Example: every kind of stream, over Connect and gRPC-Web, on h2 and on h11.
//!
//! - Chat is a bidirectional stream, which an empty message fails. Its handler in `services/demo.zig` is a type whose
//!   `on_message` answers each message the moment it arrives, so over h2 the server writes
//!   answers while the client still sends. colibri's client sends its body whole, so here the
//!   client sends all of its messages first; `buf curl` shows the full-duplex side, see
//!   `tools/interop_check.sh`.
//! - Sum is a client stream, whose type handler adds each number as it arrives and answers once
//!   the client ends.
//! - Countdown is a server stream, which also fails when asked to count from too far.
//!
//! Run it with `zig build example-streaming`.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const adapter = @import("connect_colibri");
const demo = @import("demo");
const service = @import("services/demo.zig");
const harness = @import("services/link_client.zig");
const Service = demo.DemoService;

const calls_count = 7;
const countdown_from = 3;

pub const Error = error{ExchangeWrong};

const lines = [_]demo.ChatMessage{ .{ .text = "hello" }, .{ .text = "how are you" }, .{ .text = "goodbye" } };
const echoes = [_][]const u8{ "echo: hello", "echo: how are you", "echo: goodbye", "bye after 3" };
const numbers = [_]demo.SumRequest{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 }, .{ .number = 4 } };
const numbers_sum = 10;

var chat: adapter.Exchange(Service.chat) align(@alignOf(adapter.Exchange(Service.chat))) = undefined;
var chat_refused: adapter.Exchange(Service.chat) align(@alignOf(adapter.Exchange(Service.chat))) = undefined;
var chat_silent: adapter.Exchange(Service.chat) align(@alignOf(adapter.Exchange(Service.chat))) = undefined;
var sum: adapter.Exchange(Service.sum) align(@alignOf(adapter.Exchange(Service.sum))) = undefined;
var sum_web: adapter.Exchange(Service.sum) align(@alignOf(adapter.Exchange(Service.sum))) = undefined;
var countdown: adapter.Exchange(Service.countdown) align(@alignOf(adapter.Exchange(Service.countdown))) = undefined;
var countdown_far: adapter.Exchange(Service.countdown) align(@alignOf(adapter.Exchange(Service.countdown))) = undefined;
var buffers: [calls_count]harness.CallBuffers align(@alignOf(harness.CallBuffers)) = undefined;

pub fn main() !void {
    try harness.init();
    defer harness.deinit();
    try round(.{ .h11 = false, .h3 = false }, .h2);
    try round(.{ .h2 = false, .h3 = false }, .h11);
    std.debug.print("streaming: every stream answered as expected over h2 and h11\n", .{});
}

fn round(protocols: client.Protocols, expected: client.Protocol) !void {
    try harness.begin(protocols);
    try chat.init(.{ .codec = .json }, &lines, harness.buffers(&buffers[0]));
    try chat_silent.init(.{ .protocol = .grpc_web }, &.{}, harness.buffers(&buffers[1]));
    try chat_refused.init(.{}, &.{ .{ .text = "x" }, .{ .text = "" }, .{ .text = "never read" } }, harness.buffers(&buffers[6]));
    try sum.init(.{}, &numbers, harness.buffers(&buffers[2]));
    try sum_web.init(.{ .protocol = .grpc_web, .codec = .json }, &numbers, harness.buffers(&buffers[3]));
    try countdown.init(.{}, &.{.{ .from = countdown_from }}, harness.buffers(&buffers[4]));
    try countdown_far.init(.{ .protocol = .grpc_web }, &.{.{ .from = service.countdown_max + 1 }}, harness.buffers(&buffers[5]));
    try harness.request(&chat.request, &chat.response);
    try harness.request(&chat_silent.request, &chat_silent.response);
    try harness.request(&chat_refused.request, &chat_refused.response);
    try harness.request(&sum.request, &sum.response);
    try harness.request(&sum_web.request, &sum_web.response);
    try harness.request(&countdown.request, &countdown.response);
    try harness.request(&countdown_far.request, &countdown_far.response);
    try harness.finish(expected);
    try check_chat();
    try check_sum(&sum);
    try check_sum(&sum_web);
    try check_countdown();
    std.debug.print("streaming: round over {s} answered\n", .{@tagName(expected)});
}

fn check_chat() !void {
    var chatted = chat.read(harness.storage());
    for (echoes) |echo| {
        const message = try chatted.next(demo.ChatMessage) orelse return error.ExchangeWrong;
        if (!std.mem.eql(u8, message.text, echo)) return error.ExchangeWrong;
    }
    try expect_end(&chatted, demo.ChatMessage);
    // Chat's `on_end` adds a trailer, and `Counting` two more, which the Connect end-stream
    // message carries.
    try expect_trailer(chatted.metadata, service.turns_trailer, "some");
    try expect_trailer(chatted.metadata, service.received_trailer, "3");
    try expect_trailer(chatted.metadata, service.sent_trailer, "4");

    var silent = chat_silent.read(harness.storage());
    const bye = try silent.next(demo.ChatMessage) orelse return error.ExchangeWrong;
    if (!std.mem.eql(u8, bye.text, "bye after 0")) return error.ExchangeWrong;
    try expect_end(&silent, demo.ChatMessage);

    // The empty message fails the call: its answer to "x" arrived, and no message after.
    var refused = chat_refused.read(harness.storage());
    const echo = try refused.next(demo.ChatMessage) orelse return error.ExchangeWrong;
    if (!std.mem.eql(u8, echo.text, "echo: x")) return error.ExchangeWrong;
    if (try refused.next(demo.ChatMessage) != null) return error.ExchangeWrong;
    const failure = refused.failure orelse return error.ExchangeWrong;
    if (failure.code != .invalid_argument) return error.ExchangeWrong;
    try expect_trailer(refused.metadata, service.received_trailer, "2");
    try expect_trailer(refused.metadata, service.sent_trailer, "1");
}

fn expect_trailer(metadata: []const connect.Header, name: []const u8, value: []const u8) !void {
    for (metadata) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            if (std.mem.eql(u8, entry.value, value)) return;
            std.debug.print("streaming: trailer {s} is {s}, wanted {s}\n", .{ name, entry.value, value });
            return error.ExchangeWrong;
        }
    }
    std.debug.print("streaming: no trailer {s}\n", .{name});
    return error.ExchangeWrong;
}

fn check_sum(exchange: *const adapter.Exchange(Service.sum)) !void {
    var summed = exchange.read(harness.storage());
    const answer = try summed.next(demo.SumResponse) orelse return error.ExchangeWrong;
    if (answer.sum != numbers_sum or answer.count != numbers.len) return error.ExchangeWrong;
    try expect_end(&summed, demo.SumResponse);
}

fn check_countdown() !void {
    var counted = countdown.read(harness.storage());
    for (0..countdown_from) |index| {
        const message = try counted.next(demo.CountdownResponse) orelse return error.ExchangeWrong;
        if (message.number != countdown_from - index) return error.ExchangeWrong;
    }
    try expect_end(&counted, demo.CountdownResponse);

    var far = countdown_far.read(harness.storage());
    if (try far.next(demo.CountdownResponse) != null) return error.ExchangeWrong;
    const failure = far.failure orelse return error.ExchangeWrong;
    if (failure.code != .out_of_range) return error.ExchangeWrong;
}

/// Checks a response holds no message more, and ended in success.
fn expect_end(response: *connect.client.Response, comptime T: type) !void {
    if (try response.next(T) != null) return error.ExchangeWrong;
    if (response.failure) |failure| {
        std.debug.print("streaming: {s}: {s}\n", .{ failure.code.name(), failure.message });
        return error.ExchangeWrong;
    }
}
