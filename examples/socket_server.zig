//! Example: the ELIZA and demo services on a TCP socket, in cleartext, on Rotor's loop. Run it
//! with `zig build run-eliza-server -- [port]`, then call it with any Connect, gRPC or gRPC-Web
//! client:
//!
//! ```sh
//! curl -sS --json '{"sentence":"I feel tired"}' \
//!   http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Say
//! buf curl --http2-prior-knowledge --protocol grpc --schema examples/proto \
//!   -d '{"name":"Ada"}' http://127.0.0.1:8080/connectrpc.eliza.v1.ElizaService/Introduce
//! ```
//!
//! The socket loop lives in `services/socket_loop.zig`, which the conformance server shares
//! (decision 26). This program places it, and the codings the services read and write.
const std = @import("std");
const connect = @import("connect");
const socket_loop = @import("socket_loop");
const App = @import("services/app.zig").App;
const Router = @import("services/routes.zig").Router;

const port_default = 8080;

const Server = socket_loop.SocketServer(App, Router, .{ .sockets_max = 8, .socket_buffer_len = 64 * 1024 });

var socket_server: Server align(@alignOf(Server)) = .{};
var app: App align(@alignOf(App)) = .{};
/// The server reads gzip messages and writes them when a client accepts gzip.
var gzip_decoder: connect.GzipDecoder align(@alignOf(connect.GzipDecoder)) = undefined;
var gzip_encoder: connect.GzipEncoder align(@alignOf(connect.GzipEncoder)) = undefined;
/// The same for zstd, which the server answers in when a client lists it before gzip.
var zstd_decoder: connect.ZstdDecoder align(@alignOf(connect.ZstdDecoder)) = undefined;
var zstd_encoder: connect.ZstdEncoder align(@alignOf(connect.ZstdEncoder)) = undefined;

/// Prints the port the server bound, which a script reads when it asked for port 0.
const Listening = struct {
    pub fn on_listening(_: Listening, port: u16) !void {
        std.debug.print("listening on port {d}\n", .{port});
    }
};

pub fn main(init: std.process.Init) !void {
    const port = try port_of(init);
    app.codings = .{
        .decoders = .{ .gzip = &gzip_decoder, .zstd = &zstd_decoder },
        .encoders = .{ .gzip = &gzip_encoder, .zstd = &zstd_encoder },
    };
    try socket_server.serve(&app, port, Listening{});
}

fn port_of(init: std.process.Init) !u16 {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const text = args.next() orelse return port_default;
    return std.fmt.parseInt(u16, text, 10);
}
