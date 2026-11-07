//! Example: a whole RPC through the `connect` module alone, with no network and no HTTP library.
//!
//! `connect` is sans-I/O: it never opens a socket, never reads a clock and never allocates. It
//! turns a request's headers and body into messages, and a reply into headers, a body and
//! trailers, all in memory the program owns. The program moves the bytes between them, which
//! here is a plain copy, and in a server is colibri.
//!
//! The program makes two calls of the ELIZA service, playing both sides:
//!
//! 1. Say, a unary call over Connect with the JSON codec;
//! 2. Introduce, a server stream over gRPC-Web, whose status rides in a trailers frame.
//!
//! Each call goes: the client builds the request, the server accepts its head, reads its
//! messages and writes a reply, and the client reads that reply. The program checks every message
//! and the outcome, and exits with an error otherwise. Run it with `zig build
//! example-sans_io_call`.
const std = @import("std");
const connect = @import("connect");
const eliza = @import("eliza");
const Service = eliza.ElizaService;

pub const Error = error{ExampleWrong};

/// The octets of each buffer either side holds.
const buffer_len = 4096;
/// The most details and metadata entries the client reads.
const entries_max = 8;
/// The messages the server writes for one call, at most.
const replies_max = 4;

/// A list of headers, which the server and the client look names up in, as an HTTP library's
/// header map would.
const Headers = struct {
    entries: []const connect.Header,

    fn find(context: *const anyopaque, name: []const u8) ?[]const u8 {
        const headers: *const Headers = @ptrCast(@alignCast(context));
        for (headers.entries) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    fn lookup(headers: *const Headers) connect.Lookup {
        return .{ .context = headers, .find_fn = find };
    }
};

/// What the server sent back: its status, its headers and its body, as an HTTP library would
/// carry them to the client.
const Wire = struct {
    status: u16 = 0,
    head: connect.server.Head = .{ .status = 0 },
    body: [buffer_len]u8 = undefined,
    body_len: usize = 0,
};

// The memory both sides use. The library holds none of its own.
var request_body: [buffer_len]u8 = undefined;
var request_message: [buffer_len]u8 = undefined;
var request_work: [buffer_len]u8 = undefined;
var request_values: [buffer_len]u8 = undefined;
var server_message: [buffer_len]u8 = undefined;
var server_work: [buffer_len]u8 = undefined;
var server_tokens: [buffer_len]u8 = undefined;
var reply_message: [buffer_len]u8 = undefined;
var trailer_storage: [buffer_len]u8 = undefined;
var trailer_headers: [connect.trailers.trailers_max]connect.Header align(@alignOf(connect.Header)) = undefined;
var client_message: [buffer_len]u8 = undefined;
var client_work: [buffer_len]u8 = undefined;
var client_tokens: [buffer_len]u8 = undefined;
var client_octets: [buffer_len]u8 = undefined;
var details: [entries_max]connect.Detail align(@alignOf(connect.Detail)) = undefined;
var metadata: [entries_max]connect.Header align(@alignOf(connect.Header)) = undefined;
var wire: Wire align(@alignOf(Wire)) = .{};
/// The reply's headers, which the client's response looks names up in while it reads.
var response_headers: Headers align(@alignOf(Headers)) = .{ .entries = &.{} };
/// Where the server formats a reply's sentence; each reply is written before the next is formatted.
var sentence: [buffer_len]u8 = undefined;

pub fn main() !void {
    try say();
    try introduce();
    std.debug.print("sans_io_call: both calls answered, with no socket and no allocation\n", .{});
}

fn say() !void {
    const options: connect.client.Options = .{ .protocol = .connect, .codec = .json };
    const request = try connect.client.request(Service.say, &options, &.{.{ .sentence = "I feel tired" }}, &request_buffers());
    std.debug.print("client: {s} {s} {s}\n", .{ request.http_method, request.target, request.body });
    try serve_say(&request);
    var response = read(.{ .protocol = .connect, .codec = .json, .enveloped = false });
    const answer = try response.next(eliza.SayResponse) orelse return error.ExampleWrong;
    std.debug.print("client: {d} {s}\n", .{ wire.status, answer.sentence });
    if (!std.mem.startsWith(u8, answer.sentence, "You said \"I feel tired\"")) return error.ExampleWrong;
    if (response.failure != null) return error.ExampleWrong;
}

fn introduce() !void {
    const options: connect.client.Options = .{ .protocol = .grpc_web };
    const request = try connect.client.request(Service.introduce, &options, &.{.{ .name = "Ada" }}, &request_buffers());
    std.debug.print("client: {s} {s}, {d} body bytes in envelopes\n", .{ request.http_method, request.target, request.body.len });
    try serve_introduce(&request);
    var response = read(.{ .protocol = .grpc_web, .codec = .proto, .enveloped = true });
    var count: usize = 0;
    for (0..replies_max) |_| {
        const line = try response.next(eliza.IntroduceResponse) orelse break;
        std.debug.print("client: {s}\n", .{line.sentence});
        count += 1;
    }
    // gRPC-Web's status arrives in the trailers frame, which the client read after the messages.
    if (count != replies_max - 1 or response.failure != null) return error.ExampleWrong;
}

fn request_buffers() connect.client.Buffers {
    return .{
        .body = &request_body,
        .scratch = .{ .message = &request_message, .work = &request_work, .tokens = &.{} },
        .values = &request_values,
    };
}

/// The server's first steps for any call: read the head, then start the reply.
fn accept(method: connect.Method, request: *const connect.client.Request) !connect.server.Messages {
    const headers: Headers = .{ .entries = request.headers() };
    const decision = connect.server.accept(request.http_method, null, headers.lookup(), &.{
        .stream_type = method.stream_type,
        .idempotency = method.idempotency,
    });
    const accepted = switch (decision) {
        .accepted => |accepted| accepted,
        .refused => return error.ExampleWrong,
    };
    std.debug.print("server: {s} over {s}\n", .{ method.name, @tagName(accepted.speaks.protocol) });
    const scratch: connect.Scratch = .{ .message = &server_message, .work = &server_work, .tokens = &server_tokens };
    return connect.server.Messages.init(&accepted, request.body, &scratch, &.{});
}

fn reply_of(accepted: connect.server.Accepted) connect.server.Reply {
    return .{ .accepted = accepted, .scratch = .{ .message = &reply_message, .work = &server_work, .tokens = &server_tokens } };
}

fn serve_say(request: *const connect.client.Request) !void {
    var messages = try accept(Service.say, request);
    const said = try messages.next(eliza.SayRequest) orelse return error.ExampleWrong;
    var reply = reply_of(messages.accepted);
    const answer: eliza.SayResponse = .{ .sentence = try std.fmt.bufPrint(&sentence, "You said \"{s}\". How does that make you feel?", .{said.sentence}) };
    const prepared = try reply.prepare(eliza.SayResponse, &answer);
    var body: std.Io.Writer = .fixed(&wire.body);
    wire.head = reply.head(prepared.body());
    try reply.write_message(prepared, &body);
    wire.status = wire.head.status;
    wire.body_len = body.end;
}

fn serve_introduce(request: *const connect.client.Request) !void {
    var messages = try accept(Service.introduce, request);
    const introduced = try messages.next(eliza.IntroduceRequest) orelse return error.ExampleWrong;
    var reply = reply_of(messages.accepted);
    var body: std.Io.Writer = .fixed(&wire.body);
    wire.head = reply.head(.plain);
    const lines = [_][]const u8{ "Hi {s}, I am Eliza.", "Before we begin, {s}, tell me how you came here.", "How are you feeling today, {s}?" };
    inline for (lines) |line| {
        const answer: eliza.IntroduceResponse = .{ .sentence = try std.fmt.bufPrint(&sentence, line, .{introduced.name}) };
        try reply.write_message(try reply.prepare(eliza.IntroduceResponse, &answer), &body);
    }
    // gRPC-Web ends the body with a trailers frame; `finish` writes it after the messages.
    _ = try reply.finish(null, &.{}, &body, &trailer_storage, &trailer_headers);
    wire.status = wire.head.status;
    wire.body_len = body.end;
}

/// The client reads what the server wrote, as an HTTP library would hand it over.
fn read(speaks: connect.Speaks) connect.client.Response {
    response_headers = .{ .entries = wire.head.headers() };
    const storage: connect.client.Storage = .{
        .scratch = .{ .message = &client_message, .work = &client_work, .tokens = &client_tokens },
        .octets = &client_octets,
        .details = &details,
        .metadata = &metadata,
    };
    const incoming: connect.client.Incoming = .{ .status = wire.status, .headers = response_headers.lookup(), .body = wire.body[0..wire.body_len] };
    return connect.client.Response.init(speaks, &incoming, &storage, &.{});
}
