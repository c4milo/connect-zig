//! Example: ELIZA's service on Zig's own HTTP server, with no colibri (decision 52).
//!
//! `std.http.Server` reads each request from a socket and `std.http.Client` sends each call.
//! connect-zig's `connect` module does the rest, in memory the program owns: it reads the head
//! and the messages of a request, writes the reply, builds each call and reads its answer. The
//! program asks for connect-zig with `.colibri = false`, so it links no chapulin.
//!
//! With no argument the program starts the server on a loopback port the kernel chooses, makes
//! three calls, and checks each answer:
//!
//! 1. Say, a unary call over Connect with the JSON codec;
//! 2. Say with an empty sentence, which the server answers with `invalid_argument`;
//! 3. Introduce, a server stream over gRPC-Web, whose status comes in a trailers frame.
//!
//! With `serve [port]` it serves until it is killed, for curl and buf curl. `std.http` speaks
//! HTTP/1.1 alone, so the program speaks Connect and gRPC-Web, and not gRPC, which needs trailers.
const std = @import("std");
const connect = @import("connect_zig").connect;
const platform = @import("connect_zig").platform;
const eliza = @import("eliza");
const constants = @import("constants.zig");
const server = @import("server.zig");
const client = @import("client.zig");
const Service = eliza.ElizaService;

pub const Error = error{ExampleWrong};

/// The memory of both sides, which `main` allocates once (decision 42).
const State = struct {
    server: server.Storage,
    client: client.Storage,
    connect_client: connect.Client,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes each of its
    // pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    const cpu_features: platform.CpuFeatures = .detect();
    state.server.cpu_features = cpu_features;
    state.connect_client = .{ .cpu_features = cpu_features };
    const io = init.io;
    var arguments = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = arguments.next();
    if (arguments.next()) |mode| {
        if (!std.mem.eql(u8, mode, "serve")) return error.UnknownMode;
        const port = if (arguments.next()) |text| try std.fmt.parseInt(u16, text, constants.decimal) else constants.check_port;
        return serve(io, state, port);
    }
    try check(io, init.arena.allocator(), state);
}

fn listen(io: std.Io, port: u16) !std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parseIp4(constants.address, port);
    return address.listen(io, .{ .reuse_address = true });
}

fn serve(io: std.Io, state: *State, port: u16) !void {
    var listener = try listen(io, port);
    defer listener.deinit(io);
    std.debug.print("listening on port {d}\n", .{listener.socket.address.getPort()});
    try server.serve(io, &listener, &state.server, constants.serve_connections_max);
}

/// Serves the calls on one task and makes them on this one.
fn check(io: std.Io, allocator: std.mem.Allocator, state: *State) !void {
    var listener = try listen(io, constants.check_port);
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var serving = try io.concurrent(server.serve, .{ io, &listener, &state.server, constants.check_connections });
    {
        // The client keeps one connection for every call, and closes it in `deinit`, which ends
        // the server's task.
        var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer http_client.deinit();
        try say(state, &http_client, port);
        try say_nothing(state, &http_client, port);
        try introduce(state, &http_client, port);
    }
    try serving.await(io);
    std.debug.print("std_http: three calls answered over std.http, with no colibri and no chapulin\n", .{});
}

fn say(state: *State, http_client: *std.http.Client, port: u16) !void {
    const options: connect.client.Options = .{ .protocol = .connect, .codec = .json };
    const request = try state.connect_client.request(Service.say, &options, &.{.{ .sentence = "I feel tired" }}, &client.request_buffers(&state.client));
    var response = try client.exchange(&state.connect_client, http_client, port, &request, .{ .protocol = .connect, .codec = .json, .enveloped = false }, &state.client);
    const answer = try response.next(eliza.SayResponse) orelse return error.ExampleWrong;
    std.debug.print("client: {s}\n", .{answer.sentence});
    if (!std.mem.startsWith(u8, answer.sentence, "You said \"I feel tired\"")) return error.ExampleWrong;
    if (response.failure != null) return error.ExampleWrong;
}

fn say_nothing(state: *State, http_client: *std.http.Client, port: u16) !void {
    const options: connect.client.Options = .{ .protocol = .connect, .codec = .json };
    const request = try state.connect_client.request(Service.say, &options, &.{.{ .sentence = "" }}, &client.request_buffers(&state.client));
    var response = try client.exchange(&state.connect_client, http_client, port, &request, .{ .protocol = .connect, .codec = .json, .enveloped = false }, &state.client);
    if (try response.next(eliza.SayResponse) != null) return error.ExampleWrong;
    const failure = response.failure orelse return error.ExampleWrong;
    std.debug.print("client: {t}: {s}\n", .{ failure.code, failure.message });
    if (failure.code != .invalid_argument) return error.ExampleWrong;
}

fn introduce(state: *State, http_client: *std.http.Client, port: u16) !void {
    const options: connect.client.Options = .{ .protocol = .grpc_web };
    const request = try state.connect_client.request(Service.introduce, &options, &.{.{ .name = "Ada" }}, &client.request_buffers(&state.client));
    var response = try client.exchange(&state.connect_client, http_client, port, &request, .{ .protocol = .grpc_web, .codec = .proto, .enveloped = true }, &state.client);
    var count: usize = 0;
    for (0..constants.replies_max) |_| {
        const line = try response.next(eliza.IntroduceResponse) orelse break;
        std.debug.print("client: {s}\n", .{line.sentence});
        count += 1;
    }
    // The status of gRPC-Web comes in the trailers frame, which the client read after the messages.
    if (count != constants.replies_max - 1 or response.failure != null) return error.ExampleWrong;
}
