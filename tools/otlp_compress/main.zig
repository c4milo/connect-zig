//! Writes an export of the full-stack check's compression part (decision 46 as amended) in one
//! coding, with the encoder a connect-zig client places for it: stdx's gzip, zstd or brotli, as
//! `connect.GzipEncoder`, `connect.ZstdEncoder` and `connect.BrotliEncoder` configure them, or
//! none for `identity`.
//!
//!     zig build otlp-compress
//!     zig-out/bin/otlp-compress <identity|gzip|zstd|br> <in.binpb> <out.grpc>
//!
//! <out.grpc> holds the message in gRPC's Length-Prefixed-Message (PROTOCOL-HTTP2.md,
//! "Requests"): a Compressed-Flag of 1 for a coding and of 0 for none, the Message-Length in four
//! octets, big-endian, then the message. The program prints the octets of the message and of what
//! it wrote of it.
const std = @import("std");
const connect = @import("connect");

/// The octets of the largest message the program reads, 4 MiB: the production model's export of
/// 512 spans holds under 300 KiB.
const message_len_max = 4_194_304;
/// A Length-Prefixed-Message's prefix: the Compressed-Flag and the four octets of its length.
const prefix_len = 5;
/// The octets of the buffer standard output is written through.
const output_buffer_len = 256;

/// All the program holds, which `main` allocates once.
const State = struct {
    message: [message_len_max]u8,
    frame: [prefix_len + message_len_max]u8,
    gzip: connect.GzipEncoder,
    zstd: connect.ZstdEncoder,
    brotli: connect.BrotliEncoder,
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const coding_name = args.next() orelse return error.Usage;
    const in_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const coding = connect.Coding.from_name(coding_name) orelse return error.CodingUnknown;
    // Not `create`, which fills all of State with the undefined pattern and so makes
    // each of its pages resident at the start (decision 48).
    const state_memory = init.arena.allocator().rawAlloc(@sizeOf(State), .of(State), @returnAddress()) orelse
        return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(state_memory));
    const message = try std.Io.Dir.cwd().readFile(init.io, in_path, &state.message);
    // readFile stops at the buffer's end, so a full buffer may have left octets unread.
    if (message.len == state.message.len) return error.MessageTooLarge;
    const encoders: connect.Encoders = .{ .gzip = &state.gzip, .zstd = &state.zstd, .brotli = &state.brotli };
    const room = state.frame[prefix_len..];
    const body = if (coding == .identity) identity: {
        @memcpy(room[0..message.len], message);
        break :identity room[0..message.len];
    } else try connect.compression.compress(coding, &encoders, message, room);
    state.frame[0] = @intFromBool(coding != .identity);
    std.mem.writeInt(u32, state.frame[1..prefix_len], @intCast(body.len), .big);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = state.frame[0 .. prefix_len + body.len] });
    var buffer: [output_buffer_len]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try stdout.interface.print("{d} {d}\n", .{ message.len, body.len });
    try stdout.interface.flush();
}
