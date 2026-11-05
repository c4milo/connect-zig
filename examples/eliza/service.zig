//! The ELIZA service both eliza programs serve: one handler for each method of
//! connectrpc.eliza.v1.ElizaService, and the route table of colibri's `server.router` that calls
//! them through connect_colibri (design §8 step 5).
const std = @import("std");
const connect = @import("connect");
const server = @import("server");
const adapter = @import("connect_colibri");
const eliza = @import("eliza");
const Service = eliza.ElizaService;

/// The longest sentence ELIZA writes back.
const sentence_len_max = 4096;
/// The sentences Converse answers in one call, at most.
const conversation_turns_max = 16;

/// The server's own state: the calls it answered, and room for the sentences it writes. A reply
/// is written into the response before the handler returns, so one room serves every call.
pub const App = struct {
    calls: u32 = 0,
    /// The codings connect_colibri reads and writes messages in: none unless a program sets them.
    codings: adapter.Codings = .{},
    sentence: [sentence_len_max]u8 = undefined,
};

fn reply(app: *App, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&app.sentence, format, args) catch "I have nothing to say to that.";
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

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = 500;
}

const route_options: adapter.RouteOptions = .{ .message_bytes = 4096, .token_bytes = 4096 };

pub const routes = server.router(App, .{
    .error_handler = on_error,
    .routes = .{
        adapter.post(App, Service.say, say, route_options),
        adapter.get(App, Service.say, say, route_options),
        adapter.post(App, Service.introduce, introduce, route_options),
        adapter.post(App, Service.converse, converse, route_options),
    },
});

/// The router's pool: the calls the server answers at once, and room for each one's request and
/// response.
pub const Router = @TypeOf(routes).Of(.{ .requests = 4, .response_bytes = 8192, .body_bytes = 8192 });

/// The examples' sentences: what the client sends, and what ELIZA answers.
pub const said = "I feel tired";
pub const say_answer = "You said \"I feel tired\". How does that make you feel?";
pub const name = "Ada";
pub const introduce_answers = [_][]const u8{ "Hi Ada, I am Eliza.", "Before we begin, Ada, tell me how you came here.", "How are you feeling today, Ada?" };
pub const conversation = [_][]const u8{ "Hello", "I dream of code" };
pub const converse_answers = [_][]const u8{ "Why do you say \"Hello\"?", "Why do you say \"I dream of code\"?" };
