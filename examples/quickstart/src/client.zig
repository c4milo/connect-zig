//! The README's client, as a program: it calls Greet on the server at `127.0.0.1:<port>`, in
//! Connect and in gRPC, once over h2 on TCP and once over h3 on QUIC, both under TLS. It trusts
//! the CA of `ca.pem` alone, and judges the server's certificate for `localhost`.
//!
//! ```sh
//! greet-client <port> <ca.pem>
//! ```
//!
//! It exits with an error unless each answer is right and each round spoke its protocol.
const std = @import("std");
const connect_zig = @import("connect_zig");
const stdx = @import("stdx");
const connect = connect_zig.connect;
const rpc = connect_zig.connect_colibri;
const client = connect_zig.colibri.client;
const colibri = connect_zig.colibri;
const tls = connect_zig.colibri.tls;
const greet_v1 = @import("greet_v1");
const constants = @import("constants.zig");
const Service = greet_v1.GreetService;

pub const Error = error{ ArgumentMissing, CallWrong, ProtocolWrong };

/// colibri's HTTP client, which opens the connections and sends each request.
const HttpClient = colibri.Client(.{}, .private);
const GreetCall = rpc.ClientCall(Service.greet, .{});

/// The name the server's certificate carries, which the client asks for and judges it by.
const server_name = "localhost";
const name = "Ada";
const greeting = "Hello, Ada";

const addresses = [_]client.Address{.init(&constants.loopback, 0)};

/// The system's secure entropy, through the program's I/O: the random source of the program's
/// `stdx.crypto` context, which each TLS session draws its secrets from.
const SecureRandom = struct {
    io: std.Io,

    fn fill(pointer: *anyopaque, bytes: []u8) void {
        const self: *SecureRandom = @ptrCast(@alignCast(pointer));
        self.io.randomSecure(bytes) catch |failure| std.debug.panic("no entropy: {t}", .{failure});
    }

    fn random(self: *SecureRandom) std.Random {
        return .{ .ptr = self, .fillFn = fill };
    }
};

/// A round's protocols, and the one it must speak: h2 over TLS on TCP, then h3 on QUIC.
const Round = struct { protocols: client.Protocols, expected: client.Protocol };
const rounds = [_]Round{
    .{ .protocols = .{ .h11 = false, .h3 = false }, .expected = .h2 },
    .{ .protocols = .{ .h11 = false, .h2 = false }, .expected = .h3 },
};

/// Notes the protocol of the round's connection, and ends the round once both calls finished.
const Handler = struct {
    finished: u32 = 0,
    spoken: ?client.Protocol = null,
    expected_calls: u32 = 0,

    pub fn on_connected(self: *Handler, _: *HttpClient, connected: client.Connected) void {
        self.spoken = connected.protocol;
    }

    pub fn on_finished(self: *Handler, running: *HttpClient, _: client.Finished) void {
        self.finished += 1;
        if (self.finished == self.expected_calls) running.shutdown();
    }
};

/// One Greet call, and the buffers it writes its request into and reads its response into.
const Greet = struct {
    call: GreetCall,
    request_body: [constants.call_buffer_len]u8,
    message: [constants.call_buffer_len]u8,
    work: [constants.call_buffer_len]u8,
    values: [constants.call_buffer_len]u8,
    headers: [constants.call_buffer_len]u8,
    trailers: [constants.call_buffer_len]u8,
    body: [constants.call_buffer_len]u8,

    fn init(self: *Greet, shared: *const connect.Client, options: *const connect.client.Options) !void {
        const buffers: rpc.ClientCallBuffers = .{
            .request = .{ .body = &self.request_body, .scratch = .{ .message = &self.message, .work = &self.work, .tokens = &.{} }, .values = &self.values },
            .headers = &self.headers,
            .trailers = &self.trailers,
            .body = &self.body,
        };
        try self.call.init(shared, {}, options, &.{.{ .name = name }}, &buffers);
    }
};

/// Room for one response's strings, details and metadata.
const Reading = struct {
    message: [constants.call_buffer_len]u8,
    work: [constants.call_buffer_len]u8,
    tokens: [constants.call_buffer_len]u8,
    octets: [constants.call_buffer_len]u8,
    details: [constants.entries_max]connect.Detail,
    metadata: [constants.entries_max]connect.Header,

    fn storage(self: *Reading) connect.client.Storage {
        return .{
            .scratch = .{ .message = &self.message, .work = &self.work, .tokens = &self.tokens },
            .octets = &self.octets,
            .details = &self.details,
            .metadata = &self.metadata,
        };
    }
};

/// All the program holds, which `main` allocates once before the first call (decision 42). Each
/// round runs on an HTTP client of its own.
const State = struct {
    /// Connect's client, which the program's calls share: the CPU features it detects once, as
    /// it starts.
    client: connect.Client,
    /// colibri's HTTP clients, one a round.
    http_clients: [rounds.len]HttpClient,
    handler: Handler,
    /// The round's two calls of Greet, one in Connect and one in gRPC.
    greet_connect: Greet,
    greet_grpc: Greet,
    reading: Reading,
    ca_pem: [constants.pem_len_max]u8,
    anchor_der: [constants.der_len_max]u8,
    anchor_room: [constants.anchors_max]tls.Anchor,
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.ArgumentMissing, constants.decimal);
    const ca_path = args.next() orelse return error.ArgumentMissing;
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    state.client = .{ .cpu_features = .detect() };
    // One `stdx.crypto` context of the features the program detected and the system's entropy,
    // which each TLS value holds (colibri decision 175). On arm64 the thread sets PSTATE.DIT where
    // the core has FEAT_DIT, and stdx then states its timing; on x86-64 stdx states it for every
    // core. Under that statement the sessions may run AES-GCM.
    var secure: SecureRandom = .{ .io = init.io };
    _ = stdx.platform.set_data_independent_timing(state.client.cpu_features, true);
    const crypto = stdx.crypto.init(state.client.cpu_features, secure.random());
    const ca = try std.Io.Dir.cwd().readFile(init.io, ca_path, &state.ca_pem);
    // The client judges the server's chain at this instant (RFC 5280 §4.1.2.5).
    const unix_seconds: u64 = @intCast(@max(std.Io.Clock.real.now(init.io).toSeconds(), 0));
    const anchors = try tls.pem.anchors(ca, &state.anchor_der, &state.anchor_room);
    const trust: tls.Trust = .{ .web_pki = .{ .anchors = anchors, .server_name = server_name } };
    for (&state.http_clients, rounds) |*running, round| {
        try run_round(state, running, round, .{ .trust = trust, .crypto = crypto }, port, unix_seconds);
    }
}

fn run_round(state: *State, running: *HttpClient, round: Round, tls_client: tls.Client, port: u16, unix_seconds: u64) !void {
    state.handler = .{ .expected_calls = constants.calls_per_round };
    try running.init(&.{
        .destination = .{ .addresses = &addresses, .port = port },
        .pool = .{
            .tls = tls_client,
            .authority = server_name,
            .protocols = round.protocols,
            .cpu_features = state.client.cpu_features,
        },
        .unix_seconds = unix_seconds,
    }, &state.handler);
    defer running.deinit();
    try state.greet_connect.init(&state.client, &.{});
    try state.greet_grpc.init(&state.client, &.{ .protocol = .grpc });
    _ = try running.request(&state.greet_connect.call.request, &state.greet_connect.call.response);
    _ = try running.request(&state.greet_grpc.call.request, &state.greet_grpc.call.response);
    try running.run();
    if (state.handler.spoken != round.expected) return error.ProtocolWrong;
    try expect_greeting(state, &state.greet_connect);
    try expect_greeting(state, &state.greet_grpc);
    std.debug.print("the client read both answers over {s}, in Connect and in gRPC\n", .{@tagName(round.expected)});
}

fn expect_greeting(state: *State, greet: *Greet) !void {
    var response = greet.call.read(state.reading.storage());
    const answer = try response.next(greet_v1.GreetResponse) orelse return error.CallWrong;
    if (response.failure != null) return error.CallWrong;
    if (!std.mem.eql(u8, answer.greeting, greeting)) return error.CallWrong;
}
