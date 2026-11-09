//! Example: the std.Io server of `std_io_server.zig` answers connect-zig's client over real TCP
//! sockets, and neither side runs Rotor (decision 32). Run it with `zig build example-std-io`.
//!
//! The program starts the server binary it is given on port 0, and reads the port from the
//! server's `listening on port <port>` line. It then runs two rounds, one over h2 with prior
//! knowledge and one over h11, in cleartext (decision 13). In each, one `client.ConnectionPool`,
//! which `services/std_io_client.zig` drives over `std.Io`, carries these calls at once:
//!
//! - Say over Connect with the proto codec, as a POST;
//! - Say over Connect with the JSON codec, as a GET;
//! - Introduce, a server stream, over gRPC-Web;
//! - Converse, a bidirectional stream sent half-duplex, over Connect with JSON;
//! - Say over gRPC;
//! - Say with an empty sentence over gRPC, which fails with invalid_argument.
//!
//! A third socket sends nothing, and the server must close it once its first request is late:
//! that deadline fires only through the server's ticks. Anything other than the expected answers
//! exits with an error, and the server stops with the program.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const eliza = @import("eliza");
const service = @import("services/eliza.zig");
const harness = @import("services/std_io_client.zig");
const Service = eliza.ElizaService;
const Io = std.Io;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (colibri decision 94).
    _ = @import("services/hooks.zig");
}

const calls_count = 6;
/// Octets of the server's first line, at most, and the octets one read of it takes.
const line_len_max = 64;
const port_prefix = "listening on port ";
/// The first-request timeout of `std_io_server.zig`, and how far from it the close may come:
/// within one tick of the server and the time a round takes.
const first_request_timeout_ns: u64 = 5 * std.time.ns_per_s;
const close_margin_ns: u64 = 2 * std.time.ns_per_s;

pub const Error = error{ CallWrong, ServerSilent, ServerMissing, IdleKept, IdleClosedEarly };

// colibri reads and writes each call until the round ends, so they live outside the stack.
const SayCall = rpc.ClientCall(Service.say, .{});
const IntroduceCall = rpc.ClientCall(Service.introduce, .{});
const ConverseCall = rpc.ClientCall(Service.converse, .{});
var say_proto: SayCall align(@alignOf(SayCall)) = undefined;
var say_get: SayCall align(@alignOf(SayCall)) = undefined;
var introduce: IntroduceCall align(@alignOf(IntroduceCall)) = undefined;
var converse: ConverseCall align(@alignOf(ConverseCall)) = undefined;
var say_grpc: SayCall align(@alignOf(SayCall)) = undefined;
var say_empty: SayCall align(@alignOf(SayCall)) = undefined;
var buffers: [calls_count]harness.CallBuffers align(@alignOf(harness.CallBuffers)) = undefined;
var line: [line_len_max]u8 align(@alignOf(u64)) = undefined;
var idle_room: [line_len_max]u8 align(@alignOf(u64)) = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const server_path = args.next() orelse return error.ServerMissing;
    var child = try std.process.spawn(io, .{ .argv = &.{ server_path, "0" }, .stderr = .pipe });
    defer child.kill(io);
    const port = try port_of(io, child.stderr.?);
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const idle = try address.connect(io, .{ .mode = .stream });
    defer idle.close(io);
    const idle_since = now_ns(io);
    try round(io, port, .{ .h11 = false, .h3 = false }, .h2);
    try round(io, port, .{ .h2 = false, .h3 = false }, .h11);
    try expect_closed(io, idle, idle_since);
    std.debug.print("std_io: every call answered over h2 and h11, with no Rotor\n", .{});
}

fn now_ns(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// Waits for the server to close the idle socket, and checks it closed at its first-request
/// deadline.
fn expect_closed(io: Io, idle: Io.net.Stream, since_ns: u64) !void {
    const latest_ns = since_ns + first_request_timeout_ns + close_margin_ns;
    const wait_ns = latest_ns -| now_ns(io);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(wait_ns), .clock = .awake } };
    const file: Io.File = .{ .handle = idle.socket.handle, .flags = .{ .nonblocking = false } };
    const operation: Io.Operation = .{ .file_read_streaming = .{ .file = file, .data = &.{&idle_room} } };
    const result = io.operateTimeout(operation, timeout) catch |failure| switch (failure) {
        error.Timeout => return error.IdleKept,
        else => return failure,
    };
    // The server writes nothing to a socket that sent nothing: it closes it.
    if (result.file_read_streaming) |_| return error.IdleKept else |_| {}
    if (now_ns(io) - since_ns + close_margin_ns < first_request_timeout_ns) return error.IdleClosedEarly;
    std.debug.print("std_io: the idle socket closed at its first-request deadline\n", .{});
}

/// Reads the server's first line, `listening on port <port>`, and returns the port.
fn port_of(io: Io, stderr: Io.File) !u16 {
    var reader = stderr.readerStreaming(io, &line);
    const text = reader.interface.takeDelimiterExclusive('\n') catch return error.ServerSilent;
    if (!std.mem.startsWith(u8, text, port_prefix)) return error.ServerSilent;
    return std.fmt.parseInt(u16, text[port_prefix.len..], 10);
}

fn round(io: Io, port: u16, protocols: client.Protocols, expected: client.Protocol) !void {
    try harness.begin(io, protocols, port);
    try say_proto.init(&.{}, &.{.{ .sentence = service.said }}, &harness.buffers(&buffers[0]));
    try say_get.init(&.{ .codec = .json, .use_get = true }, &.{.{ .sentence = service.said }}, &harness.buffers(&buffers[1]));
    try introduce.init(&.{ .protocol = .grpc_web }, &.{.{ .name = service.name }}, &harness.buffers(&buffers[2]));
    try converse.init(&.{ .codec = .json }, &.{ .{ .sentence = service.conversation[0] }, .{ .sentence = service.conversation[1] } }, &harness.buffers(&buffers[3]));
    try say_grpc.init(&.{ .protocol = .grpc }, &.{.{ .sentence = service.said }}, &harness.buffers(&buffers[4]));
    try say_empty.init(&.{ .protocol = .grpc }, &.{.{}}, &harness.buffers(&buffers[5]));
    try harness.request(&say_proto.request, &say_proto.response);
    try harness.request(&say_get.request, &say_get.response);
    try harness.request(&introduce.request, &introduce.response);
    try harness.request(&converse.request, &converse.response);
    try harness.request(&say_grpc.request, &say_grpc.response);
    try harness.request(&say_empty.request, &say_empty.response);
    try harness.finish(io, expected);
    try check();
    std.debug.print("std_io: round over {s} answered\n", .{@tagName(expected)});
}

/// Reads every message of a response and checks each sentence, then success.
fn expect_sentences(response: *connect.client.Response, comptime T: type, sentences: []const []const u8) !void {
    for (sentences) |sentence| {
        const message = try response.next(T) orelse return error.CallWrong;
        if (!std.mem.eql(u8, message.sentence, sentence)) {
            std.debug.print("std_io: got \"{s}\", wanted \"{s}\"\n", .{ message.sentence, sentence });
            return error.CallWrong;
        }
    }
    try harness.expect_end(response, T);
}

fn check() !void {
    var said_proto = say_proto.read(harness.storage());
    try expect_sentences(&said_proto, eliza.SayResponse, &.{service.say_answer});
    var said_get = say_get.read(harness.storage());
    try expect_sentences(&said_get, eliza.SayResponse, &.{service.say_answer});
    var introduced = introduce.read(harness.storage());
    try expect_sentences(&introduced, eliza.IntroduceResponse, &service.introduce_answers);
    var conversed = converse.read(harness.storage());
    try expect_sentences(&conversed, eliza.ConverseResponse, &service.converse_answers);
    var said_grpc = say_grpc.read(harness.storage());
    try expect_sentences(&said_grpc, eliza.SayResponse, &.{service.say_answer});
    var empty = say_empty.read(harness.storage());
    if (try empty.next(eliza.SayResponse) != null) return error.CallWrong;
    const failure = empty.failure orelse return error.CallWrong;
    if (failure.code != .invalid_argument or !std.mem.eql(u8, failure.message, "say something")) return error.CallWrong;
}
