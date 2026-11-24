//! The ELIZA service, connectrpc.eliza.v1.ElizaService: one handler for each method (design §8
//! step 5). A program's `App` holds the service's `Room` in its field `eliza`, so one route table
//! may serve ELIZA beside other services (decision 41). Say also answers a GET, since it has no
//! side effects.
const std = @import("std");
const connect = @import("connect_zig").connect;
const rpc = @import("connect_zig").connect_colibri;
const eliza = @import("eliza");
const constants = @import("constants.zig");

/// The service's part of a program's `App`. A reply is written into the response before its
/// handler returns, so one room serves every call, even while several calls run at once.
pub const Room = struct {
    text: [constants.text_len_max]u8 = undefined,
};

/// The route options of each method: room for a message and a JSON token of the longest text.
pub const route_options: rpc.RouteOptions = .{ .message_bytes = constants.text_len_max, .token_bytes = constants.text_len_max };

/// ELIZA's handlers over `App`, and their entries in a route table: `Service(App).routes`. Each
/// handler passes the call to the function below of the same name, with the service's room.
pub fn Service(comptime App: type) type {
    return struct {
        pub const routes = eliza.ElizaService.Routes(rpc, App, @This(), route_options).routes;

        pub fn say(app: *App, _: *rpc.Context, request: *const rpc.Request(eliza.SayRequest), response: *rpc.Response(eliza.SayResponse)) ?connect.RpcError {
            return say_in(&app.eliza, request, response);
        }

        pub fn introduce(app: *App, _: *rpc.Context, request: *const rpc.Request(eliza.IntroduceRequest), response: *rpc.ResponseStream(eliza.IntroduceResponse)) ?connect.RpcError {
            return introduce_in(&app.eliza, request, response);
        }

        pub fn converse(app: *App, _: *rpc.Context, request: *rpc.RequestStream(eliza.ConverseRequest), response: *rpc.ResponseStream(eliza.ConverseResponse)) ?connect.RpcError {
            return converse_in(&app.eliza, request, response);
        }
    };
}

/// Say answers one sentence.
fn say_in(room: *Room, request: *const rpc.Request(eliza.SayRequest), response: *rpc.Response(eliza.SayResponse)) ?connect.RpcError {
    if (request.message.sentence.len == 0) return .{ .code = .invalid_argument, .message = "say something" };
    response.message.sentence = reply(room, "You said \"{s}\". How does that make you feel?", .{request.message.sentence});
    return null;
}

/// Introduce answers a name with three sentences.
fn introduce_in(room: *Room, request: *const rpc.Request(eliza.IntroduceRequest), response: *rpc.ResponseStream(eliza.IntroduceResponse)) ?connect.RpcError {
    const who = if (request.message.name.len == 0) "friend" else request.message.name;
    const lines = [_][]const u8{ "Hi {s}, I am Eliza.", "Before we begin, {s}, tell me how you came here.", "How are you feeling today, {s}?" };
    inline for (lines) |line| {
        response.send(&.{ .sentence = reply(room, line, .{who}) }) catch return .{ .code = .resource_exhausted };
    }
    return null;
}

/// Converse answers each sentence it reads, in order.
fn converse_in(room: *Room, request: *rpc.RequestStream(eliza.ConverseRequest), response: *rpc.ResponseStream(eliza.ConverseResponse)) ?connect.RpcError {
    for (0..constants.conversation_turns_max) |_| {
        const turn = request.next() orelse break;
        response.send(&.{ .sentence = reply(room, "Why do you say \"{s}\"?", .{turn.sentence}) }) catch return .{ .code = .resource_exhausted };
    }
    response.add_trailer("eliza-turns", "done") catch {};
    return null;
}

/// Writes a reply into `room`, which stays valid until the next call writes there.
fn reply(room: *Room, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&room.text, format, args) catch "too long";
}

/// The examples' sentences: what a client sends, and what ELIZA answers.
pub const said = "I feel tired";
pub const say_answer = "You said \"I feel tired\". How does that make you feel?";
pub const name = "Ada";
pub const introduce_answers = [_][]const u8{ "Hi Ada, I am Eliza.", "Before we begin, Ada, tell me how you came here.", "How are you feeling today, Ada?" };
pub const conversation = [_][]const u8{ "Hello", "I dream of code" };
pub const converse_answers = [_][]const u8{ "Why do you say \"Hello\"?", "Why do you say \"I dream of code\"?" };
