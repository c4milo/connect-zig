//! Example: a whole RPC through the `connect` module alone, with no network and no HTTP library.
//!
//! `connect` is sans-I/O: it never opens a socket, never reads a clock and never allocates. It
//! turns the headers and the body of a request into messages, and a reply into headers, a body
//! and trailers, all in memory that the program owns. The program moves the bytes between them.
//! Here a plain copy moves them, and in a server colibri moves them.
//!
//! The program makes two calls of the ELIZA service, and plays both sides:
//!
//! 1. Say, a unary call over Connect with the JSON codec;
//! 2. Introduce, a server stream over gRPC-Web, whose status comes in a trailers frame.
//!
//! In each call, the client builds the request. The server accepts its head, reads its messages
//! and writes a reply. Then the client reads that reply. The program checks every message and the
//! outcome, and exits with an error otherwise. Run it with `zig build run`.
const std = @import("std");
const connect = @import("connect");
const eliza = @import("eliza");
const constants = @import("constants.zig");
const Service = eliza.ElizaService;

pub const Error = error{ExampleWrong};

/// A list of headers, which the server and the client look names up in, as the header map of an
/// HTTP library would.
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
    body: [constants.buffer_len]u8 = undefined,
    body_len: usize = 0,
};

/// The memory of both sides, which `main` allocates once (decision 42). The library holds none of
/// its own.
const State = struct {
    request_body: [constants.buffer_len]u8,
    request_message: [constants.buffer_len]u8,
    request_work: [constants.buffer_len]u8,
    request_values: [constants.buffer_len]u8,
    server_message: [constants.buffer_len]u8,
    server_work: [constants.buffer_len]u8,
    server_tokens: [constants.buffer_len]u8,
    reply_message: [constants.buffer_len]u8,
    trailer_storage: [constants.buffer_len]u8,
    trailer_headers: [connect.trailers.trailers_max]connect.Header,
    client_message: [constants.buffer_len]u8,
    client_work: [constants.buffer_len]u8,
    client_tokens: [constants.buffer_len]u8,
    client_octets: [constants.buffer_len]u8,
    details: [constants.entries_max]connect.Detail,
    metadata: [constants.entries_max]connect.Header,
    wire: Wire,
    /// The headers of the reply. The response of the client looks names up in them while it reads.
    response_headers: Headers,
    /// Where the server formats the sentence of a reply. The server writes each reply before it
    /// formats the next.
    sentence: [constants.buffer_len]u8,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.wire = .{};
    state.response_headers = .{ .entries = &.{} };
    try say(state);
    try introduce(state);
    std.debug.print("sans_io_call: both calls answered, with no socket and no allocation in the library\n", .{});
}

fn say(state: *State) !void {
    const options: connect.client.Options = .{ .protocol = .connect, .codec = .json };
    const request = try connect.client.request(Service.say, &options, &.{.{ .sentence = "I feel tired" }}, &request_buffers(state));
    std.debug.print("client: {s} {s} {s}\n", .{ request.http_method, request.target, request.body });
    try serve_say(state, &request);
    var response = read(state, .{ .protocol = .connect, .codec = .json, .enveloped = false });
    const answer = try response.next(eliza.SayResponse) orelse return error.ExampleWrong;
    std.debug.print("client: {d} {s}\n", .{ state.wire.status, answer.sentence });
    if (!std.mem.startsWith(u8, answer.sentence, "You said \"I feel tired\"")) return error.ExampleWrong;
    if (response.failure != null) return error.ExampleWrong;
}

fn introduce(state: *State) !void {
    const options: connect.client.Options = .{ .protocol = .grpc_web };
    const request = try connect.client.request(Service.introduce, &options, &.{.{ .name = "Ada" }}, &request_buffers(state));
    std.debug.print("client: {s} {s}, {d} body bytes in envelopes\n", .{ request.http_method, request.target, request.body.len });
    try serve_introduce(state, &request);
    var response = read(state, .{ .protocol = .grpc_web, .codec = .proto, .enveloped = true });
    var count: usize = 0;
    for (0..constants.replies_max) |_| {
        const line = try response.next(eliza.IntroduceResponse) orelse break;
        std.debug.print("client: {s}\n", .{line.sentence});
        count += 1;
    }
    // The status of gRPC-Web comes in the trailers frame, which the client read after the messages.
    if (count != constants.replies_max - 1 or response.failure != null) return error.ExampleWrong;
}

fn request_buffers(state: *State) connect.client.Buffers {
    return .{
        .body = &state.request_body,
        .scratch = .{ .message = &state.request_message, .work = &state.request_work, .tokens = &.{} },
        .values = &state.request_values,
    };
}

/// The first steps of the server for any call: read the head, then start the reply.
fn accept(state: *State, method: connect.Method, request: *const connect.client.Request) !connect.server.Messages {
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
    const scratch: connect.Scratch = .{ .message = &state.server_message, .work = &state.server_work, .tokens = &state.server_tokens };
    return connect.server.Messages.init(&accepted, request.body, &scratch, &.{});
}

fn reply_of(state: *State, accepted: connect.server.Accepted) connect.server.Reply {
    return .{ .accepted = accepted, .scratch = .{ .message = &state.reply_message, .work = &state.server_work, .tokens = &state.server_tokens } };
}

fn serve_say(state: *State, request: *const connect.client.Request) !void {
    var messages = try accept(state, Service.say, request);
    const said = try messages.next(eliza.SayRequest) orelse return error.ExampleWrong;
    var reply = reply_of(state, messages.accepted);
    const answer: eliza.SayResponse = .{ .sentence = try std.fmt.bufPrint(&state.sentence, "You said \"{s}\". How does that make you feel?", .{said.sentence}) };
    const prepared = try reply.prepare(eliza.SayResponse, &answer);
    var body: std.Io.Writer = .fixed(&state.wire.body);
    state.wire.head = reply.head(prepared.body());
    try reply.write_message(prepared, &body);
    state.wire.status = state.wire.head.status;
    state.wire.body_len = body.end;
}

fn serve_introduce(state: *State, request: *const connect.client.Request) !void {
    var messages = try accept(state, Service.introduce, request);
    const introduced = try messages.next(eliza.IntroduceRequest) orelse return error.ExampleWrong;
    var reply = reply_of(state, messages.accepted);
    var body: std.Io.Writer = .fixed(&state.wire.body);
    state.wire.head = reply.head(.plain);
    const lines = [_][]const u8{ "Hi {s}, I am Eliza.", "Before we begin, {s}, tell me how you came here.", "How are you feeling today, {s}?" };
    inline for (lines) |line| {
        const answer: eliza.IntroduceResponse = .{ .sentence = try std.fmt.bufPrint(&state.sentence, line, .{introduced.name}) };
        try reply.write_message(try reply.prepare(eliza.IntroduceResponse, &answer), &body);
    }
    // gRPC-Web ends the body with a trailers frame. `finish` writes it after the messages.
    _ = try reply.finish(null, &.{}, &body, &state.trailer_storage, &state.trailer_headers);
    state.wire.status = state.wire.head.status;
    state.wire.body_len = body.end;
}

/// The client reads what the server wrote, as an HTTP library would hand it over.
fn read(state: *State, speaks: connect.Speaks) connect.client.Response {
    state.response_headers = .{ .entries = state.wire.head.headers() };
    const storage: connect.client.Storage = .{
        .scratch = .{ .message = &state.client_message, .work = &state.client_work, .tokens = &state.client_tokens },
        .octets = &state.client_octets,
        .details = &state.details,
        .metadata = &state.metadata,
    };
    const incoming: connect.client.Incoming = .{ .status = state.wire.status, .headers = state.response_headers.lookup(), .body = state.wire.body[0..state.wire.body_len] };
    return connect.client.Response.init(speaks, &incoming, &storage, &.{});
}
