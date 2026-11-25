//! Example: the std.Io server of `src/server/server.zig` answers connect-zig's client over real
//! TCP sockets, and neither side runs Rotor (decision 32). Run it with `zig build run`.
//!
//! The program starts the server binary it is given on port 0, and reads the port from the
//! server's `listening on port <port>` line. It then runs two rounds, one over h2 with prior
//! knowledge and one over h11, in cleartext (decision 13). In each, one `client.ConnectionPool`,
//! which `driver.zig` drives over `std.Io`, carries these calls at once:
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
const connect = @import("connect_zig").connect;
const client = @import("connect_zig").client;
const eliza = @import("eliza");
const service = @import("eliza_service");
const constants = @import("constants.zig");
const driver_module = @import("driver.zig");
const Driver = driver_module.Driver;
const Service = eliza.ElizaService;
const Io = std.Io;

comptime {
    // chapulin's hook, which every program over colibri's `tls` defines (colibri decision 94). The
    // harness holds it.
    _ = @import("hooks");
}

const port_prefix = "listening on port ";

pub const Error = error{ CallWrong, ServerSilent, ServerMissing, IdleKept, IdleClosedEarly };

const SayCall = driver_module.Call(Service.say);
const IntroduceCall = driver_module.Call(Service.introduce);
const ConverseCall = driver_module.Call(Service.converse);

/// All the program holds, which `main` allocates once (decision 42). colibri reads and writes
/// each call until its round ends, so the calls live here.
const State = struct {
    driver: Driver,
    /// What the program's calls share: the CPU features it detects once, as it starts.
    client: connect.Client,
    say_proto: SayCall,
    say_get: SayCall,
    introduce: IntroduceCall,
    converse: ConverseCall,
    say_grpc: SayCall,
    say_empty: SayCall,
    /// The server's first line, and the room of the read that waits for the idle socket's close.
    line: [constants.line_len_max]u8,
    idle_room: [constants.line_len_max]u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.driver.init(io);
    state.client = .{ .cpu_features = .detect() };
    defer state.driver.deinit(io);
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const server_path = args.next() orelse return error.ServerMissing;
    var child = try std.process.spawn(io, .{ .argv = &.{ server_path, constants.server_port_argument }, .stderr = .pipe });
    defer child.kill(io);
    const port = try port_of(io, child.stderr.?, &state.line);
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const idle = try address.connect(io, .{ .mode = .stream });
    defer idle.close(io);
    const idle_since = now_ns(io);
    try round(io, state, port, .{ .h11 = false, .h3 = false }, .h2);
    try round(io, state, port, .{ .h2 = false, .h3 = false }, .h11);
    try expect_closed(io, idle, idle_since, &state.idle_room);
    std.debug.print("std_io: every call answered over h2 and h11, with no Rotor\n", .{});
}

fn now_ns(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// Waits for the server to close the idle socket, and checks it closed at its first-request
/// deadline.
fn expect_closed(io: Io, idle: Io.net.Stream, since_ns: u64, room: []u8) !void {
    const latest_ns = since_ns + constants.first_request_timeout_ns + constants.close_margin_ns;
    const wait_ns = latest_ns -| now_ns(io);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(wait_ns), .clock = .awake } };
    const file: Io.File = .{ .handle = idle.socket.handle, .flags = .{ .nonblocking = false } };
    const operation: Io.Operation = .{ .file_read_streaming = .{ .file = file, .data = &.{room} } };
    const result = io.operateTimeout(operation, timeout) catch |failure| switch (failure) {
        error.Timeout => return error.IdleKept,
        else => return failure,
    };
    // The server writes nothing to a socket that sent nothing: it closes it.
    if (result.file_read_streaming) |_| return error.IdleKept else |_| {}
    if (now_ns(io) - since_ns + constants.close_margin_ns < constants.first_request_timeout_ns) return error.IdleClosedEarly;
    std.debug.print("std_io: the idle socket closed at its first-request deadline\n", .{});
}

/// Reads the server's first line, `listening on port <port>`, and returns the port.
fn port_of(io: Io, stderr: Io.File, line: []u8) !u16 {
    var reader = stderr.readerStreaming(io, line);
    const text = reader.interface.takeDelimiterExclusive('\n') catch return error.ServerSilent;
    if (!std.mem.startsWith(u8, text, port_prefix)) return error.ServerSilent;
    return std.fmt.parseInt(u16, text[port_prefix.len..], constants.port_base);
}

fn round(io: Io, state: *State, port: u16, protocols: client.Protocols, expected: client.Protocol) !void {
    const driver = &state.driver;
    try driver.begin(protocols, port, state.client.cpu_features);
    try state.say_proto.init(&state.client, &.{}, &.{.{ .sentence = service.said }});
    try state.say_get.init(&state.client, &.{ .codec = .json, .use_get = true }, &.{.{ .sentence = service.said }});
    try state.introduce.init(&state.client, &.{ .protocol = .grpc_web }, &.{.{ .name = service.name }});
    try state.converse.init(&state.client, &.{ .codec = .json }, &.{ .{ .sentence = service.conversation[0] }, .{ .sentence = service.conversation[1] } });
    try state.say_grpc.init(&state.client, &.{ .protocol = .grpc }, &.{.{ .sentence = service.said }});
    try state.say_empty.init(&state.client, &.{ .protocol = .grpc }, &.{.{}});
    inline for (.{ "say_proto", "say_get", "introduce", "converse", "say_grpc", "say_empty" }) |field| {
        const call = &@field(state, field).call;
        try driver.request(&call.request, &call.response);
    }
    try driver.finish(io, expected);
    try check(state);
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
    try driver_module.expect_end(response, T);
}

fn check(state: *State) !void {
    const storage = state.driver.storage();
    var said_proto = state.say_proto.call.read(storage);
    try expect_sentences(&said_proto, eliza.SayResponse, &.{service.say_answer});
    var said_get = state.say_get.call.read(storage);
    try expect_sentences(&said_get, eliza.SayResponse, &.{service.say_answer});
    var introduced = state.introduce.call.read(storage);
    try expect_sentences(&introduced, eliza.IntroduceResponse, &service.introduce_answers);
    var conversed = state.converse.call.read(storage);
    try expect_sentences(&conversed, eliza.ConverseResponse, &service.converse_answers);
    var said_grpc = state.say_grpc.call.read(storage);
    try expect_sentences(&said_grpc, eliza.SayResponse, &.{service.say_answer});
    var empty = state.say_empty.call.read(storage);
    if (try empty.next(eliza.SayResponse) != null) return error.CallWrong;
    const failure = empty.failure orelse return error.CallWrong;
    if (failure.code != .invalid_argument or !std.mem.eql(u8, failure.message, "say something")) return error.CallWrong;
}
