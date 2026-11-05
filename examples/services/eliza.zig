//! The ELIZA service: one handler for each method of connectrpc.eliza.v1.ElizaService, and its
//! entries in the route table of `routes.zig` (design §8 step 5).
const std = @import("std");
const connect = @import("connect");
const adapter = @import("connect_colibri");
const eliza = @import("eliza");
const Service = eliza.ElizaService;

/// The sentences Converse answers in one call, at most.
const conversation_turns_max = 16;

const app_file = @import("app.zig");
const App = app_file.App;
const reply = app_file.text_of;

/// Say answers one sentence.
pub fn say(app: *App, _: *adapter.Call, request: *const eliza.SayRequest, response: *eliza.SayResponse) ?connect.RpcError {
    if (request.sentence.len == 0) return .{ .code = .invalid_argument, .message = "say something" };
    response.sentence = reply(app, "You said \"{s}\". How does that make you feel?", .{request.sentence});
    return null;
}

/// Introduce answers a name with three sentences.
pub fn introduce(app: *App, _: *adapter.Call, request: *const eliza.IntroduceRequest, sender: *adapter.Sender(eliza.IntroduceResponse)) ?connect.RpcError {
    const who = if (request.name.len == 0) "friend" else request.name;
    const lines = [_][]const u8{ "Hi {s}, I am Eliza.", "Before we begin, {s}, tell me how you came here.", "How are you feeling today, {s}?" };
    inline for (lines) |line| {
        sender.send(&.{ .sentence = reply(app, line, .{who}) }) catch return .{ .code = .resource_exhausted };
    }
    return null;
}

/// Converse answers each sentence it reads, in order.
pub fn converse(app: *App, call: *adapter.Call, receiver: *adapter.Receiver(eliza.ConverseRequest), sender: *adapter.Sender(eliza.ConverseResponse)) ?connect.RpcError {
    for (0..conversation_turns_max) |_| {
        const sentence = receiver.next() orelse break;
        sender.send(&.{ .sentence = reply(app, "Why do you say \"{s}\"?", .{sentence.sentence}) }) catch return .{ .code = .resource_exhausted };
    }
    call.add_trailer("eliza-turns", "done") catch {};
    return null;
}

const route_options = app_file.route_options;

/// ELIZA's entries in the route table, which its generated `routes` lists: each method served by
/// the function of this file it names, and Say also as a GET, since it has no side effects.
pub const routes = Service.Routes(adapter, App, @This(), route_options).routes;

/// The examples' sentences: what the client sends, and what ELIZA answers.
pub const said = "I feel tired";
pub const say_answer = "You said \"I feel tired\". How does that make you feel?";
pub const name = "Ada";
pub const introduce_answers = [_][]const u8{ "Hi Ada, I am Eliza.", "Before we begin, Ada, tell me how you came here.", "How are you feeling today, Ada?" };
pub const conversation = [_][]const u8{ "Hello", "I dream of code" };
pub const converse_answers = [_][]const u8{ "Why do you say \"Hello\"?", "Why do you say \"I dream of code\"?" };
