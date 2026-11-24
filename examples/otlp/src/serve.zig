//! The OTLP trace receiver on a socket, to play with: `zig build serve -- [port]`, 8443 by
//! default. It serves h11 and h2 over TLS on a TCP port, and h3 on the UDP socket of the same
//! port, under the test identity of the harness (decision 25). An OpenTelemetry SDK's gRPC
//! exporter sends its spans to it, and `SpanStore/Received` reads them back. README.md shows how.
const std = @import("std");
const connect = @import("connect");
const harness = @import("harness");
const app_file = @import("app.zig");

comptime {
    _ = harness.hooks;
}

/// All the program holds, which `main` allocates once (decision 42). An exporter sends gzip, so
/// the receiver reads gzip and zstd.
const State = struct {
    app: app_file.App,
    served: harness.Served(app_file.App, app_file.Router),
    gzip_decoder: connect.GzipDecoder,
    gzip_encoder: connect.GzipEncoder,
    zstd_decoder: connect.ZstdDecoder,
    zstd_encoder: connect.ZstdEncoder,
};

pub fn main(init: std.process.Init) !void {
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    // Each codec runs the fastest path the CPU it runs on holds (decision 10).
    state.app = .{ .cpu_features = .detect(), .codings = .{
        .decoders = .{ .gzip = &state.gzip_decoder, .zstd = &state.zstd_decoder },
        .encoders = .{ .gzip = &state.gzip_encoder, .zstd = &state.zstd_encoder },
    } };
    try state.served.run(init, &state.app);
}
