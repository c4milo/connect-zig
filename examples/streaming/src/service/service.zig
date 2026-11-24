//! The streaming service, streaming.v1.StreamingService: a handler for each method, and the
//! interceptor around Chat. A program's `App` holds the service's `Room` in its field
//! `streaming`, so one route table may serve it beside other services (decision 41).
//!
//! - Chat and Sum are type handlers: they take each message as it arrives. Chat answers each one
//!   at once, so over h2 a client reads answers while it still sends. `Counting` reports how
//!   many messages a Chat read and wrote, in trailers.
//! - Countdown is a server stream whose route asks it for one number at a time, so the stream
//!   may be far longer than the router's response memory (decision 33).
const std = @import("std");
const connect = @import("connect_zig").connect;
const rpc = @import("connect_zig").connect_colibri;
const streaming = @import("streaming");
const constants = @import("constants.zig");
const StreamingService = streaming.StreamingService;

/// The service's part of a program's `App`. A reply and a trailer go out before their handler
/// returns, so one room serves every call, even while several calls run at once.
pub const Room = struct {
    text: [constants.text_len_max]u8 = undefined,
    /// The digits of the counts `Counting` reports.
    received_digits: [constants.count_len_max]u8 = undefined,
    sent_digits: [constants.count_len_max]u8 = undefined,
};

/// The route options of each method: room for a message and a JSON token of the longest text.
pub const route_options: rpc.RouteOptions = .{ .message_bytes = constants.text_len_max, .token_bytes = constants.text_len_max };

/// The largest `from` Countdown counts down from.
pub const countdown_max = constants.countdown_max;
/// The trailer Chat adds once the client ends its stream: whether it answered any message.
pub const turns_trailer = "chat-turns";
/// The trailers `Counting` adds: the messages a call read and wrote.
pub const received_trailer = "call-received";
pub const sent_trailer = "call-sent";

/// The service's handlers over `App`, and their entries in a route table:
/// `Service(App).routes`. Each handler passes the call to the function below of the same name,
/// with the service's room.
pub fn Service(comptime App: type) type {
    return struct {
        /// Chat runs behind `Counting`; Sum and Countdown run behind no interceptor.
        pub const routes = .{
            rpc.post(App, StreamingService.chat, Chat, counted),
            rpc.post(App, StreamingService.sum, Sum, route_options),
            rpc.post(App, StreamingService.countdown, Countdown, route_options),
        };
        const counted = with_interceptors(&.{Counting});

        /// Adds trailers that count the messages a call read and wrote, once it ends.
        pub const Counting = struct {
            pub fn on_finish(app: *App, ctx: *rpc.Context, response: *rpc.AnyResponse, failure: ?connect.RpcError) ?connect.RpcError {
                return count_finish(&app.streaming, ctx, response, failure);
            }
        };

        /// Chat answers each message the moment it arrives, and says goodbye when the client
        /// ends.
        pub const Chat = struct {
            pub const State = ChatState;

            pub fn on_message(app: *App, _: *rpc.Context, state: *State, request: *const rpc.Request(streaming.ChatMessage), response: *rpc.ResponseStream(streaming.ChatMessage)) ?connect.RpcError {
                return chat_message(&app.streaming, state, request, response);
            }

            pub fn on_end(app: *App, _: *rpc.Context, state: *State, _: *const rpc.AnyRequest, response: *rpc.ResponseStream(streaming.ChatMessage)) ?connect.RpcError {
                return chat_end(&app.streaming, state, response);
            }
        };

        /// Sum adds the numbers as they arrive, and answers once the client ends its stream.
        pub const Sum = struct {
            pub const State = SumState;

            pub fn on_message(_: *App, _: *rpc.Context, state: *State, request: *const rpc.Request(streaming.SumRequest)) ?connect.RpcError {
                return sum_message(state, request);
            }

            pub fn on_end(_: *App, _: *rpc.Context, state: *State, _: *const rpc.AnyRequest, response: *rpc.Response(streaming.SumResponse)) ?connect.RpcError {
                return sum_end(state, response);
            }
        };

        /// Countdown sends `from`, `from - 1`, ... down to 1. Its route calls `next` for one
        /// number at a time, while the response memory has room.
        pub const Countdown = struct {
            pub const State = CountdownState;

            pub fn on_request(_: *App, _: *rpc.Context, state: *State, request: *const rpc.Request(streaming.CountdownRequest)) ?connect.RpcError {
                return countdown_request(state, request);
            }

            pub fn next(_: *App, _: *rpc.Context, state: *State, response: *rpc.Response(streaming.CountdownResponse)) rpc.Next {
                return countdown_next(state, response);
            }
        };
    };
}

fn with_interceptors(comptime interceptors: []const type) rpc.RouteOptions {
    var options = route_options;
    options.interceptors = interceptors;
    return options;
}

/// Writes the counts of messages the call read and wrote as trailers. The trailers go out as
/// soon as `on_finish` returns, so one room serves every call.
fn count_finish(room: *Room, ctx: *rpc.Context, response: *rpc.AnyResponse, failure: ?connect.RpcError) ?connect.RpcError {
    // A u32 has at most `count_len_max` digits, so each count fits.
    const received = std.fmt.bufPrint(&room.received_digits, "{d}", .{ctx.received()}) catch unreachable;
    const sent = std.fmt.bufPrint(&room.sent_digits, "{d}", .{ctx.sent()}) catch unreachable;
    response.add_trailer(received_trailer, received) catch {};
    response.add_trailer(sent_trailer, sent) catch {};
    return failure;
}

/// What one Chat call keeps: the messages it answered.
const ChatState = struct { turns: u32 = 0 };

fn chat_message(room: *Room, state: *ChatState, request: *const rpc.Request(streaming.ChatMessage), response: *rpc.ResponseStream(streaming.ChatMessage)) ?connect.RpcError {
    // An error from `on_message` ends the call at once, after the answers already sent.
    if (request.message.text.len == 0) return .{ .code = .invalid_argument, .message = "empty message" };
    state.turns += 1;
    // `send` writes the message out before it returns, so `room.text` is free again after.
    response.send(&.{ .text = reply(room, "echo: {s}", .{request.message.text}) }) catch return .{ .code = .resource_exhausted };
    return null;
}

fn chat_end(room: *Room, state: *ChatState, response: *rpc.ResponseStream(streaming.ChatMessage)) ?connect.RpcError {
    response.send(&.{ .text = reply(room, "bye after {d}", .{state.turns}) }) catch return .{ .code = .resource_exhausted };
    response.add_trailer(turns_trailer, if (state.turns == 0) "none" else "some") catch {};
    return null;
}

/// What one Sum call keeps: the sum so far, and the numbers it read.
const SumState = struct { sum: i64 = 0, count: i64 = 0 };

fn sum_message(state: *SumState, request: *const rpc.Request(streaming.SumRequest)) ?connect.RpcError {
    state.sum +|= request.message.number;
    state.count += 1;
    return null;
}

fn sum_end(state: *SumState, response: *rpc.Response(streaming.SumResponse)) ?connect.RpcError {
    response.message = .{ .sum = state.sum, .count = state.count };
    return null;
}

/// What one Countdown call keeps: the numbers it has yet to send.
const CountdownState = struct { left: i32 = 0 };

fn countdown_request(state: *CountdownState, request: *const rpc.Request(streaming.CountdownRequest)) ?connect.RpcError {
    if (request.message.from < 0 or request.message.from > countdown_max) return .{ .code = .out_of_range, .message = "from must be between 0 and 1000000" };
    state.left = request.message.from;
    return null;
}

fn countdown_next(state: *CountdownState, response: *rpc.Response(streaming.CountdownResponse)) rpc.Next {
    if (state.left == 0) return .end;
    response.message = .{ .number = state.left };
    state.left -= 1;
    return .message;
}

/// Writes a reply into `room`, which stays valid until the next call writes there.
fn reply(room: *Room, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&room.text, format, args) catch "too long";
}
