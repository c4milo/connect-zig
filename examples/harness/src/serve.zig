//! An example's routes on a real socket, for curl, buf curl or a client of your own: h11 and h2
//! over TLS on a TCP port, and h3 on the UDP socket of the same port, under the test identity of
//! `tls/` (decision 25). `zig build serve -- [port]` runs it in each example; port 0 lets the
//! kernel choose. It prints `listening on port <port>`, and serves until it is killed.
//!
//! The certificate is for `localhost` and 127.0.0.1, signed by `tls/ca.pem`, so a client trusts
//! that file: `curl --cacert examples/harness/tls/ca.pem https://127.0.0.1:8443/...`.
const std = @import("std");
const colibri = @import("connect_zig").colibri;
const server = @import("connect_zig").server;
const identity = @import("test_identity");
const constants = @import("constants.zig");
const server_side = @import("server_side.zig");

const Server = colibri.Server(.{ .tcp_connections = constants.serve_tcp_connections, .quic_connections = constants.serve_quic_connections }, .private);

/// The served example of a program whose route table `Router` serves calls with `*App`. It holds
/// colibri's server, so the program places it where it allocates its state (decision 42).
pub fn Served(comptime App: type, comptime Router: type) type {
    return struct {
        const Self = @This();

        http_server: Server,
        router: Router,
        /// The TLS session of each TCP connection (colibri decision 167).
        tls_buffer: [server.Config.tls_buffer_len(constants.serve_tcp_connections)]u8,

        /// Serves `app` on the port the command line names, until the program is killed.
        pub fn run(self: *Self, init: std.process.Init, app: *App) !void {
            self.router.init();
            try serve(&self.http_server, &self.router, app, &self.tls_buffer, init);
        }
    };
}

fn serve(http_server: *Server, router: anytype, app: anytype, tls_buffer: []u8, init: std.process.Init) !void {
    const port = try port_of(init);
    // The Unix time when the server starts, which its TLS session tickets carry.
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    try http_server.init(&.{
        .port = port,
        .identity = .{ .chain = identity.chain_pem, .key = identity.key_pem },
        .cpu = server_side.cpu,
        .unix_seconds = unix_seconds,
        .engine = .{ .tls_buffer = tls_buffer },
    }, router, app);
    defer http_server.deinit();
    // A script that asked for port 0 reads the port from this line.
    std.debug.print("listening on port {d}\n", .{http_server.port()});
    try http_server.run();
}

/// The port the command line names, or `serve_port_default`.
pub fn port_of(init: std.process.Init) !u16 {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const text = args.next() orelse return constants.serve_port_default;
    return std.fmt.parseInt(u16, text, constants.decimal);
}
