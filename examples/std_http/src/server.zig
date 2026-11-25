//! The server half: `std.http.Server` reads each request's head and body from a socket, and
//! connect's sans-I/O server turns them into ELIZA's messages and writes the reply, which
//! `std.http.Server` sends. The program moves the bytes between the two.
const std = @import("std");
const connect = @import("connect_zig").connect;
const CpuFeatures = @import("connect_zig").CpuFeatures;
const eliza = @import("eliza");
const constants = @import("constants.zig");
const Copied = @import("headers.zig").Copied;
const Service = eliza.ElizaService;

/// The server's memory, which `main` allocates once (decision 42). It serves one request at a
/// time, so one of each buffer serves every call.
pub const Storage = struct {
    receive: [constants.buffer_len]u8,
    send: [constants.buffer_len]u8,
    transfer: [constants.buffer_len]u8,
    request_body: [constants.buffer_len]u8,
    request_headers: Copied,
    method_name: [constants.method_len_max]u8,
    target: [constants.buffer_len]u8,
    message: [constants.buffer_len]u8,
    work: [constants.buffer_len]u8,
    tokens: [constants.buffer_len]u8,
    reply_message: [constants.buffer_len]u8,
    reply_body: [constants.buffer_len]u8,
    trailer_storage: [constants.buffer_len]u8,
    trailer_headers: [connect.trailers.trailers_max]connect.Header,
    error_storage: [constants.buffer_len]u8,
    response_headers: [constants.headers_max]std.http.Header,
    sentence: [constants.buffer_len]u8,
    cpu_features: CpuFeatures,
};

/// Serves `connections` connections one after another, each until its client closes it.
pub fn serve(io: std.Io, listener: *std.Io.net.Server, storage: *Storage, connections: usize) !void {
    std.debug.assert(connections > 0);
    for (0..connections) |_| {
        var stream = try listener.accept(io);
        defer stream.close(io);
        try serve_connection(io, stream, storage);
    }
}

fn serve_connection(io: std.Io, stream: std.Io.net.Stream, storage: *Storage) !void {
    var reader = stream.reader(io, &storage.receive);
    var writer = stream.writer(io, &storage.send);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    for (0..constants.requests_per_connection_max) |_| {
        var request = http.receiveHead() catch |failure| switch (failure) {
            error.HttpConnectionClosing => return,
            else => return failure,
        };
        try serve_request(&request, storage);
    }
}

fn serve_request(request: *std.http.Server.Request, storage: *Storage) !void {
    // Each copy points into `storage`, since reading the body reuses the head's octets.
    const target = try copy_target(request, storage);
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. query_start orelse target.len];
    const query = if (query_start) |start| target[start + 1 ..] else null;
    const http_method = copy_method(request, &storage.method_name);
    try storage.request_headers.copy(request.iterateHeaders());
    const body = try read_body(request, storage);
    if (std.mem.eql(u8, path, comptime Service.say.path())) return say(request, storage, http_method, query, body);
    if (std.mem.eql(u8, path, comptime Service.introduce.path())) return introduce(request, storage, http_method, query, body);
    try request.respond("", .{ .status = .not_found });
}

fn copy_target(request: *const std.http.Server.Request, storage: *Storage) ![]const u8 {
    const target = request.head.target;
    if (target.len > storage.target.len) return error.TargetTooLong;
    @memcpy(storage.target[0..target.len], target);
    return storage.target[0..target.len];
}

fn copy_method(request: *const std.http.Server.Request, out: *[constants.method_len_max]u8) []const u8 {
    const name = @tagName(request.head.method);
    std.debug.assert(name.len <= out.len);
    @memcpy(out[0..name.len], name);
    return out[0..name.len];
}

fn read_body(request: *std.http.Server.Request, storage: *Storage) ![]const u8 {
    const length = request.head.content_length orelse 0;
    if (length > storage.request_body.len) return error.BodyTooLarge;
    const body = storage.request_body[0..@intCast(length)];
    const reader = request.readerExpectNone(&storage.transfer);
    try reader.readSliceAll(body);
    return body;
}

fn scratch_of(storage: *Storage) connect.Scratch {
    return .{ .message = &storage.message, .work = &storage.work, .tokens = &storage.tokens };
}

/// Reads the head with connect's server. A refused request is answered here, and gives null.
fn accept(request: *std.http.Server.Request, storage: *Storage, method: connect.Method, http_method: []const u8, query: ?[]const u8) !?connect.server.Accepted {
    const decision = connect.server.accept(http_method, query, storage.request_headers.lookup(), &.{
        .stream_type = method.stream_type,
        .idempotency = method.idempotency,
        .cpu_features = storage.cpu_features,
    });
    switch (decision) {
        .accepted => |accepted| return accepted,
        .refused => |refused| {
            const reply = connect.server.refusal_reply(&refused, &scratch_of(storage)) orelse {
                try request.respond("", .{ .status = @enumFromInt(refused.http_status) });
                return null;
            };
            try respond_error(request, storage, &reply, refused.failure.?);
            return null;
        },
    }
}

fn say(request: *std.http.Server.Request, storage: *Storage, http_method: []const u8, query: ?[]const u8, body: []const u8) !void {
    const accepted = try accept(request, storage, Service.say, http_method, query) orelse return;
    var messages = connect.server.Messages.init(&accepted, body, &scratch_of(storage), &.{});
    const said = try messages.next(eliza.SayRequest) orelse return error.NoRequestMessage;
    var reply = reply_of(storage, accepted);
    // Connect protocol, "Unary-Response": an error is a JSON body with its HTTP status.
    if (said.sentence.len == 0) return respond_error(request, storage, &reply, .{ .code = .invalid_argument, .message = "say something" });
    const answer: eliza.SayResponse = .{ .sentence = try std.fmt.bufPrint(&storage.sentence, "You said \"{s}\". How does that make you feel?", .{said.sentence}) };
    const prepared = try reply.prepare(eliza.SayResponse, &answer);
    var out: std.Io.Writer = .fixed(&storage.reply_body);
    const head = reply.head(prepared.body());
    try reply.write_message(prepared, &out);
    try respond(request, storage, &head, out.buffered());
}

fn introduce(request: *std.http.Server.Request, storage: *Storage, http_method: []const u8, query: ?[]const u8, body: []const u8) !void {
    const accepted = try accept(request, storage, Service.introduce, http_method, query) orelse return;
    var messages = connect.server.Messages.init(&accepted, body, &scratch_of(storage), &.{});
    const introduced = try messages.next(eliza.IntroduceRequest) orelse return error.NoRequestMessage;
    var reply = reply_of(storage, accepted);
    var out: std.Io.Writer = .fixed(&storage.reply_body);
    const head = reply.head(.plain);
    const lines = [_][]const u8{ "Hi {s}, I am Eliza.", "Before we begin, {s}, tell me how you came here.", "How are you feeling today, {s}?" };
    inline for (lines) |line| {
        const answer: eliza.IntroduceResponse = .{ .sentence = try std.fmt.bufPrint(&storage.sentence, line, .{introduced.name}) };
        try reply.write_message(try reply.prepare(eliza.IntroduceResponse, &answer), &out);
    }
    // Connect streams and gRPC-Web end in the body, so the reply needs no HTTP trailers.
    const trailers = try reply.finish(null, &.{}, &out, &storage.trailer_storage, &storage.trailer_headers);
    if (trailers.len != 0) return error.TrailersOverHttp1;
    try respond(request, storage, &head, out.buffered());
}

fn reply_of(storage: *Storage, accepted: connect.server.Accepted) connect.server.Reply {
    return .{ .accepted = accepted, .scratch = .{ .message = &storage.reply_message, .work = &storage.work, .tokens = &storage.tokens } };
}

fn respond_error(request: *std.http.Server.Request, storage: *Storage, reply: *const connect.server.Reply, failure: connect.RpcError) !void {
    // A gRPC error before any message carries its status in trailers, which HTTP/1.1 cannot.
    if (!reply.error_only()) return error.TrailersOverHttp1;
    const head = try reply.error_head(&failure, &storage.error_storage);
    var out: std.Io.Writer = .fixed(&storage.reply_body);
    try reply.write_error_body(failure, &out);
    try respond(request, storage, &head, out.buffered());
}

/// Sends the head connect's reply built, and the body, with `std.http.Server`.
fn respond(request: *std.http.Server.Request, storage: *Storage, head: *const connect.server.Head, body: []const u8) !void {
    const headers = head.headers();
    if (headers.len > storage.response_headers.len) return error.TooManyHeaders;
    for (headers, storage.response_headers[0..headers.len]) |header, *out| out.* = .{ .name = header.name, .value = header.value };
    try request.respond(body, .{ .status = @enumFromInt(head.status), .extra_headers = storage.response_headers[0..headers.len] });
}
