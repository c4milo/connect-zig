//! The routed calls: one unary call of a message through `connect_colibri`'s route on colibri's
//! `server.Router`, in memory (docs/performance.md, "The units of work"). The program hands the
//! router the events an engine reports: the request's head, its body with its end, and the
//! request's end. A stand-in engine takes each response octet at once. So a count holds the
//! router, the route, the protocol and the codec, and no framing, TLS or socket.
//!
//! The route takes `connect_colibri`'s default options, as a program that names none does. Its
//! handler answers the message with itself, so each reply's octets equal its request's: `prepare`
//! checks that once for each protocol, before any run. bench/go and bench/rust make the same call
//! through connect-go and connect-rust, and `--write` writes each reply for tools/bench_check.sh.
const std = @import("std");
const assert = std.debug.assert;
const connect = @import("connect");
const rpc = @import("connect_colibri");
const server = @import("server");
const http = @import("http");
const proto = @import("protobuf");
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

    /// The end of the name of the file `--write` writes the reply to, after the message's name.
    pub fn file_suffix(protocol: Protocol) []const u8 {
        return switch (protocol) {
            .connect => "connect.reply",
            .grpc => "grpc.reply",
        };
    }
};

const protocol_count = std.enums.values(Protocol).len;

/// The octets of an envelope's prefix: a flag, then the length (gRPC's "Length-Prefixed-Message").
const prefix_len = connect.constants.protocol.envelope_prefix_len;
const request_id: server.RequestId = @bitCast(@as(u128, 1));
const h2_version: server.Version = .{ .major = constants.h2_major, .minor = 0 };

/// What the route reads: nothing. A program's own state would live here.
const App = struct {};

fn on_error(_: *App, _: *const server.Request, _: anyerror, response: *server.ResponseWriter) void {
    response.status = .internal_server_error;
}

/// The routed calls of `Message`, on the route of the method `Echo<name>`, which answers the
/// message with itself. `main` holds one for each message in its `State` (decision 42).
pub fn Calls(comptime Message: type, comptime name: []const u8) type {
    return struct {
        const Self = @This();
        const echo: connect.Method = .{ .service = "bench.v1.Bench", .name = "Echo" ++ name, .Request = Message, .Response = Message, .stream_type = .unary };
        const Router = server.Router(App, .{
            .error_handler = on_error,
            .routes = .{rpc.post(App, echo, on_echo, .{})},
        }, .{ .requests = constants.call_requests, .response_bytes = constants.call_response_bytes, .body_bytes = constants.call_body_bytes });

        app: App,
        router: Router,
        exchange: Exchange,

        fn on_echo(_: *App, _: *rpc.Context, request: *const rpc.Request(Message), response: *rpc.Response(Message)) ?connect.RpcError {
            response.message = request.message;
            return null;
        }

        /// Encodes `message`, writes each protocol's head and body, and checks one call of each.
        pub fn prepare(self: *Self, message: *const Message) !void {
            self.app = .{};
            self.router = .{};
            // The reply's buffer holds the encoding until `prepare` copies it into each body.
            const reply = &self.exchange.reply;
            const octets = try proto.encode(Message, message, reply[0 .. reply.len - prefix_len]);
            try self.exchange.prepare(octets, comptime echo.path(), self, handle);
        }

        fn handle(context: *anyopaque, engine: *Engine, received: server.Event) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.router.handle(&self.app, engine, received) == .taken;
        }
    };
}

/// One message's calls apart from its route: the engine, each protocol's head and body, and the
/// reply `reply_of` checks. The route's router stands behind `handle_fn`.
pub const Exchange = struct {
    engine: Engine,
    path: []const u8,
    context: *anyopaque,
    handle_fn: *const fn (context: *anyopaque, engine: *Engine, received: server.Event) bool,
    sections: [protocol_count]http.FieldSection,
    bodies: [protocol_count][constants.call_body_len]u8,
    body_lens: [protocol_count]usize,
    reply: [constants.call_body_len]u8,
    reply_len: usize,

    fn prepare(exchange: *Exchange, encoded: []const u8, path: []const u8, context: *anyopaque, handle_fn: @FieldType(Exchange, "handle_fn")) !void {
        assert(encoded.len + prefix_len <= constants.call_body_len);
        assert(encoded.ptr == &exchange.reply);
        exchange.engine = .{};
        exchange.path = path;
        exchange.context = context;
        exchange.handle_fn = handle_fn;
        for (std.enums.values(Protocol)) |protocol| {
            const index = @intFromEnum(protocol);
            const section = &exchange.sections[index];
            section.init();
            const body = &exchange.bodies[index];
            switch (protocol) {
                .connect => {
                    try section.append("content-type", "application/proto");
                    @memcpy(body[0..encoded.len], encoded);
                    exchange.body_lens[index] = encoded.len;
                },
                .grpc => {
                    try section.append("content-type", "application/grpc+proto");
                    try section.append("te", "trailers");
                    // gRPC's "Length-Prefixed-Message": no compression, then the length.
                    body[0] = 0;
                    std.mem.writeInt(u32, body[1..prefix_len], @intCast(encoded.len), .big);
                    @memcpy(body[prefix_len..][0..encoded.len], encoded);
                    exchange.body_lens[index] = prefix_len + encoded.len;
                },
            }
        }
        // A call writes the reply's buffer, which holds `encoded`, so the calls come after the
        // copies.
        for (std.enums.values(Protocol)) |protocol| _ = try exchange.reply_of(protocol);
    }

    /// The reply of one call in `protocol`, which must equal its request's body.
    pub fn reply_of(exchange: *Exchange, protocol: Protocol) ![]const u8 {
        exchange.engine.kept = &exchange.reply;
        defer exchange.engine.kept = null;
        try exchange.call(protocol);
        exchange.reply_len = exchange.engine.body_len;
        if (exchange.engine.status != .ok) return error.CallFailed;
        const sent = exchange.bodies[@intFromEnum(protocol)][0..exchange.bytes(protocol)];
        if (!std.mem.eql(u8, exchange.reply[0..exchange.reply_len], sent)) return error.ReplyDiffers;
        return exchange.reply[0..exchange.reply_len];
    }

    /// The octets of a call's request body, which the table reports.
    pub fn bytes(exchange: *const Exchange, protocol: Protocol) usize {
        return exchange.body_lens[@intFromEnum(protocol)];
    }

    /// One call: its head, its body with its end, and its end, as an engine reports them. Out of
    /// line, so the router's code makes a function of its own (bench/call_main.zig says why).
    noinline fn call(exchange: *Exchange, protocol: Protocol) !void {
        const index = @intFromEnum(protocol);
        exchange.engine.ended = false;
        exchange.engine.body_len = 0;
        try exchange.handle(.{ .request = .{
            .id = request_id,
            .method = "POST",
            .version = h2_version,
            .target = exchange.path,
            .scheme = "https",
            .authority = "bench.example",
            .path = exchange.path,
            .query = null,
            .headers = .of(&exchange.sections[index]),
            .end = false,
        } });
        try exchange.handle(.{ .body = .{ .id = request_id, .user_data = exchange.engine.user_data, .bytes = exchange.bodies[index][0..exchange.body_lens[index]], .end = true } });
        if (!exchange.engine.ended) return error.CallUnfinished;
        try exchange.handle(.{ .finished = .{ .id = request_id, .user_data = exchange.engine.user_data, .result = .sent } });
    }

    fn handle(exchange: *Exchange, received: server.Event) !void {
        if (!exchange.handle_fn(exchange.context, &exchange.engine, received)) return error.EventRefused;
    }

    /// What `measure` and the instruction count run: `iterations` calls in one protocol.
    pub fn runner(exchange: *Exchange, protocol: Protocol) Runner {
        return .{ .exchange = exchange, .protocol = protocol };
    }
};

pub const Runner = struct {
    exchange: *Exchange,
    protocol: Protocol,

    pub fn run(runner: Runner, iterations: u64) !void {
        assert(iterations > 0);
        for (0..iterations) |_| try runner.exchange.call(runner.protocol);
    }
};

/// An engine that takes each response octet at once. It keeps the octets only while `reply_of`
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
