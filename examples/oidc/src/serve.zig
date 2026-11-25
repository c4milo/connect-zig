//! The account service, account.v1.AccountService, on a socket, to play with:
//! `zig build serve -- [port]`, 8443 by default. It serves h11 and h2 over TLS on a TCP port, and
//! h3 on the UDP socket of the same port, under the test identity of the harness (decision 25).
//!
//! Status needs no token. Whoami needs a bearer token that the test issuer signs with its first
//! key, for the audience "account-service". The server prints one at the start, `token: <jwt>`,
//! for "ada", valid for an hour. From the project's folder:
//!
//! ```sh
//! curl --cacert ../harness/tls/ca.pem --json '{}' \
//!   https://127.0.0.1:8443/account.v1.AccountService/Status
//! curl --cacert ../harness/tls/ca.pem -H "authorization: Bearer $TOKEN" --json '{}' \
//!   https://127.0.0.1:8443/account.v1.AccountService/Whoami
//! ```
const std = @import("std");
const harness = @import("harness");
const service = @import("account_service");
const app_file = @import("app.zig");
const constants = @import("constants.zig");
const issuer = service.issuer;

/// All the program holds, which `main` allocates once (decision 42).
const State = struct {
    app: app_file.App,
    served: harness.Served(app_file.App, app_file.Router),
    /// The issuer's JWK Set, which the verifier reads, and the room of the token it prints.
    jwks_text: [issuer.jwks_len_max]u8,
    tokens: issuer.TokenRoom,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    // The program detects the CPU's features once, as it starts.
    state.app = .{ .cpu_features = .detect() };
    // The verifier starts with the issuer's first key and the time of the real clock. A real
    // program fetches the JWK Set from its provider. This program sets the time once, at the
    // start. A program that runs for long calls `set_time` again in each turn of its loop, or
    // the verifier accepts a token after its "exp".
    const now = std.Io.Clock.real.now(init.io).toSeconds();
    try service.start(&state.app.oidc, issuer.jwks(&state.jwks_text, &.{issuer.first_key()}), now, state.app.cpu_features);
    defer state.app.oidc.deinit();
    // A token to call Whoami with, which the test issuer signs with the key the verifier holds.
    const key = issuer.first_key();
    const token = issuer.token(&state.tokens, &key, &.{ .subject = "ada", .audience = service.audience, .expires_unix_seconds = now + constants.hour_s, .email = "ada@example.com", .admin = true });
    std.debug.print("token: {s}\n", .{token});
    try state.served.run(init, &state.app);
}
