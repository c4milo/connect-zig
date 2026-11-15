//! The routed calls: one unary call of the small message through `connect_colibri`'s route on
//! colibri's `server.Router`, in memory (docs/performance.md, "The units of work"). The program
//! hands the router the events an engine reports: the request's head, its body with its end, and
//! the request's end. A stand-in engine takes each response octet at once. So a count holds the
//! router, the route, the protocol and the codec, and no framing, TLS or socket.
//!
//! The route takes `connect_colibri`'s default options, as a program that names none does. Its
//! handler answers the small message with itself, so each reply's octets equal its request's:
//! `prepare` checks that once for each protocol, before any run.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const rpc = @import("connect_colibri");
const server = @import("server");
const http = @import("http");
const proto = @import("protobuf");
const bench = @import("bench_v1");
const constants = @import("constants.zig");

/// The protocols a routed call speaks, each with the binary codec.
pub const Protocol = enum {
    connect,
    grpc,

    /// The name the table prints, beside the message's.
    pub fn label(protocol: Protocol) []const u8 {
        return switch (protocol) {
            .connect => "Connect unary call",
            .grpc => "gRPC unary call",
        };
    }
};

/// The method each call runs. It answers the small message with itself.
const echo: connect.Method = .{ .service = "bench.v1.Bench", .name = "Echo", .Request = bench.Small, .Response = bench.Small, .stream_type = .unary };
const path = echo.path();

/// What the route reads: nothing. A program's own state would live here.
const App = struct {};

fn on_echo(_: *App, _: *rpc.Context, request: *const rpc.Request(bench.Small), response: *rpc.Response(bench.Small)) ?connect.RpcError {
    response.message = request.message;
    return null;
}

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

const Router = server.Router(App, .{
    .error_handler = on_error,
    .routes = .{rpc.post(App, echo, on_echo, .{})},
}, .{ .requests = constants.call_requests, .response_bytes = constants.call_response_bytes, .body_bytes = constants.call_body_bytes });

/// An engine that takes each response octet at once. It keeps the octets only while `prepare`
/// checks a reply.
const Engine = struct {
    user_data: usize = 0,
    status: http.Status = .ok,
    ended: bool = false,
    body_len: usize = 0,
    kept: ?[]u8 = null,

    pub fn respond(engine: *Engine, _: server.RequestId, response: server.Response) server.SendError!void {
        engine.status = response.status;
        engine.ended = response.end;
    }

    pub fn write_body(engine: *Engine, _: server.RequestId, body: server.ResponseBody) server.SendError!usize {
        if (engine.kept) |kept| @memcpy(kept[engine.body_len..][0..body.bytes.len], body.bytes);
        engine.body_len += body.bytes.len;
        engine.ended = body.end;
        return body.bytes.len;
    }

    pub fn write_trailers(engine: *Engine, _: server.RequestId, _: []const http.Field) server.SendError!void {
        engine.ended = true;
    }

    pub fn set_user_data(engine: *Engine, _: server.RequestId, user_data: usize) error{RequestUnknown}!void {
        engine.user_data = user_data;
    }

    pub fn cancel(_: *Engine, _: server.RequestId) void {}

    pub fn held_len(_: *Engine, _: server.RequestId) usize {
        return 0;
    }

    pub fn wait_release(_: *Engine, _: server.RequestId) void {}
};

/// The octets of an envelope's prefix: a flag, then the length (gRPC's "Length-Prefixed-Message").
const prefix_len = connect.constants.protocol.envelope_prefix_len;
const request_id: server.RequestId = @bitCast(@as(u128, 1));
const h2_version: server.Version = .{ .major = constants.h2_major, .minor = 0 };

/// What the routed calls hold. `main` allocates it once in its `State` (decision 42).
pub const Calls = struct {
    app: App,
    router: Router,
    engine: Engine,
    /// Each protocol's request head: its header section, and its body.
    sections: [protocol_count]http.FieldSection,
    bodies: [protocol_count][constants.call_body_len]u8,
    body_lens: [protocol_count]usize,
    /// The reply `prepare` checks.
    reply: [constants.call_body_len]u8,

    const protocol_count = std.enums.values(Protocol).len;

    /// Writes each protocol's head and body for `message`, and checks that one call of each
    /// answers with its request's octets.
    pub fn prepare(calls: *Calls, message: *const bench.Small) !void {
        calls.app = .{};
        calls.router = .{};
        calls.engine = .{};
        for (std.enums.values(Protocol)) |protocol| {
            const index = @intFromEnum(protocol);
            const section = &calls.sections[index];
            section.init();
            const body = &calls.bodies[index];
            const encoded = try proto.encode(bench.Small, message, body[prefix_len..]);
            switch (protocol) {
                .connect => {
                    try section.append("content-type", "application/proto");
                    std.mem.copyForwards(u8, body, encoded);
                    calls.body_lens[index] = encoded.len;
                },
                .grpc => {
                    try section.append("content-type", "application/grpc+proto");
                    try section.append("te", "trailers");
                    // gRPC's "Length-Prefixed-Message": no compression, then the length.
                    body[0] = 0;
                    std.mem.writeInt(u32, body[1..prefix_len], @intCast(encoded.len), .big);
                    calls.body_lens[index] = prefix_len + encoded.len;
                },
            }
            try calls.check(protocol);
        }
    }

    fn check(calls: *Calls, protocol: Protocol) !void {
        calls.engine.kept = &calls.reply;
        defer calls.engine.kept = null;
        try calls.call(protocol);
        const sent = calls.bytes(protocol);
        if (calls.engine.status != .ok) return error.CallFailed;
        if (!std.mem.eql(u8, calls.reply[0..calls.engine.body_len], calls.bodies[@intFromEnum(protocol)][0..sent])) return error.ReplyDiffers;
    }

    /// The octets of a call's request body, which the table reports.
    pub fn bytes(calls: *const Calls, protocol: Protocol) usize {
        return calls.body_lens[@intFromEnum(protocol)];
    }

    /// One call: its head, its body with its end, and its end, as an engine reports them.
    fn call(calls: *Calls, protocol: Protocol) !void {
        const index = @intFromEnum(protocol);
        calls.engine.ended = false;
        calls.engine.body_len = 0;
        try calls.handle(.{ .request = .{
            .id = request_id,
            .method = "POST",
            .version = h2_version,
            .target = path,
            .scheme = "https",
            .authority = "bench.example",
            .path = path,
            .query = null,
            .headers = .of(&calls.sections[index]),
            .end = false,
        } });
        try calls.handle(.{ .body = .{ .id = request_id, .user_data = calls.engine.user_data, .bytes = calls.bodies[index][0..calls.body_lens[index]], .end = true } });
        if (!calls.engine.ended) return error.CallUnfinished;
        try calls.handle(.{ .finished = .{ .id = request_id, .user_data = calls.engine.user_data, .result = .sent } });
    }

    fn handle(calls: *Calls, received: server.Event) !void {
        const handled = calls.router.handle(&calls.app, &calls.engine, received);
        if (handled != .taken) return error.EventRefused;
    }

    /// What `measure` and the instruction count run: `iterations` calls in one protocol.
    pub fn runner(calls: *Calls, protocol: Protocol) Runner {
        return .{ .calls = calls, .protocol = protocol };
    }
};

pub const Runner = struct {
    calls: *Calls,
    protocol: Protocol,

    pub fn run(runner: Runner, iterations: u64) !void {
        assert(iterations > 0);
        for (0..iterations) |_| try runner.calls.call(runner.protocol);
    }
};
