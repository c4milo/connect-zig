//! The ELIZA service: one handler for each method of connectrpc.eliza.v1.ElizaService, and its
//! entries in the route table of `routes.zig` (design §8 step 5).
const std = @import("std");
const connect = @import("connect");
const adapter = @import("connect_colibri");
const eliza = @import("eliza");
const Service = eliza.ElizaService;

/// The sentences Converse answers in one call, at most.
const conversation_turns_max = 16;

const App = @import("app.zig").App;

fn reply(app: *App, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&app.text, format, args) catch "I have nothing to say to that.";
}

/// Say answers one sentence.
fn say(app: *App, _: *adapter.Call, request: *const eliza.SayRequest, response: *eliza.SayResponse) ?connect.RpcError {
    app.calls += 1;
    if (request.sentence.len == 0) return .{ .code = .invalid_argument, .message = "say something" };
    response.sentence = reply(app, "You said \"{s}\". How does that make you feel?", .{request.sentence});
    return null;
}

/// Introduce answers a name with three sentences.
fn introduce(app: *App, _: *adapter.Call, request: *const eliza.IntroduceRequest, sender: *adapter.Sender(eliza.IntroduceResponse)) ?connect.RpcError {
    app.calls += 1;
    const who = if (request.name.len == 0) "friend" else request.name;
    const lines = [_][]const u8{ "Hi {s}, I am Eliza.", "Before we begin, {s}, tell me how you came here.", "How are you feeling today, {s}?" };
    inline for (lines) |line| {
        sender.send(&.{ .sentence = reply(app, line, .{who}) }) catch return .{ .code = .resource_exhausted };
    }
    return null;
}

/// Converse answers each sentence it reads, in order.
fn converse(app: *App, call: *adapter.Call, receiver: *adapter.Receiver(eliza.ConverseRequest), sender: *adapter.Sender(eliza.ConverseResponse)) ?connect.RpcError {
    app.calls += 1;
    for (0..conversation_turns_max) |_| {
        const sentence = receiver.next() orelse break;
        sender.send(&.{ .sentence = reply(app, "Why do you say \"{s}\"?", .{sentence.sentence}) }) catch return .{ .code = .resource_exhausted };
    }
    call.add_trailer("eliza-turns", "done") catch {};
    return null;
}

const route_options: adapter.RouteOptions = .{ .message_bytes = 4096, .token_bytes = 4096 };

/// ELIZA's entries in the route table. Say is served as a POST and, since it has no side
/// effects, as a GET.
pub const routes = .{
    adapter.post(App, Service.say, say, route_options),
    adapter.get(App, Service.say, say, route_options),
    adapter.post(App, Service.introduce, introduce, route_options),
    adapter.post(App, Service.converse, converse, route_options),
};

/// The examples' sentences: what the client sends, and what ELIZA answers.
pub const said = "I feel tired";
pub const say_answer = "You said \"I feel tired\". How does that make you feel?";
pub const name = "Ada";
pub const introduce_answers = [_][]const u8{ "Hi Ada, I am Eliza.", "Before we begin, Ada, tell me how you came here.", "How are you feeling today, Ada?" };
pub const conversation = [_][]const u8{ "Hello", "I dream of code" };
pub const converse_answers = [_][]const u8{ "Why do you say \"Hello\"?", "Why do you say \"I dream of code\"?" };
