//! Example: a client calls the ELIZA service over colibri, in each protocol its client speaks,
//! and checks every answer (design §8 step 5).
//!
//! Both sides run in one process over the in-memory links of the harness, as colibri's examples
//! do. The run has three rounds: over h2 with prior knowledge and over h11, in cleartext, and over
//! h3. In each, one `client.ConnectionPool` carries these calls at once:
//!
//! - Say over Connect with the proto codec, as a POST;
//! - Say over Connect with the JSON codec, as a GET, since Say has no side effects;
//! - Introduce, a server stream, over gRPC-Web;
//! - Converse, a bidirectional stream sent half-duplex, over Connect with JSON;
//! - Say over gRPC, and Introduce over gRPC: their status comes in HTTP trailers, after the
//!   messages, which colibri's client keeps apart from the headers (decision 11);
//! - Say with an empty sentence over gRPC, which fails with invalid_argument. The server sends
//!   that error Trailers-Only, in the head.
//!
//! Anything other than the expected answers exits with an error, which is how `zig build test`
//! and CI know the example works. Run it with `zig build run`.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const harness = @import("harness");
const eliza = @import("eliza");
const service = @import("eliza_service");
const app_file = @import("app.zig");
const App = app_file.App;
const Router = app_file.Router;
const ElizaService = eliza.ElizaService;

comptime {
    _ = harness.hooks;
}

pub const Error = error{CallWrong};

const SayCall = harness.Call(ElizaService.say, .{});
const IntroduceCall = harness.Call(ElizaService.introduce, .{});
const ConverseCall = harness.Call(ElizaService.converse, .{});

/// All the program holds, which `main` allocates once (decision 42). colibri reads and writes
/// each call until its round ends, so the calls live here.
const State = struct {
    app: App,
    rounds: harness.Rounds(App, Router),
    say_proto: SayCall,
    say_get: SayCall,
    introduce: IntroduceCall,
    converse: ConverseCall,
    say_empty: SayCall,
    say_grpc: SayCall,
    introduce_grpc: IntroduceCall,
};

pub fn main(init: std.process.Init) !void {
    const state = try init.arena.allocator().create(State);
    state.app = .{};
    try state.rounds.init(&state.app);
    defer state.rounds.deinit();
    try round(state, .{ .h11 = false, .h3 = false }, .h2);
    try round(state, .{ .h2 = false, .h3 = false }, .h11);
    try round(state, .{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("eliza: every call answered as expected over h2, h11 and h3\n", .{});
}

fn round(state: *State, protocols: client.Protocols, expected: client.Protocol) !void {
    const rounds = &state.rounds;
    try rounds.begin(protocols);
    try state.say_proto.init(&.{}, &.{.{ .sentence = service.said }});
    try state.say_get.init(&.{ .codec = .json, .use_get = true }, &.{.{ .sentence = service.said }});
    try state.introduce.init(&.{ .protocol = .grpc_web }, &.{.{ .name = service.name }});
    try state.converse.init(&.{ .codec = .json }, &.{ .{ .sentence = service.conversation[0] }, .{ .sentence = service.conversation[1] } });
    try state.say_empty.init(&.{ .protocol = .grpc }, &.{.{}});
    try state.say_grpc.init(&.{ .protocol = .grpc }, &.{.{ .sentence = service.said }});
    try state.introduce_grpc.init(&.{ .protocol = .grpc }, &.{.{ .name = service.name }});
    inline for (.{ "say_proto", "say_get", "introduce", "converse", "say_empty", "say_grpc", "introduce_grpc" }) |field| {
        const call = &@field(state, field).call;
        try rounds.request(&call.request, &call.response);
    }
    try rounds.finish(expected);
    try check(state);
    std.debug.print("eliza: round over {s} answered\n", .{@tagName(expected)});
}

/// Reads every message of a response and checks each sentence, then success.
fn expect_sentences(response: *connect.client.Response, comptime T: type, sentences: []const []const u8) !void {
    for (sentences) |sentence| {
        const message = try response.next(T) orelse return error.CallWrong;
        if (!std.mem.eql(u8, message.sentence, sentence)) {
            std.debug.print("eliza: got \"{s}\", wanted \"{s}\"\n", .{ message.sentence, sentence });
            return error.CallWrong;
        }
    }
    try harness.expect_end(response, T);
}

fn check(state: *State) !void {
    const storage = state.rounds.storage();
    var said_proto = state.say_proto.call.read(storage);
    try expect_sentences(&said_proto, eliza.SayResponse, &.{service.say_answer});
    var said_get = state.say_get.call.read(storage);
    try expect_sentences(&said_get, eliza.SayResponse, &.{service.say_answer});
    var introduced = state.introduce.call.read(storage);
    try expect_sentences(&introduced, eliza.IntroduceResponse, &service.introduce_answers);
    var conversed = state.converse.call.read(storage);
    try expect_sentences(&conversed, eliza.ConverseResponse, &service.converse_answers);
    try harness.expect_trailer(conversed.metadata, "eliza-turns", "done");
    var said_grpc = state.say_grpc.call.read(storage);
    try expect_sentences(&said_grpc, eliza.SayResponse, &.{service.say_answer});
    var introduced_grpc = state.introduce_grpc.call.read(storage);
    try expect_sentences(&introduced_grpc, eliza.IntroduceResponse, &service.introduce_answers);
    var empty = state.say_empty.call.read(storage);
    if (try empty.next(eliza.SayResponse) != null) return error.CallWrong;
    const failure = empty.failure orelse return error.CallWrong;
    if (failure.code != .invalid_argument or !std.mem.eql(u8, failure.message, "say something")) return error.CallWrong;
}
