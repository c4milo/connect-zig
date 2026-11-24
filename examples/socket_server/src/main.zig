//! Every example's service on one socket, through `colibri.Server` (colibri decision 150): h11
//! and h2 over TLS on a TCP port, and h3 on the UDP socket of the same port, under the test
//! identity of the harness (decision 25). `tools/interop_check.sh` calls it with curl and buf
//! curl. Run it with `zig build serve -- [port]`, 8443 by default, then call it with any Connect,
//! gRPC or gRPC-Web client:
//!
//! ```sh
//! curl --cacert ../harness/tls/ca.pem --json '{"sentence":"I feel tired"}' \
//!   https://127.0.0.1:8443/connectrpc.eliza.v1.ElizaService/Say
//! ```
//!
//! It reads gzip, zstd and br messages, and answers in the one a client accepts first.
const std = @import("std");
const connect = @import("connect_zig").connect;
const harness = @import("harness");
const account_service = @import("account_service");
const app_file = @import("app.zig");
const App = app_file.App;
const issuer = account_service.issuer;

comptime {
    _ = harness.hooks;
}

/// All the program holds, which `main` allocates once before the first call (decision 42).
const State = struct {
    app: App,
    served: harness.Served(App, app_file.Router),
    gzip_decoder: connect.GzipDecoder,
    gzip_encoder: connect.GzipEncoder,
    zstd_decoder: connect.ZstdDecoder,
    zstd_encoder: connect.ZstdEncoder,
    brotli_decoder: connect.BrotliDecoder,
    brotli_encoder: connect.BrotliEncoder,
    jwks_text: [issuer.jwks_len_max]u8,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    // The program detects the CPU's features once, as it starts: each message and each codec
    // then runs the fastest path the CPU holds (decision 10).
    state.app = .{ .cpu_features = .detect(), .codings = .{
        .decoders = .{ .gzip = &state.gzip_decoder, .zstd = &state.zstd_decoder, .brotli = &state.brotli_decoder },
        .encoders = .{ .gzip = &state.gzip_encoder, .zstd = &state.zstd_encoder, .brotli = &state.brotli_encoder },
    } };
    // The account service's verifier, with the test issuer's first key, at the time the server
    // starts. A server that runs for long calls `set_time` again as its clock moves, and
    // `set_keys` when `keys_stale` asks for it.
    const started_seconds: i64 = @max(std.Io.Clock.real.now(init.io).toSeconds(), 0);
    try account_service.start(&state.app.oidc, issuer.jwks(&state.jwks_text, &.{issuer.first_key()}), started_seconds, state.app.cpu_features);
    defer state.app.oidc.deinit();
    try state.served.run(init, &state.app);
}
