//! Example: a client calls the ELIZA service over colibri, in each protocol its client speaks,
//! and checks every answer (design §8 step 5).
//!
//! Both sides run in one process over the in-memory link of `services/link.zig`, in cleartext,
//! as colibri's examples do. The run has two rounds: one over h2 with prior knowledge, one over
//! h11. In each, one `client.ConnectionPool` carries these calls at once:
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
//! Anything other than the expected answers exits with an error, which is how `zig build
//! examples` and CI know the example works. Run it with `zig build example-eliza`.
const std = @import("std");
const connect = @import("connect");
const client = @import("client");
const rpc = @import("connect_colibri");
const eliza = @import("eliza");
const service = @import("services/eliza.zig");
const harness = @import("services/link_client.zig");
const Service = eliza.ElizaService;

const calls_count = 7;

pub const Error = error{CallWrong};

// colibri reads and writes each call until the round ends, so they live outside the stack.
var say_proto: rpc.ClientCall(Service.say, .{}) align(@alignOf(rpc.ClientCall(Service.say, .{}))) = undefined;
var say_get: rpc.ClientCall(Service.say, .{}) align(@alignOf(rpc.ClientCall(Service.say, .{}))) = undefined;
var introduce: rpc.ClientCall(Service.introduce, .{}) align(@alignOf(rpc.ClientCall(Service.introduce, .{}))) = undefined;
var converse: rpc.ClientCall(Service.converse, .{}) align(@alignOf(rpc.ClientCall(Service.converse, .{}))) = undefined;
var say_empty: rpc.ClientCall(Service.say, .{}) align(@alignOf(rpc.ClientCall(Service.say, .{}))) = undefined;
var say_grpc: rpc.ClientCall(Service.say, .{}) align(@alignOf(rpc.ClientCall(Service.say, .{}))) = undefined;
var introduce_grpc: rpc.ClientCall(Service.introduce, .{}) align(@alignOf(rpc.ClientCall(Service.introduce, .{}))) = undefined;
var buffers: [calls_count]harness.CallBuffers align(@alignOf(harness.CallBuffers)) = undefined;

pub fn main() !void {
    try harness.init();
    defer harness.deinit();
    try round(.{ .h11 = false, .h3 = false }, .h2);
    try round(.{ .h2 = false, .h3 = false }, .h11);
    try round(.{ .h11 = false, .h2 = false }, .h3);
    std.debug.print("eliza: every call answered as expected over h2, h11 and h3\n", .{});
}

fn round(protocols: client.Protocols, expected: client.Protocol) !void {
    try harness.begin(protocols);
    try say_proto.init(&.{}, &.{.{ .sentence = service.said }}, &harness.buffers(&buffers[0]));
    try say_get.init(&.{ .codec = .json, .use_get = true }, &.{.{ .sentence = service.said }}, &harness.buffers(&buffers[1]));
    try introduce.init(&.{ .protocol = .grpc_web }, &.{.{ .name = service.name }}, &harness.buffers(&buffers[2]));
    try converse.init(&.{ .codec = .json }, &.{ .{ .sentence = service.conversation[0] }, .{ .sentence = service.conversation[1] } }, &harness.buffers(&buffers[3]));
    try say_empty.init(&.{ .protocol = .grpc }, &.{.{}}, &harness.buffers(&buffers[4]));
    try harness.request(&say_proto.request, &say_proto.response);
    try harness.request(&say_get.request, &say_get.response);
    try harness.request(&introduce.request, &introduce.response);
    try harness.request(&converse.request, &converse.response);
    try harness.request(&say_empty.request, &say_empty.response);
    try say_grpc.init(&.{ .protocol = .grpc }, &.{.{ .sentence = service.said }}, &harness.buffers(&buffers[5]));
    try introduce_grpc.init(&.{ .protocol = .grpc }, &.{.{ .name = service.name }}, &harness.buffers(&buffers[6]));
    try harness.request(&say_grpc.request, &say_grpc.response);
    try harness.request(&introduce_grpc.request, &introduce_grpc.response);
    try harness.finish(expected);
    try check();
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

fn check() !void {
    var said_proto = say_proto.read(harness.storage());
    try expect_sentences(&said_proto, eliza.SayResponse, &.{service.say_answer});
    var said_get = say_get.read(harness.storage());
    try expect_sentences(&said_get, eliza.SayResponse, &.{service.say_answer});
    var introduced = introduce.read(harness.storage());
    try expect_sentences(&introduced, eliza.IntroduceResponse, &service.introduce_answers);
    var conversed = converse.read(harness.storage());
    try expect_sentences(&conversed, eliza.ConverseResponse, &service.converse_answers);
    try harness.expect_trailer(conversed.metadata, "eliza-turns", "done");
    var said_grpc = say_grpc.read(harness.storage());
    try expect_sentences(&said_grpc, eliza.SayResponse, &.{service.say_answer});
    var introduced_grpc = introduce_grpc.read(harness.storage());
    try expect_sentences(&introduced_grpc, eliza.IntroduceResponse, &service.introduce_answers);
    var empty = say_empty.read(harness.storage());
    if (try empty.next(eliza.SayResponse) != null) return error.CallWrong;
    const failure = empty.failure orelse return error.CallWrong;
    if (failure.code != .invalid_argument or !std.mem.eql(u8, failure.message, "say something")) return error.CallWrong;
}
